//! Machine-readable rendering of the top-level command registry.
//!
//! `nfx help --json` and `nfx <command> --help --json` let an agent discover the
//! whole CLI contract in one call instead of scraping the human help text.

const std = @import("std");
const agent_stream = @import("../cli/agent_stream.zig");
const command_specs = @import("command_specs.zig");

const Allocator = std.mem.Allocator;
const TopLevelKind = command_specs.TopLevelKind;
const TopLevelRegistry = command_specs.TopLevelRegistry;
const TopLevelSpec = command_specs.TopLevelSpec;

/// Exit codes fx uses for noninteractive commands. `error_detail.code` in a
/// `--json` result carries the specific reason behind a code 1 failure.
const exit_codes = [_]struct { code: u8, meaning: []const u8 }{
    .{ .code = 0, .meaning = "success" },
    .{ .code = 1, .meaning = "failure; see error and error_detail in --json output" },
    .{ .code = 130, .meaning = "interrupted" },
};

/// Event kinds emitted by `nfx ask --stream-json`, one JSON object per line.
const ask_stream_events = [_][]const u8{
    "run_start",
    "step",
    "text",
    "tool_start",
    "tool_progress",
    "tool_end",
    "notice",
    "recovery",
    "run_end",
};

pub fn renderTopLevelHelpJson(
    alloc: Allocator,
    registry: TopLevelRegistry,
    version: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    try w.print("{{\"v\":{d},\"kind\":\"help\",\"version\":", .{agent_stream.schema_version});
    try std.json.Stringify.value(version, .{}, w);
    try w.writeAll(",\"description\":");
    try std.json.Stringify.value(registry.description, .{}, w);

    try w.writeAll(",\"commands\":[");
    for (registry.specs, 0..) |spec, i| {
        if (i > 0) try w.writeAll(",");
        try writeCommand(w, spec);
    }
    try w.writeAll("]");

    try w.writeAll(",\"global_flags\":[");
    for (registry.flags, 0..) |flag, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"usage\":");
        try std.json.Stringify.value(flag.usage, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(flag.description, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try w.writeAll(",\"examples\":[");
    for (registry.examples, 0..) |example, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"command\":");
        try std.json.Stringify.value(example.command, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(example.description, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try writeStringArray(w, ",\"notes\":", registry.notes);
    try writeExitCodes(w);
    try w.writeAll("}\n");
    return try out.toOwnedSlice();
}

pub fn renderCommandHelpJson(
    alloc: Allocator,
    registry: TopLevelRegistry,
    kind: TopLevelKind,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;

    const spec = findSpec(registry, kind) orelse return error.UnknownCommand;
    try w.print("{{\"v\":{d},\"kind\":\"command_help\",\"command\":", .{agent_stream.schema_version});
    try std.json.Stringify.value(spec.token, .{}, w);
    try w.writeAll(",\"spec\":");
    try writeCommand(w, spec);
    try writeExitCodes(w);
    try w.writeAll("}\n");
    return try out.toOwnedSlice();
}

fn findSpec(registry: TopLevelRegistry, kind: TopLevelKind) ?TopLevelSpec {
    for (registry.specs) |spec| {
        if (spec.kind == kind) return spec;
    }
    return null;
}

fn writeCommand(w: *std.Io.Writer, spec: TopLevelSpec) !void {
    try w.writeAll("{\"name\":");
    try std.json.Stringify.value(spec.token, .{}, w);
    try writeStringArray(w, ",\"aliases\":", spec.aliases);
    try w.writeAll(",\"usage\":");
    try std.json.Stringify.value(spec.usage, .{}, w);
    try w.writeAll(",\"summary\":");
    try std.json.Stringify.value(spec.summary, .{}, w);
    try w.writeAll(",\"options\":[");
    for (spec.options, 0..) |option, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"flag\":");
        try std.json.Stringify.value(option.flag, .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.value(option.description, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("]");
    try writeStringArray(w, ",\"details\":", spec.details);
    if (spec.kind == .ask) {
        try writeStringArray(w, ",\"stream_events\":", &ask_stream_events);
    }
    try w.writeAll("}");
}

fn writeStringArray(w: *std.Io.Writer, prefix: []const u8, values: []const []const u8) !void {
    try w.writeAll(prefix);
    try w.writeAll("[");
    for (values, 0..) |value, i| {
        if (i > 0) try w.writeAll(",");
        try std.json.Stringify.value(value, .{}, w);
    }
    try w.writeAll("]");
}

fn writeExitCodes(w: *std.Io.Writer) !void {
    try w.writeAll(",\"exit_codes\":[");
    for (exit_codes, 0..) |entry, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"code\":{d},\"meaning\":", .{entry.code});
        try std.json.Stringify.value(entry.meaning, .{}, w);
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

const test_registry: TopLevelRegistry = .{
    .specs = &.{
        .{
            .kind = .ask,
            .token = "ask",
            .usage = "ask [--json] <prompt>",
            .summary = "Run one noninteractive request",
            .options = &.{.{ .flag = "--json", .description = "Emit JSON" }},
            .details = &.{"Reads stdin when no prompt args are given."},
        },
        .{
            .kind = .status,
            .token = "status",
            .aliases = &.{"state"},
            .usage = "status [--json]",
            .summary = "Show configuration",
        },
    },
    .description = "test registry",
    .interactive_hint = "",
    .flags = &.{.{ .usage = "-h, --help", .description = "Display help" }},
    .examples = &.{.{ .command = "nfx ask \"hi\"", .description = "One request" }},
    .notes = &.{"note one"},
};

test "top level help json exposes commands, flags, and exit codes" {
    const alloc = std.testing.allocator;
    const text = try renderTopLevelHelpJson(alloc, test_registry, "1.2.3");
    defer alloc.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, agent_stream.schema_version), root.get("v").?.integer);
    try std.testing.expectEqualStrings("1.2.3", root.get("version").?.string);
    try std.testing.expectEqual(@as(usize, 2), root.get("commands").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 3), root.get("exit_codes").?.array.items.len);

    const ask = root.get("commands").?.array.items[0].object;
    try std.testing.expectEqualStrings("ask", ask.get("name").?.string);
    try std.testing.expectEqual(@as(usize, 9), ask.get("stream_events").?.array.items.len);

    const status = root.get("commands").?.array.items[1].object;
    try std.testing.expectEqualStrings("state", status.get("aliases").?.array.items[0].string);
    try std.testing.expectEqual(@as(usize, 0), status.get("options").?.array.items.len);
}

test "command help json carries one command spec" {
    const alloc = std.testing.allocator;
    const text = try renderCommandHelpJson(alloc, test_registry, .status);
    defer alloc.free(text);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("command_help", root.get("kind").?.string);
    try std.testing.expectEqualStrings("status", root.get("command").?.string);
    try std.testing.expectEqualStrings("status [--json]", root.get("spec").?.object.get("usage").?.string);
    try std.testing.expect(root.get("spec").?.object.get("stream_events") == null);
}

test "command help json rejects a kind the registry does not define" {
    try std.testing.expectError(
        error.UnknownCommand,
        renderCommandHelpJson(std.testing.allocator, test_registry, .replay),
    );
}
