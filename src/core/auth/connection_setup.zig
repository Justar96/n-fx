const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Result = enum {
    saved,
    authentication_failed,
    connection_failed,
    validation_failed,
    invalid_base_url,
    insecure_base_url,
    invalid_api_key,
    store_failed,
    unavailable,
};

pub const ConfigureFn = *const fn (
    ?*anyopaque,
    Allocator,
    []const u8,
    []const u8,
) Allocator.Error!Result;
pub const ConfiguredFn = *const fn (?*anyopaque) bool;

pub const Provider = struct {
    ctx: ?*anyopaque = null,
    default_base_url: []const u8 = "",
    configure_fn: ConfigureFn = unavailable,
    configured_fn: ConfiguredFn = notConfigured,

    pub fn configure(
        self: Provider,
        alloc: Allocator,
        base_url: []const u8,
        api_key: []const u8,
    ) Allocator.Error!Result {
        return self.configure_fn(self.ctx, alloc, base_url, api_key);
    }

    pub fn isConfigured(self: Provider) bool {
        return self.configured_fn(self.ctx);
    }
};

fn unavailable(_: ?*anyopaque, _: Allocator, _: []const u8, _: []const u8) Allocator.Error!Result {
    return .unavailable;
}

fn notConfigured(_: ?*anyopaque) bool {
    return false;
}

pub const unavailable_provider: Provider = .{};
