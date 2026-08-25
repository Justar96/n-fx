const std = @import("std");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");

const Allocator = std.mem.Allocator;

pub const provider_env = "FX_PROVIDER";
pub const base_url_env = "CLIPROXYAPI_BASE_URL";
pub const api_key_env = "CLIPROXYAPI_API_KEY";
pub const provider_name = "cliproxyapi";
pub const default_base_url = "http://127.0.0.1:8317";
pub const default_model = "gpt-5.6-sol";
pub const responses_path = "/v1/responses";
pub const root_dir_name = ".nfx";
pub const legacy_root_dir_name = ".fx";
pub const config_file_name = "cliproxyapi.json";
pub const settings_file_name = "settings.json";

const max_config_bytes = 64 * 1024;

pub const Connection = struct {
    base_url: []u8,
    api_key: []u8,
    inference_url: []u8,
    models_url: []u8,

    pub fn deinit(self: *Connection, alloc: Allocator) void {
        alloc.free(self.base_url);
        secret.zeroAndFree(alloc, self.api_key);
        alloc.free(self.inference_url);
        alloc.free(self.models_url);
        self.* = undefined;
    }
};

pub const FileConfig = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,

    pub fn deinit(self: *FileConfig, alloc: Allocator) void {
        if (self.base_url) |value| alloc.free(value);
        if (self.api_key) |value| secret.zeroAndFree(alloc, value);
        self.* = .{};
    }
};

pub fn enabled() bool {
    if (io_mod.getenv(provider_env)) |raw| {
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, raw, " \t\r\n"), provider_name);
    }
    const configured = configuredProviderName(std.heap.page_allocator) catch null;
    if (configured) |name| {
        defer std.heap.page_allocator.free(name);
        return std.ascii.eqlIgnoreCase(name, provider_name);
    }
    return nonEmptyEnv(base_url_env) != null or nonEmptyEnv(api_key_env) != null;
}

fn configuredProviderName(alloc: Allocator) !?[]u8 {
    const home = io_mod.getenv("HOME") orelse return null;
    for ([_][]const u8{ root_dir_name, legacy_root_dir_name }) |root| {
        const path = try std.fs.path.join(alloc, &.{ home, root, settings_file_name });
        defer alloc.free(path);
        if (try readConfiguredProviderName(alloc, path)) |name| return name;
    }
    return null;
}

fn readConfiguredProviderName(alloc: Allocator, path: []const u8) !?[]u8 {
    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), path, .read_only) catch |err| switch (err) {
        error.FileNotFound, error.DurablePathUnsafe => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_config_bytes);
    defer secret.zeroAndFree(alloc, bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("provider") orelse return null;
    if (value != .string) return null;
    const name = trimmedNonEmpty(value.string) orelse return null;
    return try alloc.dupe(u8, name);
}

pub fn load(alloc: Allocator) !Connection {
    var file_config = try loadFirstConfigFile(alloc);
    defer file_config.deinit(alloc);

    const base_source = nonEmptyRawEnv(base_url_env) orelse file_config.base_url orelse default_base_url;
    const api_key_source = nonEmptyRawEnv(api_key_env) orelse file_config.api_key orelse return error.MissingCliproxyApiKey;
    const api_key = try validateApiKey(api_key_source);

    const normalized = try normalizeBaseUrl(alloc, base_source);
    errdefer alloc.free(normalized);
    const inference_url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ normalized, responses_path });
    errdefer alloc.free(inference_url);
    const models_url = try std.fmt.allocPrint(alloc, "{s}/v1/models?client_version=nfx", .{normalized});
    errdefer alloc.free(models_url);

    return .{
        .base_url = normalized,
        .api_key = try alloc.dupe(u8, api_key),
        .inference_url = inference_url,
        .models_url = models_url,
    };
}

pub fn loadApiKey(alloc: Allocator) !?[]u8 {
    if (!enabled()) return null;
    var connection = load(alloc) catch |err| switch (err) {
        error.MissingCliproxyApiKey => return null,
        else => return err,
    };
    defer {
        alloc.free(connection.base_url);
        alloc.free(connection.inference_url);
        alloc.free(connection.models_url);
    }
    const key = connection.api_key;
    connection.api_key = &.{};
    return key;
}

fn loadFirstConfigFile(alloc: Allocator) !FileConfig {
    const home = io_mod.getenv("HOME") orelse return .{};
    const candidates = [_][]const []const u8{
        &.{ home, root_dir_name, config_file_name },
        &.{ home, legacy_root_dir_name, config_file_name },
        &.{ home, ".pi", "agent", config_file_name },
    };
    for (candidates) |parts| {
        const path = try std.fs.path.join(alloc, parts);
        defer alloc.free(path);
        if (try loadFileConfig(alloc, path)) |config| return config;
    }
    return .{};
}

pub fn loadLegacy(alloc: Allocator) !?FileConfig {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    const path = try std.fs.path.join(alloc, &.{ home, legacy_root_dir_name, config_file_name });
    defer alloc.free(path);
    return loadFileConfig(alloc, path);
}

pub fn save(alloc: Allocator, base_url: []const u8, api_key: []const u8) !void {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    return saveAtHome(alloc, home, base_url, api_key);
}

fn saveAtHome(alloc: Allocator, home: []const u8, base_url: []const u8, api_key: []const u8) !void {
    const normalized = try normalizeBaseUrl(alloc, base_url);
    defer alloc.free(normalized);
    const key = try validateApiKey(api_key);

    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();
    var nfx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, root_dir_name);
    defer nfx_dir.close();

    var config_out: std.Io.Writer.Allocating = .init(alloc);
    defer {
        @memset(config_out.writer.buffer, 0);
        config_out.deinit();
    }
    try std.json.Stringify.value(.{ .baseUrl = normalized, .apiKey = key }, .{ .whitespace = .indent_2 }, &config_out.writer);
    try config_out.writer.writeByte('\n');

    const settings_bytes = try settingsWithProvider(alloc, &nfx_dir);
    defer alloc.free(settings_bytes);

    // Write credentials first. If the settings write fails, nfx does not select a
    // provider whose credential file is missing.
    try io_mod.durableReplaceVerified(alloc, &nfx_dir, config_file_name, config_out.written());
    try io_mod.durableReplaceVerified(alloc, &nfx_dir, settings_file_name, settings_bytes);
}

fn settingsWithProvider(alloc: Allocator, nfx_dir: *io_mod.VerifiedDir) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var root: std.json.Value = .{ .object = .{} };
    if (io_mod.openExistingRegularFile(nfx_dir.dir, settings_file_name, .read_only)) |file_value| {
        var file = file_value;
        defer file.close(io_mod.getIo());
        const bytes = try io_mod.readFileToEnd(arena_alloc, &file, max_config_bytes);
        const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, bytes, .{}) catch return error.InvalidNfxSettings;
        if (parsed.value != .object) return error.InvalidNfxSettings;
        root = parsed.value;
    } else |err| switch (err) {
        error.FileNotFound => {},
        error.DurablePathUnsafe => return error.InvalidNfxSettings,
        else => return err,
    }
    try root.object.put(arena_alloc, "provider", .{ .string = provider_name });

    var output: std.Io.Writer.Allocating = .init(alloc);
    errdefer output.deinit();
    try std.json.Stringify.value(root, .{ .whitespace = .indent_2 }, &output.writer);
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}

fn loadFileConfig(alloc: Allocator, path: []const u8) !?FileConfig {
    var file = io_mod.openExistingRegularFile(
        std.Io.Dir.cwd(),
        path,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.DurablePathUnsafe => return error.InvalidCliproxyConfig,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_config_bytes);
    defer secret.zeroAndFree(alloc, bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCliproxyConfig;

    var result: FileConfig = .{};
    errdefer result.deinit(alloc);
    if (parsed.value.object.get("baseUrl")) |value| {
        if (value != .string) return error.InvalidCliproxyConfig;
        if (containsControl(value.string)) return error.InvalidCliproxyConfig;
        if (trimmedNonEmpty(value.string)) |text| result.base_url = try alloc.dupe(u8, text);
    }
    if (parsed.value.object.get("apiKey")) |value| {
        if (value != .string) return error.InvalidCliproxyConfig;
        const text = validateApiKey(value.string) catch return error.InvalidCliproxyConfig;
        result.api_key = try alloc.dupe(u8, text);
    }
    return result;
}

pub fn normalizeBaseUrl(alloc: Allocator, input: []const u8) ![]u8 {
    if (containsControl(input)) return error.InvalidCliproxyBaseUrl;
    const trimmed = std.mem.trim(u8, input, " \t\r\n/");
    if (trimmed.len == 0) return error.InvalidCliproxyBaseUrl;
    const with_scheme = if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://"))
        try alloc.dupe(u8, trimmed)
    else
        try std.fmt.allocPrint(alloc, "http://{s}", .{trimmed});
    defer alloc.free(with_scheme);

    const parsed = std.Uri.parse(with_scheme) catch return error.InvalidCliproxyBaseUrl;
    if (parsed.scheme.len == 0 or parsed.host == null or parsed.user != null or parsed.password != null or parsed.query != null or parsed.fragment != null)
        return error.InvalidCliproxyBaseUrl;
    if (!std.mem.eql(u8, parsed.scheme, "http") and !std.mem.eql(u8, parsed.scheme, "https"))
        return error.InvalidCliproxyBaseUrl;
    if (std.mem.eql(u8, parsed.scheme, "http") and !isLoopbackHost(parsed))
        return error.InsecureCliproxyBaseUrl;

    var root = std.mem.trimEnd(u8, with_scheme, "/");
    for ([_][]const u8{ "/backend-api", "/v1" }) |suffix| {
        if (std.mem.endsWith(u8, root, suffix)) {
            root = std.mem.trimEnd(u8, root[0 .. root.len - suffix.len], "/");
            break;
        }
    }
    return alloc.dupe(u8, root);
}

pub fn validateApiKey(raw: []const u8) ![]const u8 {
    if (containsControl(raw)) return error.InvalidCliproxyApiKey;
    return trimmedNonEmpty(raw) orelse error.MissingCliproxyApiKey;
}

fn isLoopbackHost(uri: std.Uri) bool {
    const host_component = uri.host orelse return false;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return false;
    return std.mem.eql(u8, host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.mem.eql(u8, host, "[::1]");
}

fn containsControl(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

fn nonEmptyRawEnv(name: []const u8) ?[]const u8 {
    const raw = io_mod.getenv(name) orelse return null;
    return if (trimmedNonEmpty(raw) != null) raw else null;
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    return trimmedNonEmpty(io_mod.getenv(name) orelse return null);
}

fn trimmedNonEmpty(raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

test "normalizes CLIProxyAPI endpoint variants" {
    const alloc = std.testing.allocator;
    for ([_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "127.0.0.1:8317", .expected = "http://127.0.0.1:8317" },
        .{ .input = "http://[::1]:8317/v1", .expected = "http://[::1]:8317" },
        .{ .input = "https://proxy.example/v1", .expected = "https://proxy.example" },
        .{ .input = "https://proxy.example/backend-api/", .expected = "https://proxy.example" },
    }) |case| {
        const actual = try normalizeBaseUrl(alloc, case.input);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "uses the public CLIProxyAPI Responses endpoint" {
    try std.testing.expectEqualStrings("/v1/responses", responses_path);
}

test "rejects unsafe CLIProxyAPI base URLs" {
    try std.testing.expectError(error.InvalidCliproxyBaseUrl, normalizeBaseUrl(std.testing.allocator, "ftp://proxy.example"));
    try std.testing.expectError(error.InvalidCliproxyBaseUrl, normalizeBaseUrl(std.testing.allocator, "https://user:pass@proxy.example"));
    try std.testing.expectError(error.InvalidCliproxyBaseUrl, normalizeBaseUrl(std.testing.allocator, "https://proxy.example?token=secret"));
    try std.testing.expectError(error.InvalidCliproxyBaseUrl, normalizeBaseUrl(std.testing.allocator, "https://proxy.example\r\nX-Test: injected"));
    try std.testing.expectError(error.InsecureCliproxyBaseUrl, normalizeBaseUrl(std.testing.allocator, "http://proxy.example"));

    const loopback = try normalizeBaseUrl(std.testing.allocator, "http://localhost:8317/v1");
    defer std.testing.allocator.free(loopback);
    try std.testing.expectEqualStrings("http://localhost:8317", loopback);
}

test "rejects control bytes in CLIProxyAPI credentials" {
    try std.testing.expectError(error.InvalidCliproxyApiKey, validateApiKey("secret\r\nX-Test: injected"));
    try std.testing.expectError(error.InvalidCliproxyApiKey, validateApiKey("secret\x7f"));
    try std.testing.expectEqualStrings("secret", try validateApiKey(" secret "));
}

test "saves private nfx credentials and preserves settings" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var parent = io_mod.VerifiedDir{ .dir = try tmp.dir.openDir(io_mod.getIo(), ".", .{ .iterate = true }) };
    defer parent.close();
    var nfx = try io_mod.openOrCreateVerifiedPrivateDir(&parent, root_dir_name);
    defer nfx.close();
    try io_mod.durableReplaceVerified(alloc, &nfx, settings_file_name, "{\"model\":\"gpt-test\"}\n");

    try saveAtHome(alloc, home, "https://proxy.example/v1", "secret-key");

    const dir_stat = try nfx.dir.stat(io_mod.getIo());
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), dir_stat.permissions.toMode() & 0o777);
    for ([_][]const u8{ config_file_name, settings_file_name }) |name| {
        const file_stat = try nfx.dir.statFile(io_mod.getIo(), name, .{});
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), file_stat.permissions.toMode() & 0o777);
    }

    var settings_file = try nfx.dir.openFile(io_mod.getIo(), settings_file_name, .{});
    defer settings_file.close(io_mod.getIo());
    const settings = try io_mod.readFileToEnd(alloc, &settings_file, max_config_bytes);
    defer alloc.free(settings);
    try std.testing.expect(std.mem.find(u8, settings, "\"provider\": \"cliproxyapi\"") != null);
    try std.testing.expect(std.mem.find(u8, settings, "\"model\": \"gpt-test\"") != null);
}
