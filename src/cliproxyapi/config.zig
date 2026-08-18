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

const FileConfig = struct {
    base_url: ?[]u8 = null,
    api_key: ?[]u8 = null,

    fn deinit(self: *FileConfig, alloc: Allocator) void {
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
    const path = try std.fs.path.join(alloc, &.{ home, ".fx", "settings.json" });
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_config_bytes);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get("provider") orelse return null;
    if (value != .string) return null;
    const name = trimmedNonEmpty(value.string) orelse return null;
    return @as(?[]u8, try alloc.dupe(u8, name));
}

pub fn load(alloc: Allocator) !Connection {
    var file_config = try loadFirstConfigFile(alloc);
    defer file_config.deinit(alloc);

    const base_source = nonEmptyEnv(base_url_env) orelse file_config.base_url orelse default_base_url;
    const api_key_source = nonEmptyEnv(api_key_env) orelse file_config.api_key orelse return error.MissingCliproxyApiKey;

    const normalized = try normalizeBaseUrl(alloc, base_source);
    errdefer alloc.free(normalized);
    const inference_url = try std.fmt.allocPrint(alloc, "{s}/backend-api/codex/responses", .{normalized});
    errdefer alloc.free(inference_url);
    const models_url = try std.fmt.allocPrint(alloc, "{s}/v1/models?client_version=fx", .{normalized});
    errdefer alloc.free(models_url);

    return .{
        .base_url = normalized,
        .api_key = try alloc.dupe(u8, api_key_source),
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
        &.{ home, ".fx", "cliproxyapi.json" },
        &.{ home, ".pi", "agent", "cliproxyapi.json" },
    };
    for (candidates) |parts| {
        const path = try std.fs.path.join(alloc, parts);
        defer alloc.free(path);
        if (try loadFileConfig(alloc, path)) |config| return config;
    }
    return .{};
}

fn loadFileConfig(alloc: Allocator, path: []const u8) !?FileConfig {
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_config_bytes);
    defer alloc.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCliproxyConfig;

    var result: FileConfig = .{};
    errdefer result.deinit(alloc);
    if (parsed.value.object.get("baseUrl")) |value| {
        if (value != .string) return error.InvalidCliproxyConfig;
        if (trimmedNonEmpty(value.string)) |text| result.base_url = try alloc.dupe(u8, text);
    }
    if (parsed.value.object.get("apiKey")) |value| {
        if (value != .string) return error.InvalidCliproxyConfig;
        if (trimmedNonEmpty(value.string)) |text| result.api_key = try alloc.dupe(u8, text);
    }
    return result;
}

fn normalizeBaseUrl(alloc: Allocator, input: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n/");
    if (trimmed.len == 0) return error.InvalidCliproxyBaseUrl;
    const with_scheme = if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://"))
        try alloc.dupe(u8, trimmed)
    else
        try std.fmt.allocPrint(alloc, "http://{s}", .{trimmed});
    defer alloc.free(with_scheme);

    const parsed = std.Uri.parse(with_scheme) catch return error.InvalidCliproxyBaseUrl;
    if (parsed.scheme.len == 0 or parsed.host == null or parsed.user != null or parsed.password != null or parsed.fragment != null)
        return error.InvalidCliproxyBaseUrl;
    if (!std.mem.eql(u8, parsed.scheme, "http") and !std.mem.eql(u8, parsed.scheme, "https"))
        return error.InvalidCliproxyBaseUrl;

    var root = std.mem.trimEnd(u8, with_scheme, "/");
    for ([_][]const u8{ "/backend-api", "/v1" }) |suffix| {
        if (std.mem.endsWith(u8, root, suffix)) {
            root = std.mem.trimEnd(u8, root[0 .. root.len - suffix.len], "/");
            break;
        }
    }
    return alloc.dupe(u8, root);
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
        .{ .input = "https://proxy.example/v1", .expected = "https://proxy.example" },
        .{ .input = "https://proxy.example/backend-api/", .expected = "https://proxy.example" },
    }) |case| {
        const actual = try normalizeBaseUrl(alloc, case.input);
        defer alloc.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "rejects unsafe CLIProxyAPI base URLs" {
    try std.testing.expectError(error.InvalidCliproxyBaseUrl, normalizeBaseUrl(std.testing.allocator, "ftp://proxy.example"));
    try std.testing.expectError(error.InvalidCliproxyBaseUrl, normalizeBaseUrl(std.testing.allocator, "https://user:pass@proxy.example"));
}
