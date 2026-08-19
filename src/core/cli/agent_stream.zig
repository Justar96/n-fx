//! NDJSON event stream for `nfx ask --stream-json`.
//!
//! Agents that drive fx noninteractively need progress while a run is still in
//! flight, not only a final blob at exit. Each event is one JSON object on one
//! stdout line, tagged with a schema version so consumers can gate on it.
//!
//! The final line is always `run_end`, carrying the same fields as `ask --json`,
//! so a consumer that only wants the result can read the last line.

const std = @import("std");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;

/// Tool argument payloads above this size are reported as omitted, so a large
/// file write does not duplicate its whole content into the event stream.
const max_tool_arguments_bytes: usize = 4 * 1024;

const WriteFn = *const fn (?*anyopaque, []const u8) anyerror!void;

/// Serializes NDJSON lines from the ask runtime, which publishes progress from
/// worker threads as well as the main thread.
pub const Emitter = struct {
    alloc: Allocator,
    write: WriteFn,
    write_ctx: ?*anyopaque = null,
    mutex: std.Io.Mutex = .init,

    pub fn runStart(
        self: *Emitter,
        model: []const u8,
        session_id: []const u8,
        cwd: []const u8,
        permission_mode: []const u8,
    ) void {
        var line = self.begin("run_start") catch return;
        defer line.deinit();
        line.field("model", model) catch return;
        line.field("session_id", session_id) catch return;
        line.field("cwd", cwd) catch return;
        line.field("permission_mode", permission_mode) catch return;
        self.finish(&line);
    }

    pub fn step(self: *Emitter, n: usize) void {
        var line = self.begin("step") catch return;
        defer line.deinit();
        line.number("n", n) catch return;
        self.finish(&line);
    }

    pub fn text(self: *Emitter, delta: []const u8) void {
        if (delta.len == 0) return;
        var line = self.begin("text") catch return;
        defer line.deinit();
        line.field("delta", delta) catch return;
        self.finish(&line);
    }

    /// `arguments_json` is the tool's own argument object, so a caller can see
    /// which path a write targets without parsing the human summary text. Large
    /// payloads (file contents) are dropped rather than inflating the stream.
    pub fn toolStart(
        self: *Emitter,
        call_id: []const u8,
        name: []const u8,
        arguments_json: ?[]const u8,
    ) void {
        var line = self.begin("tool_start") catch return;
        defer line.deinit();
        line.field("call_id", call_id) catch return;
        line.field("name", name) catch return;
        if (arguments_json) |args| {
            if (args.len > max_tool_arguments_bytes) {
                line.raw("args_omitted", "true") catch return;
            } else if (std.json.validate(self.alloc, args) catch false) {
                line.raw("args", args) catch return;
            }
        }
        self.finish(&line);
    }

    pub fn toolProgress(self: *Emitter, call_id: []const u8, message: []const u8) void {
        var line = self.begin("tool_progress") catch return;
        defer line.deinit();
        line.field("call_id", call_id) catch return;
        line.field("message", message) catch return;
        self.finish(&line);
    }

    pub fn toolEnd(
        self: *Emitter,
        call_id: []const u8,
        status: []const u8,
        summary: []const u8,
    ) void {
        var line = self.begin("tool_end") catch return;
        defer line.deinit();
        line.field("call_id", call_id) catch return;
        line.field("status", status) catch return;
        line.field("summary", summary) catch return;
        self.finish(&line);
    }

    pub fn notice(self: *Emitter, topic: []const u8, level: []const u8, body: []const u8) void {
        var line = self.begin("notice") catch return;
        defer line.deinit();
        line.field("topic", topic) catch return;
        line.field("level", level) catch return;
        line.field("text", body) catch return;
        self.finish(&line);
    }

    pub fn recovery(
        self: *Emitter,
        state: []const u8,
        kind: []const u8,
        attempt: usize,
        attempt_limit: usize,
        message: []const u8,
    ) void {
        var line = self.begin("recovery") catch return;
        defer line.deinit();
        line.field("state", state) catch return;
        line.field("kind", kind) catch return;
        line.number("attempt", attempt) catch return;
        line.number("attempt_limit", attempt_limit) catch return;
        line.field("message", message) catch return;
        self.finish(&line);
    }

    /// Renders the `{"v":1,"t":"<kind>"` prefix shared by every event.
    fn begin(self: *Emitter, kind: []const u8) !Line {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer out.deinit();
        try out.writer.print("{{\"v\":{d},\"t\":", .{schema_version});
        try std.json.Stringify.value(kind, .{}, &out.writer);
        return .{ .alloc = self.alloc, .out = out };
    }

    fn finish(self: *Emitter, line: *Line) void {
        line.out.writer.writeAll("}\n") catch return;
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.write(self.write_ctx, line.out.written()) catch return;
    }
};

const Line = struct {
    alloc: Allocator,
    out: std.Io.Writer.Allocating,

    fn deinit(self: *Line) void {
        self.out.deinit();
    }

    fn field(self: *Line, name: []const u8, value: []const u8) !void {
        const plain = try stripTerminalControls(self.alloc, value);
        defer self.alloc.free(plain);
        try self.out.writer.print(",\"{s}\":", .{name});
        try std.json.Stringify.value(plain, .{}, &self.out.writer);
    }

    fn number(self: *Line, name: []const u8, value: usize) !void {
        try self.out.writer.print(",\"{s}\":{d}", .{ name, value });
    }

    /// Embeds an already-encoded JSON value.
    fn raw(self: *Line, name: []const u8, value: []const u8) !void {
        try self.out.writer.print(",\"{s}\":{s}", .{ name, value });
    }
};

/// Progress strings reaching the emitter are formatted for a terminal, so they
/// can carry ANSI styling. Machine consumers get plain text instead.
fn stripTerminalControls(alloc: Allocator, value: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < value.len) {
        const byte = value[i];
        if (byte == 0x1b) {
            i += 1;
            if (i < value.len and value[i] == '[') {
                i += 1;
                while (i < value.len and (value[i] < 0x40 or value[i] > 0x7e)) i += 1;
                if (i < value.len) i += 1;
            } else if (i < value.len) {
                i += 1;
            }
            continue;
        }
        i += 1;
        if (byte < 0x20 and byte != '\n' and byte != '\t') continue;
        try out.append(alloc, byte);
    }
    return out.toOwnedSlice(alloc);
}

test "strip terminal controls removes ansi styling and stray control bytes" {
    const plain = try stripTerminalControls(std.testing.allocator, "\x1b[32m\u{25CF} Reading\x1b[0m\r\nnext");
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("\u{25CF} Reading\nnext", plain);
}

/// Stable machine codes for the `error_detail` object in ask results. The
/// legacy `error` string keeps carrying the raw Zig error name.
pub const ErrorDetail = struct {
    code: []const u8,
    retryable: bool,

    pub fn fromErrorName(name: []const u8) ErrorDetail {
        const table = [_]struct { name: []const u8, code: []const u8, retryable: bool }{
            .{ .name = "MissingPrompt", .code = "usage", .retryable = false },
            .{ .name = "InvalidAskArgs", .code = "usage", .retryable = false },
            .{ .name = "NoSaveResumeConflict", .code = "usage", .retryable = false },
            .{ .name = "InvalidPromptText", .code = "usage", .retryable = false },
            .{ .name = "PromptResourceLimitExceeded", .code = "prompt_too_large", .retryable = false },
            .{ .name = "PromptInputReadFailed", .code = "stdin_read_failed", .retryable = true },
            .{ .name = "MissingCredentials", .code = "auth", .retryable = false },
            .{ .name = "Unauthorized", .code = "auth", .retryable = false },
            .{ .name = "NonInteractivePermissionRequired", .code = "permission_required", .retryable = false },
            .{ .name = "Cancelled", .code = "interrupted", .retryable = true },
            .{ .name = "ProviderFailed", .code = "provider", .retryable = true },
            .{ .name = "OneOffSessionNotResumable", .code = "session", .retryable = false },
            .{ .name = "RecoverySessionUnavailable", .code = "session", .retryable = false },
            .{ .name = "NoPendingRecovery", .code = "session", .retryable = false },
        };
        for (table) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return .{ .code = entry.code, .retryable = entry.retryable };
            }
        }
        return .{ .code = "internal", .retryable = false };
    }
};

test "error detail maps known names and falls back to internal" {
    try std.testing.expectEqualStrings("usage", ErrorDetail.fromErrorName("InvalidAskArgs").code);
    try std.testing.expect(ErrorDetail.fromErrorName("PromptInputReadFailed").retryable);
    try std.testing.expectEqualStrings("internal", ErrorDetail.fromErrorName("SomethingElse").code);
    try std.testing.expect(!ErrorDetail.fromErrorName("SomethingElse").retryable);
}

const TestSink = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn write(raw_ctx: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *TestSink = @ptrCast(@alignCast(raw_ctx.?));
        try self.bytes.appendSlice(std.testing.allocator, text);
    }

    fn deinit(self: *TestSink) void {
        self.bytes.deinit(std.testing.allocator);
    }
};

test "emitter writes one versioned json object per line" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var emitter: Emitter = .{
        .alloc = std.testing.allocator,
        .write = TestSink.write,
        .write_ctx = &sink,
    };

    emitter.runStart("gpt-5.6-sol", "s-1", "/repo", "auto");
    emitter.step(1);
    emitter.text("hello \"world\"");
    emitter.toolStart("c1", "shell", "{\"command\":\"ls\"}");
    emitter.toolEnd("c1", "ok", "exit 0");

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, sink.bytes.items, "\n"), '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        count += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, schema_version), parsed.value.object.get("v").?.integer);
        try std.testing.expect(parsed.value.object.get("t") != null);
    }
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expect(std.mem.find(u8, sink.bytes.items, "hello \\\"world\\\"") != null);
}

test "tool start embeds valid arguments, drops invalid, and omits oversized" {
    var sink: TestSink = .{};
    defer sink.deinit();
    var emitter: Emitter = .{
        .alloc = std.testing.allocator,
        .write = TestSink.write,
        .write_ctx = &sink,
    };

    emitter.toolStart("c1", "write_file", "{\"path\":\"out/note.txt\"}");
    emitter.toolStart("c2", "write_file", "{not json");
    const oversized = try std.testing.allocator.alloc(u8, max_tool_arguments_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    emitter.toolStart("c3", "write_file", oversized);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, sink.bytes.items, "\n"), '\n');
    const with_args = lines.next().?;
    try std.testing.expect(std.mem.find(u8, with_args, "\"args\":{\"path\":\"out/note.txt\"}") != null);
    const invalid = lines.next().?;
    try std.testing.expect(std.mem.find(u8, invalid, "\"args\"") == null);
    const oversized_line = lines.next().?;
    try std.testing.expect(std.mem.find(u8, oversized_line, "\"args_omitted\":true") != null);
}
