const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const provider = @import("provider.zig");
const connection_setup = @import("../core/auth/connection_setup.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const Allocator = std.mem.Allocator;
const max_input_bytes = 8 * 1024;

pub const Outcome = enum {
    not_handled,
    success,
    failure,
    invalid_arguments,
};

pub const connection_setup_provider = connection_setup.Provider{
    .default_base_url = config.default_base_url,
    .configure_fn = configureConnection,
    .configured_fn = isConfigured,
};

fn isConfigured(_: ?*anyopaque) bool {
    return config.enabled();
}

const Options = struct {
    base_url: ?[]const u8 = null,
    api_key_stdin: bool = false,
    migrate_from_fx: bool = false,
};

pub fn run(alloc: Allocator, args: []const [:0]const u8) !Outcome {
    if (args.len < 1 or !std.ascii.eqlIgnoreCase(args[0], config.provider_name)) {
        return .not_handled;
    }
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return .not_handled;
    }

    const options = parseOptions(args[1..]) catch return .invalid_arguments;
    runLogin(alloc, options) catch |err| {
        try writeLoginError(err);
        return .failure;
    };
    return .success;
}

fn parseOptions(args: []const [:0]const u8) !Options {
    var result: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--api-key-stdin")) {
            if (result.api_key_stdin) return error.InvalidArguments;
            result.api_key_stdin = true;
        } else if (std.mem.eql(u8, arg, "--migrate-from-fx")) {
            if (result.migrate_from_fx) return error.InvalidArguments;
            result.migrate_from_fx = true;
        } else if (std.mem.eql(u8, arg, "--base-url")) {
            if (result.base_url != null or index + 1 >= args.len) return error.InvalidArguments;
            index += 1;
            result.base_url = args[index];
        } else {
            return error.InvalidArguments;
        }
    }
    return result;
}

fn runLogin(alloc: Allocator, options: Options) !void {
    var legacy: config.FileConfig = if (options.migrate_from_fx)
        (try config.loadLegacy(alloc)) orelse .{}
    else
        .{};
    defer legacy.deinit(alloc);

    var owned_base_url: ?[]u8 = null;
    defer if (owned_base_url) |value| alloc.free(value);
    var owned_api_key: ?[]u8 = null;
    defer if (owned_api_key) |value| secret.zeroAndFree(alloc, value);

    const env_base_url = nonEmptyRawEnv(config.base_url_env);
    const env_api_key = nonEmptyRawEnv(config.api_key_env);
    var base_source: []const u8 = "default";
    var key_source: []const u8 = "prompt";

    const base_url: []const u8 = if (options.base_url) |value| blk: {
        base_source = "command line";
        break :blk value;
    } else if (options.migrate_from_fx) blk: {
        if (legacy.base_url) |value| {
            base_source = "~/.fx/cliproxyapi.json";
            break :blk value;
        }
        if (env_base_url) |value| {
            base_source = config.base_url_env;
            break :blk value;
        }
        break :blk config.default_base_url;
    } else blk: {
        const suggested = env_base_url orelse legacy.base_url orelse config.default_base_url;
        owned_base_url = try promptLine(alloc, "CLIProxyAPI base URL", suggested);
        base_source = "prompt";
        break :blk owned_base_url.?;
    };

    const api_key: []const u8 = if (options.api_key_stdin) blk: {
        owned_api_key = try readLine(alloc, false, true);
        key_source = "stdin";
        break :blk nonEmpty(owned_api_key.?) orelse return error.MissingCliproxyApiKey;
    } else if (options.migrate_from_fx) blk: {
        if (legacy.api_key) |value| {
            key_source = "~/.fx/cliproxyapi.json";
            break :blk value;
        }
        if (env_api_key) |value| {
            key_source = config.api_key_env;
            break :blk value;
        }
        return error.MissingLegacyCliproxyApiKey;
    } else blk: {
        try writeStderr("CLIProxyAPI API key: ");
        owned_api_key = try readMaskedSecret(alloc);
        try writeStderr("\n");
        break :blk owned_api_key.?;
    };
    const validated_api_key = try config.validateApiKey(api_key);

    if (options.migrate_from_fx) {
        const message = try std.fmt.allocPrint(
            alloc,
            "Importing CLIProxyAPI URL from {s} and API key from {s}.\n",
            .{ base_source, key_source },
        );
        defer alloc.free(message);
        try writeStdout(message);
    }

    try writeStdout("Validating CLIProxyAPI connection...\n");
    try configure(alloc, base_url, validated_api_key);
    try writeStdout("Saved CLIProxyAPI settings to ~/.nfx. Existing fx sessions and history remain in ~/.fx.\n");
}

fn configure(alloc: Allocator, base_url: []const u8, api_key: []const u8) !void {
    const validated_api_key = try config.validateApiKey(api_key);
    try provider.validateCredentials(alloc, base_url, validated_api_key);
    try config.save(alloc, base_url, validated_api_key);
}

fn configureConnection(
    _: ?*anyopaque,
    alloc: Allocator,
    base_url: []const u8,
    api_key: []const u8,
) Allocator.Error!connection_setup.Result {
    configure(alloc, base_url, api_key) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.CliproxyAuthenticationFailed => .authentication_failed,
        error.CliproxyConnectionFailed => .connection_failed,
        error.CliproxyValidationFailed => .validation_failed,
        error.InvalidCliproxyBaseUrl => .invalid_base_url,
        error.InsecureCliproxyBaseUrl => .insecure_base_url,
        error.InvalidCliproxyApiKey => .invalid_api_key,
        else => .store_failed,
    };
    return .saved;
}

fn promptLine(alloc: Allocator, label: []const u8, default_value: []const u8) ![]u8 {
    const prompt = try std.fmt.allocPrint(alloc, "{s} [{s}]: ", .{ label, default_value });
    defer alloc.free(prompt);
    try writeStderr(prompt);
    const entered = try readLine(alloc, true, false);
    if (nonEmpty(entered)) |_| return entered;
    alloc.free(entered);
    return alloc.dupe(u8, default_value);
}

fn readLine(alloc: Allocator, allow_empty: bool, sensitive: bool) ![]u8 {
    var input: std.ArrayList(u8) = .empty;
    errdefer if (sensitive and input.capacity > 0)
        secret.zeroAndFree(alloc, input.allocatedSlice())
    else
        input.deinit(alloc);
    while (true) {
        var byte: [1]u8 = undefined;
        const count = try std.Io.File.stdin().readStreaming(io_mod.getIo(), &.{&byte});
        if (count == 0) break;
        if (byte[0] == '\n' or byte[0] == '\r') break;
        if (input.items.len == max_input_bytes) return error.InputTooLong;
        try input.append(alloc, byte[0]);
    }
    if (!allow_empty and input.items.len == 0) return error.InputRequired;
    if (sensitive) {
        const owned = try alloc.dupe(u8, input.items);
        if (input.capacity > 0) secret.zeroAndFree(alloc, input.allocatedSlice());
        input = .empty;
        return owned;
    }
    return input.toOwnedSlice(alloc);
}

fn readMaskedSecret(alloc: Allocator) ![]u8 {
    if (comptime builtin.os.tag == .windows) return error.NotATerminal;
    if (std.c.isatty(std.posix.STDIN_FILENO) == 0 or std.c.isatty(std.posix.STDERR_FILENO) == 0)
        return error.NotATerminal;

    const original = try std.posix.tcgetattr(std.posix.STDIN_FILENO);
    var hidden = original;
    hidden.lflag.ECHO = false;
    try std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, hidden);
    defer std.posix.tcsetattr(std.posix.STDIN_FILENO, .FLUSH, original) catch {};

    return readLine(alloc, false, true);
}

fn writeLoginError(err: anyerror) !void {
    try writeStderr(loginErrorMessage(err));
}

fn loginErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.CliproxyAuthenticationFailed => "nfx login: CLIProxyAPI rejected the API key; nothing was saved\n",
        error.CliproxyConnectionFailed => "nfx login: could not connect to CLIProxyAPI; nothing was saved\n",
        error.CliproxyValidationFailed => "nfx login: CLIProxyAPI model validation failed; nothing was saved\n",
        error.InvalidCliproxyBaseUrl => "nfx login: invalid CLIProxyAPI base URL; nothing was saved\n",
        error.InsecureCliproxyBaseUrl => "nfx login: CLIProxyAPI requires HTTPS outside localhost; nothing was saved\n",
        error.InvalidCliproxyApiKey => "nfx login: CLIProxyAPI API key contains unsupported control characters; nothing was saved\n",
        error.MissingLegacyCliproxyApiKey => "nfx login: no API key exists in ~/.fx/cliproxyapi.json or CLIPROXYAPI_API_KEY\n",
        error.NotATerminal => "nfx login: interactive login needs a terminal; use --api-key-stdin for scripts\n",
        error.HomeNotSet => "nfx login: HOME is not set; nothing was saved\n",
        else => "nfx login: setup failed; check ~/.nfx before retrying\n",
    };
}

fn nonEmptyRawEnv(name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(name) orelse return null;
    return if (nonEmpty(raw) != null) raw else null;
}

fn nonEmpty(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

fn writeStderr(text: []const u8) !void {
    try std.Io.File.stderr().writeStreamingAll(io_mod.getIo(), text);
}

test "parses CLIProxyAPI login options" {
    const args = [_][:0]const u8{ "--base-url", "https://proxy.example", "--api-key-stdin", "--migrate-from-fx" };
    const parsed = try parseOptions(&args);
    try std.testing.expectEqualStrings("https://proxy.example", parsed.base_url.?);
    try std.testing.expect(parsed.api_key_stdin);
    try std.testing.expect(parsed.migrate_from_fx);
}

test "rejects unknown CLIProxyAPI login options" {
    const args = [_][:0]const u8{"--unknown"};
    try std.testing.expectError(error.InvalidArguments, parseOptions(&args));
}

test "maps insecure endpoint and injected key login failures" {
    try std.testing.expectEqualStrings(
        "nfx login: CLIProxyAPI requires HTTPS outside localhost; nothing was saved\n",
        loginErrorMessage(error.InsecureCliproxyBaseUrl),
    );
    try std.testing.expectEqualStrings(
        "nfx login: CLIProxyAPI API key contains unsupported control characters; nothing was saved\n",
        loginErrorMessage(error.InvalidCliproxyApiKey),
    );
}

test "custom provider setup contract maps validation failures without saving" {
    try std.testing.expectEqual(
        connection_setup.Result.invalid_base_url,
        try configureConnection(null, std.testing.allocator, "ftp://proxy.example", "secret"),
    );
    try std.testing.expectEqual(
        connection_setup.Result.insecure_base_url,
        try configureConnection(null, std.testing.allocator, "http://proxy.example", "secret"),
    );
    try std.testing.expectEqual(
        connection_setup.Result.invalid_api_key,
        try configureConnection(null, std.testing.allocator, config.default_base_url, "secret\r\n"),
    );
}
