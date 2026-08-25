const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const agent_stream = @import("../core/agent/stream_provider.zig");
const oauth_transport = @import("../core/auth/oauth_transport.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const provider_set = @import("../core/gateway/provider_set.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const image_attachments = @import("../core/images/image_attachments.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const model_tool_schema = @import("../core/tooling/model_tool_schema.zig");
const types = @import("../core/shared/types.zig");
const gateway_client = @import("../gateway/client.zig");
const openai_codex = @import("../gateway/openai_codex.zig");

const Allocator = std.mem.Allocator;
const max_error_body_bytes: usize = 1024 * 1024;
const max_catalog_bytes: usize = 4 * 1024 * 1024;
const max_catalog_models: usize = 1024;
const max_model_id_bytes: usize = 1024;
const transfer_buffer_bytes: usize = 256 * 1024;
const connect_timeout_ms: i64 = 30_000;
const catalog_timeout_ms: i64 = 30_000;
const user_agent = "nfx-cliproxyapi/" ++ build_options.app_version;

pub const models_path = "/v1/models?client_version=nfx";
pub const retry_count: usize = 1;

pub const agent_stream_provider = agent_stream.Provider{
    .stream_fn = streamResponse,
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchModelCatalog,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub fn gatewayProvider() gateway_provider.Provider {
    return .{
        .oauth_transport = oauth_transport.unavailable_provider,
        .chat_url = .{ .resolve_fn = resolveChatUrl },
    };
}

pub fn providerBundle() provider_set.Bundle {
    return .{
        .capabilities = .{ .native_images = true },
        .agent_stream = agent_stream_provider,
        .cli_model_catalog = cli_model_catalog_provider,
        .model_catalog = model_catalog_provider,
        .credits = .{ .fetch_fn = fetchCredits },
    };
}

fn resolveChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return fallback;
}

fn buildRequest(alloc: Allocator, request: agent_stream.RequestData) ![]u8 {
    if (request.response_format != null) {
        return error.CliproxyStructuredResponseUnsupported;
    }
    var normalized = request;
    normalized.model = normalizeModel(request.model);
    const payload = try openai_codex.buildRequest(alloc, normalized);
    const max_output_tokens = request.max_output_tokens orelse return payload;
    defer alloc.free(payload);

    std.debug.assert(payload.len > 0 and payload[payload.len - 1] == '}');
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll(payload[0 .. payload.len - 1]);
    try out.writer.print(",\"max_output_tokens\":{d}}}", .{max_output_tokens});
    return out.toOwnedSlice();
}

fn normalizeModel(model: []const u8) []const u8 {
    const prefix = "openai/";
    return if (std.mem.startsWith(u8, model, prefix)) model[prefix.len..] else model;
}

fn streamResponse(_: ?*anyopaque, alloc: Allocator, request: agent_stream.ModelRequest) !agent_stream.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const payload = try buildRequest(alloc, request.data());
    defer alloc.free(payload);
    var connection = try config.load(alloc);
    defer connection.deinit(alloc);

    var result = streamPrepared(alloc, request, connection.inference_url, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (requestDeadlineExpired(request)) return error.Timeout;
        request.attempt_evidence.network_failure = gateway_client.networkFailureEvidence(err, request.delivery.load());
        return err;
    };
    if (requestDeadlineExpired(request)) {
        result.deinit(alloc);
        return error.Timeout;
    }
    return result;
}

fn requestDeadlineExpired(request: agent_stream.ModelRequest) bool {
    const deadline = request.deadline orelse return false;
    const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    return !std.Io.Clock.Timestamp.compare(now, .lt, deadline);
}

const OpenedRequest = struct {
    request: ?std.http.Client.Request,

    pub fn deinit(self: *OpenedRequest, _: Allocator) void {
        if (self.request) |*request| request.deinit();
        self.request = null;
    }

    pub fn take(self: *OpenedRequest) std.http.Client.Request {
        const request = self.request.?;
        self.request = null;
        return request;
    }
};

const OpenRequestOperation = struct {
    client: *std.http.Client,
    uri: std.Uri,
    auth_header: []const u8,

    pub fn run(self: *@This()) !OpenedRequest {
        return .{
            .request = try self.client.request(.POST, self.uri, .{
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                    .authorization = .{ .override = self.auth_header },
                    .accept_encoding = .omit,
                    .user_agent = .{ .override = user_agent },
                },
                .extra_headers = &.{
                    .{ .name = "Accept", .value = "text/event-stream" },
                    .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
                    .{ .name = "originator", .value = "nfx" },
                },
                .keep_alive = false,
                // Never replay the CLIProxy credential to a redirect target.
                .redirect_behavior = .unhandled,
            }),
        };
    }
};

fn streamPrepared(
    alloc: Allocator,
    request: agent_stream.ModelRequest,
    endpoint: []const u8,
    payload: []const u8,
) !agent_stream.Result {
    return streamPreparedInner(alloc, request, endpoint, payload) catch |err| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (requestDeadlineExpired(request)) return error.Timeout;
        return err;
    };
}

fn streamPreparedInner(
    alloc: Allocator,
    request: agent_stream.ModelRequest,
    endpoint: []const u8,
    payload: []const u8,
) !agent_stream.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const credential = try config.validateApiKey(request.credential.secret);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{credential});
    defer secret.zeroAndFree(alloc, auth_header);
    const uri = std.Uri.parse(endpoint) catch return error.InvalidCliproxyInferenceUrl;

    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    var open_operation = OpenRequestOperation{
        .client = &client,
        .uri = uri,
        .auth_header = auth_header,
    };
    var connect_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(connect_timeout_ms),
    });
    if (request.deadline) |deadline| {
        if (std.Io.Clock.Timestamp.compare(deadline, .lt, connect_deadline)) {
            connect_deadline = deadline;
        }
    }

    try request.admission.admit();
    var opened = try gateway_client.runBoundedHttpOperation(
        OpenedRequest,
        alloc,
        request.cancel_flag,
        connect_deadline,
        &open_operation,
    );
    var http_request = opened.take();
    defer http_request.deinit();

    var cancel_watch_done = std.atomic.Value(bool).init(false);
    const cancel_watcher = if (http_request.connection) |connection|
        if (request.deadline) |deadline|
            try gateway_client.spawnHttpCancelWatcherBounded(
                &cancel_watch_done,
                request.cancel_flag,
                deadline,
                connection.stream_writer.stream,
            )
        else
            try gateway_client.spawnHttpCancelWatcher(
                &cancel_watch_done,
                request.cancel_flag,
                connection.stream_writer.stream,
            )
    else
        null;
    defer {
        cancel_watch_done.store(true, .seq_cst);
        if (cancel_watcher) |thread| thread.join();
    }
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    http_request.transfer_encoding = .{ .content_length = payload.len };
    var send_buffer: [8192]u8 = undefined;
    request.delivery.markPossiblySent();
    var body_writer = try http_request.sendBodyUnflushed(&send_buffer);
    try body_writer.writer.writeAll(payload);
    try body_writer.end();
    if (http_request.connection) |connection| try connection.flush();
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    var response = try http_request.receiveHead(&.{});
    if (response.head.status != .ok) {
        var transfer: [16 * 1024]u8 = undefined;
        const reader = response.reader(&transfer);
        const body = try readErrorBody(alloc, reader);
        return .{ .failed = .{
            .kind = failureKind(response.head.status),
            .detail = body,
            .ownership = .owned,
        } };
    }

    var transfer_buffer: [transfer_buffer_bytes]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    var events = request.events;
    const completion = try openai_codex.consumeResponsesSse(
        alloc,
        reader,
        &events,
        request.cancel_flag,
        request.content_capture_limit,
    );
    return .{ .completed = .{
        .completion = completion,
        .usage = .{ .immediate = null },
        .ownership = .owned,
    } };
}

fn readErrorBody(alloc: Allocator, reader: anytype) ![]u8 {
    const bounded_body = reader.allocRemaining(alloc, .limited(max_error_body_bytes + 1)) catch |err| switch (err) {
        error.StreamTooLong => return alloc.dupe(u8, "CLIProxyAPI error response exceeded the local limit"),
        else => return err,
    };
    if (bounded_body.len <= max_error_body_bytes) return bounded_body;
    alloc.free(bounded_body);
    return alloc.dupe(u8, "CLIProxyAPI error response exceeded the local limit");
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn failureKind(status: std.http.Status) agent_stream.FailureKind {
    return switch (status) {
        .bad_request => .invalid_request,
        .unauthorized => .unauthorized,
        .forbidden => .forbidden,
        .payload_too_large => .request_too_large,
        .too_many_requests => .rate_limited,
        .internal_server_error => .server_error,
        .bad_gateway => .bad_gateway,
        .service_unavailable => .unavailable,
        .gateway_timeout => .gateway_timeout,
        else => .provider_error,
    };
}

fn fetchModelCatalog(_: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    var connection = config.load(alloc) catch return .{ .failure = .{ .category = .runtime } };
    defer connection.deinit(alloc);
    return fetchCatalogUrl(alloc, connection.models_url, connection.api_key, input.cancel_flag);
}

const CatalogResponse = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *CatalogResponse, alloc: Allocator) void {
        alloc.free(self.body);
        self.* = undefined;
    }
};

const CatalogFetchOperation = struct {
    alloc: Allocator,
    url: []const u8,
    api_key: []const u8,

    pub fn run(self: *@This()) !CatalogResponse {
        const auth_header = try std.fmt.allocPrint(self.alloc, "Bearer {s}", .{self.api_key});
        defer secret.zeroAndFree(self.alloc, auth_header);
        const body_buffer = try self.alloc.alloc(u8, max_catalog_bytes + 1);
        defer self.alloc.free(body_buffer);
        var body_writer = std.Io.Writer.fixed(body_buffer);
        var client: std.http.Client = .{ .allocator = self.alloc, .io = io_mod.getIo() };
        defer client.deinit();
        const response = client.fetch(.{
            .location = .{ .url = self.url },
            .method = .GET,
            .headers = .{
                .authorization = .{ .override = auth_header },
                .user_agent = .{ .override = user_agent },
                .accept_encoding = .omit,
            },
            .extra_headers = &.{.{ .name = "accept", .value = "application/json" }},
            .response_writer = &body_writer,
            .redirect_behavior = .unhandled,
        }) catch |err| switch (err) {
            error.WriteFailed => return error.CliproxyCatalogTooLarge,
            else => return err,
        };
        const body = body_writer.buffered();
        try validateCatalogBodySize(body.len);
        return .{ .status = response.status, .body = try self.alloc.dupe(u8, body) };
    }
};

fn validateCatalogBodySize(size: usize) !void {
    if (size > max_catalog_bytes) return error.CliproxyCatalogTooLarge;
}

fn fetchCatalogResponse(
    alloc: Allocator,
    url: []const u8,
    api_key: []const u8,
    cancel_flag: *std.atomic.Value(bool),
) !CatalogResponse {
    const credential = try config.validateApiKey(api_key);
    var operation = CatalogFetchOperation{
        .alloc = alloc,
        .url = url,
        .api_key = credential,
    };
    return gateway_client.runBoundedHttpOperation(
        CatalogResponse,
        alloc,
        cancel_flag,
        std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(catalog_timeout_ms),
        }),
        &operation,
    );
}

fn fetchCatalogUrl(
    alloc: Allocator,
    url: []const u8,
    api_key: []const u8,
    input_cancel_flag: ?*std.atomic.Value(bool),
) Allocator.Error!model_catalog.ProviderResult {
    var fallback_cancel = std.atomic.Value(bool).init(false);
    const cancel_flag = input_cancel_flag orelse &fallback_cancel;
    var response = fetchCatalogResponse(alloc, url, api_key, cancel_flag) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return .{ .failure = .{
            .category = if (err == error.Cancelled) .cancellation else if (err == error.CliproxyCatalogTooLarge) .malformed_response else .transport,
            .retryable = err != error.Cancelled and err != error.CliproxyCatalogTooLarge,
        } };
    };
    defer response.deinit(alloc);
    if (response.status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    return parseCatalog(alloc, response.body) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failure = .{ .category = .malformed_response } },
    };
}

pub fn validateCredentials(alloc: Allocator, base_url: []const u8, api_key: []const u8) !void {
    const normalized = try config.normalizeBaseUrl(alloc, base_url);
    defer alloc.free(normalized);
    const models_url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ normalized, models_path });
    defer alloc.free(models_url);
    const credential = try config.validateApiKey(api_key);
    var cancel_flag = std.atomic.Value(bool).init(false);
    var response = fetchCatalogResponse(alloc, models_url, credential, &cancel_flag) catch |err| switch (err) {
        error.CliproxyCatalogTooLarge => return error.CliproxyValidationFailed,
        else => return error.CliproxyConnectionFailed,
    };
    defer response.deinit(alloc);
    if (response.status == .unauthorized or response.status == .forbidden) return error.CliproxyAuthenticationFailed;
    if (response.status != .ok) return error.CliproxyValidationFailed;
    var catalog_result = parseCatalog(alloc, response.body) catch return error.CliproxyValidationFailed;
    switch (catalog_result) {
        .catalog => |*catalog| model_catalog.freeModelCatalog(alloc, catalog),
        .failure => return error.CliproxyValidationFailed,
    }
}

fn parseCatalog(alloc: Allocator, bytes: []const u8) !model_catalog.ProviderResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCliproxyCatalog;
    const models_value = parsed.value.object.get("models") orelse parsed.value.object.get("data") orelse return error.InvalidCliproxyCatalog;
    if (models_value != .array or models_value.array.items.len > max_catalog_models) return error.InvalidCliproxyCatalog;

    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (models_value.array.items) |model| {
        const entry = try parseCatalogEntry(alloc, model) orelse continue;
        entries.append(alloc, entry) catch |err| {
            model_catalog.freeModelCatalogEntry(alloc, entry);
            return err;
        };
    }
    return .{ .catalog = entries };
}

fn parseCatalogEntry(alloc: Allocator, model: std.json.Value) !?model_catalog.ModelCatalogEntry {
    if (model != .object) return null;
    if (stringField(model.object, "visibility")) |visibility| {
        if (std.ascii.eqlIgnoreCase(visibility, "hide")) return null;
    }
    const id = stringField(model.object, "slug") orelse stringField(model.object, "id") orelse return null;
    if (!validModelId(id)) return error.InvalidCliproxyCatalog;

    var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
    errdefer efforts.deinit(alloc);
    if (model.object.get("supported_reasoning_levels")) |levels| if (levels == .array) {
        for (levels.array.items) |level| {
            if (efforts.items.len >= types.ReasoningEffort.max_options) break;
            const effort = if (level == .string) level.string else if (level == .object) stringField(level.object, "effort") orelse continue else continue;
            const parsed_effort = types.ReasoningEffort.parse(effort) orelse continue;
            try efforts.append(alloc, parsed_effort);
        }
    };

    var has_vision = false;
    if (model.object.get("input_modalities")) |modalities| if (modalities == .array) {
        for (modalities.array.items) |modality| {
            if (modality == .string and std.ascii.eqlIgnoreCase(modality.string, "image")) has_vision = true;
        }
    };
    const supports_fast = if (model.object.get("service_tiers")) |tiers| tiers == .array and tiers.array.items.len > 0 else false;
    const context_window = unsignedField(model.object, "context_window") orelse unsignedField(model.object, "max_context_window") orelse 0;
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_model_type = try alloc.dupe(u8, "language");
    errdefer alloc.free(owned_model_type);
    return .{
        .id = owned_id,
        .model_type = owned_model_type,
        .has_tool_use = true,
        .has_reasoning = efforts.items.len > 0,
        .reasoning_efforts = efforts,
        .supports_fast_mode = supports_fast,
        .has_vision = has_vision,
        .has_file_input = has_vision,
        .context_window = @intCast(@min(context_window, std.math.maxInt(u32))),
        .max_tokens = 16_384,
    };
}

fn validModelId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_model_id_bytes) return false;
    for (id) |byte| if (byte <= 0x20 or byte == 0x7f) return false;
    return true;
}

fn fetchCliModelCatalog(_: ?*anyopaque, alloc: Allocator, input: gateway_provider.CliModelCatalogInput) gateway_provider.CliModelCatalogResult {
    const result = fetchModelCatalog(null, alloc, .{
        .access = input.access,
        .endpoint = input.endpoint,
        .cancel_flag = input.cancel_flag,
    }) catch return .{ .failure = .{
        .access = .init(input.access),
        .anonymous_fallback_used = false,
        .failure = .{ .category = .resource_exhausted },
    } };
    return switch (result) {
        .catalog => |catalog| blk: {
            var mutable = catalog;
            const ids = model_catalog.projectModelIds(alloc, mutable.items) catch {
                model_catalog.freeModelCatalog(alloc, &mutable);
                break :blk .{ .failure = .{
                    .access = .init(input.access),
                    .anonymous_fallback_used = false,
                    .failure = .{ .category = .resource_exhausted },
                } };
            };
            model_catalog.freeModelCatalog(alloc, &mutable);
            break :blk .{ .loaded = .{
                .ids = ids,
                .provenance = .{ .access = .init(input.access) },
            } };
        },
        .failure => |failure| .{ .failure = .{
            .access = .init(input.access),
            .anonymous_fallback_used = false,
            .failure = failure,
        } },
    };
}

fn fetchCredits(_: ?*anyopaque, alloc: Allocator, _: gateway_provider.CreditsLookupInput) output_contracts.CreditsSnapshot {
    return .{ .err_message = alloc.dupe(u8, "CLIProxyAPI does not expose the Vercel credits endpoint") catch null };
}

test "provider bundle keeps credentials on CLIProxy-owned routes" {
    const gateway = gatewayProvider();
    const bundle = providerBundle();

    try std.testing.expect(gateway.oauth_transport.execute_fn == oauth_transport.unavailable_provider.execute_fn);
    try std.testing.expect(bundle.agent_stream.?.stream_fn == agent_stream_provider.stream_fn);
    try std.testing.expect(bundle.cli_model_catalog != null);
    try std.testing.expect(bundle.cli_model_catalog.?.fetch_fn == cli_model_catalog_provider.fetch_fn);
    try std.testing.expect(bundle.model_catalog != null);
    try std.testing.expect(bundle.model_catalog.?.fetch_fn == model_catalog_provider.fetch_fn);
    try std.testing.expect(bundle.credits != null);

    // These routes belong to Vercel AI Gateway and receive provider credentials
    // when enabled. CLIProxyAPI must never inherit them implicitly.
    try std.testing.expect(bundle.permission_reviewer == null);
    try std.testing.expect(bundle.fx_search == null);
    try std.testing.expect(bundle.deferred_usage == null);
    try std.testing.expect(bundle.auth_strategy == null);
    try std.testing.expect(bundle.presentation == null);
    try std.testing.expect(!bundle.capabilities.fx_search);
    try std.testing.expect(!bundle.capabilities.vision_fallback);
    try std.testing.expect(!bundle.capabilities.deferred_usage);
    try std.testing.expect(bundle.capabilities.native_images);

    const fallback = bundle.fallbackModelCapabilities("anthropic/claude-opus-4.8");
    try std.testing.expectEqual(@as(?u32, null), fallback.context_window);
    try std.testing.expect(!fallback.prompt_caching);
    try std.testing.expectEqual(@as(?bool, null), fallback.parallel_tool_calls);
}

test "builds OpenAI Responses request from fx messages and tools" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "system" },
        .{ .role = .user, .content = "hello" },
    };
    const tool_names = [_][]const u8{"read_file"};
    const tools = [_]model_tool_schema.FunctionSchema{.{
        .name = "read_file",
        .description = "Read",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "openai/gpt-5.6-sol",
        .messages = &messages,
        .tools = .{
            .advertised_names = &tool_names,
            .advertised_functions = &tools,
        },
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high"), .fast = true },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.6-sol\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"system\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\",\"properties\":{}}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\":\"priority\"") != null);
}

test "builds CLIProxy Responses request with verified image content" {
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "Describe it." }};
    const images = [_]image_attachments.VerifiedSnapshot{.{
        .bytes = @constCast(&[_]u8{ 1, 2, 3, 4 }),
        .media_type = "image/png",
    }};
    const body = try buildRequest(std.testing.allocator, .{
        .model = "openai/gpt-5.6-sol",
        .messages = &messages,
        .tool_choice = .none,
        .provider_options = .{},
        .verified_images = &images,
    });
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.find(u8, body, "\"type\":\"input_image\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "data:image/png;base64,AQIDBA==") != null);
}

test "rejects control bytes in CLIProxy model identifiers" {
    try std.testing.expectError(error.InvalidOpenAICodexModel, buildRequest(std.testing.allocator, .{
        .model = "openai/gpt-5.6-sol\r\nX-Test: injected",
        .messages = &.{},
        .tool_choice = .none,
        .provider_options = .{},
    }));
}

test "parses Responses SSE content, tools, and usage" {
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        fn emit(raw: *anyopaque, event: agent_stream.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .content_delta => |bytes| self.content.appendSlice(std.testing.allocator, bytes) catch unreachable,
                else => {},
            }
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    const sse =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}\n\n";
    var reader: std.Io.Reader = .fixed(sse);
    var events = agent_stream.EventSink{ .context = &capture, .emit_fn = Capture.emit };
    const completion = try openai_codex.consumeResponsesSse(
        std.testing.allocator,
        &reader,
        &events,
        &cancelled,
        null,
    );
    var result = agent_stream.Result{ .completed = .{
        .completion = completion,
        .usage = .{ .immediate = null },
        .ownership = .owned,
    } };
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", result.completed.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), result.completed.completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", result.completed.completion.tool_calls[0].id);
    try std.testing.expectEqual(@as(?u64, 10), result.completed.completion.usage.input_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, result.completed.completion.finish_reason.?);
}

test "CLIProxy Responses emits first delta before reading stream completion" {
    const Capture = struct {
        saw_delta: bool = false,
        fn emit(raw: *anyopaque, event: agent_stream.Event) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (event == .content_delta) self.saw_delta = true;
        }
    };
    const GatedReader = struct {
        capture: *Capture,
        step: usize = 0,

        pub fn takeDelimiter(self: *@This(), _: u8) error{ StreamTooLong, ReadFailed }!?[]const u8 {
            defer self.step += 1;
            return switch (self.step) {
                0 => "data: {\"type\":\"response.output_text.delta\",\"delta\":\"first\"}",
                1 => if (self.capture.saw_delta)
                    "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}"
                else
                    error.ReadFailed,
                else => null,
            };
        }

        pub fn buffered(_: *@This()) []const u8 {
            return "";
        }

        pub fn tossBuffered(_: *@This()) void {}
    };

    var capture = Capture{};
    var reader = GatedReader{ .capture = &capture };
    var cancelled = std.atomic.Value(bool).init(false);
    var events = agent_stream.EventSink{ .context = &capture, .emit_fn = Capture.emit };
    const completion = try openai_codex.consumeResponsesSse(
        std.testing.allocator,
        &reader,
        &events,
        &cancelled,
        3,
    );
    defer {
        if (completion.content) |content| std.testing.allocator.free(@constCast(content));
        types.freeToolCallSlice(std.testing.allocator, @constCast(completion.tool_calls));
        if (completion.generation_id) |id| std.testing.allocator.free(@constCast(id));
        if (completion.provider_state_json) |state| std.testing.allocator.free(@constCast(state));
    }
    try std.testing.expect(capture.saw_delta);
    try std.testing.expectEqualStrings("fir", completion.content.?);
}

test "CLIProxy error response bodies are capped at one MiB" {
    const exact = try std.testing.allocator.alloc(u8, max_error_body_bytes);
    defer std.testing.allocator.free(exact);
    @memset(exact, 'e');
    var exact_reader: std.Io.Reader = .fixed(exact);
    const exact_body = try readErrorBody(std.testing.allocator, &exact_reader);
    defer std.testing.allocator.free(exact_body);
    try std.testing.expectEqual(max_error_body_bytes, exact_body.len);

    const excess = try std.testing.allocator.alloc(u8, max_error_body_bytes + 1);
    defer std.testing.allocator.free(excess);
    @memset(excess, 'e');
    var excess_reader: std.Io.Reader = .fixed(excess);
    const excess_body = try readErrorBody(std.testing.allocator, &excess_reader);
    defer std.testing.allocator.free(excess_body);
    try std.testing.expectEqualStrings("CLIProxyAPI error response exceeded the local limit", excess_body);
}

test "CLIProxy catalog rejects HTML and injected model ids" {
    try std.testing.expectError(error.SyntaxError, parseCatalog(std.testing.allocator, "<html>ok</html>"));
    try std.testing.expectError(
        error.InvalidCliproxyCatalog,
        parseCatalog(std.testing.allocator, "{\"data\":[{\"id\":\"model\\r\\nX-Test: injected\"}]}"),
    );

    var vision_result = try parseCatalog(
        std.testing.allocator,
        "{\"data\":[{\"id\":\"vision-model\",\"input_modalities\":[\"text\",\"image\"]}]}",
    );
    defer switch (vision_result) {
        .catalog => |*catalog| model_catalog.freeModelCatalog(std.testing.allocator, catalog),
        .failure => {},
    };
    const vision_catalog = switch (vision_result) {
        .catalog => |catalog| catalog,
        .failure => return error.TestExpectedCatalog,
    };
    try std.testing.expectEqual(@as(usize, 1), vision_catalog.items.len);
    try std.testing.expect(vision_catalog.items[0].has_vision);
    try std.testing.expect(vision_catalog.items[0].has_file_input);

    try validateCatalogBodySize(max_catalog_bytes);
    try std.testing.expectError(
        error.CliproxyCatalogTooLarge,
        validateCatalogBodySize(max_catalog_bytes + 1),
    );
}

const StalledResponseFixture = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    server_open: bool = true,
    stopping: std.atomic.Value(bool) = .init(false),
    response_started: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,

    fn init() !@This() {
        var fixture: @This() = .{ .server = undefined };
        var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        fixture.server = try address.listen(fixture.io(), .{ .reuse_address = true });
        return fixture;
    }

    fn start(self: *@This()) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn deinit(self: *@This()) void {
        if (!self.server_open) return;
        self.stopping.store(true, .seq_cst);
        const zio = self.io();
        if (self.thread) |thread| {
            const listener = std.Io.net.Stream{ .socket = self.server.socket };
            listener.shutdown(zio, .both) catch {};
            thread.join();
            self.thread = null;
        }
        self.server.deinit(zio);
        self.server_open = false;
    }

    fn io(self: *@This()) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *@This()) u16 {
        return self.server.socket.address.getPort();
    }

    fn run(self: *@This()) void {
        self.runFallible() catch |err| {
            if (self.stopping.load(.seq_cst) and
                (err == error.SocketNotListening or err == error.BrokenPipe or err == error.ConnectionResetByPeer)) return;
            self.failure = err;
        };
    }

    fn runFallible(self: *@This()) !void {
        const zio = self.io();
        var stream = try self.server.accept(zio);
        defer stream.close(zio);
        try readTestRequest(zio, stream);
        try writeTestBytes(
            zio,
            stream,
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/event-stream\r\n" ++
                "Connection: close\r\n\r\n" ++
                "data: {\"type\":\"response.output_text.delta\",\"delta\":\"partial\"}\n\n",
        );
        self.response_started.store(true, .seq_cst);
        while (!self.stopping.load(.seq_cst)) {
            var sleep_io: std.Io.Threaded = .init_single_threaded;
            sleep_io.io().sleep(.fromMilliseconds(5), .real) catch {};
        }
    }
};

fn readTestRequest(zio: std.Io, stream: std.Io.net.Stream) !void {
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(zio, &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var header_len: usize = 0;
    while (header_len < request_bytes.len) {
        request_bytes[header_len] = try reader.interface.takeByte();
        header_len += 1;
        if (!std.mem.endsWith(u8, request_bytes[0..header_len], "\r\n\r\n")) continue;
        const headers = request_bytes[0 .. header_len - 4];
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const prefix = "content-length:";
            if (line.len < prefix.len or !std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) continue;
            const length = try std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " \t"), 10);
            try reader.interface.discardAll(length);
            return;
        }
        return;
    }
    return error.TestRequestTooLarge;
}

fn writeTestBytes(zio: std.Io, stream: std.Io.net.Stream, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(zio, &buffer);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn ignoreTestEvent(_: *anyopaque, _: agent_stream.Event) void {}
fn admitTestRequest(_: *anyopaque) !void {}

fn testModelRequest(
    delivery: *agent_stream.DeliveryCertainty,
    evidence: *agent_stream.AttemptEvidence,
    cancelled: *std.atomic.Value(bool),
    callback_context: *u8,
) agent_stream.ModelRequest {
    return .{
        .credential = .{ .secret = "cliproxy-secret", .source = .ai_gateway_api_key },
        .model = "gpt-5.6-sol",
        .retry_count = 1,
        .messages = &.{},
        .tool_choice = .none,
        .provider_options = .{},
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = delivery,
        .attempt_evidence = evidence,
        .events = .{ .context = callback_context, .emit_fn = ignoreTestEvent },
        .admission = .{ .context = callback_context, .admit_fn = admitTestRequest },
        .cancel_flag = cancelled,
    };
}

test "CLIProxy request deadline interrupts a stalled Responses stream" {
    var fixture = try StalledResponseFixture.init();
    defer fixture.deinit();
    try fixture.start();
    const endpoint = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/responses",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(endpoint);
    var delivery = agent_stream.DeliveryCertainty.init();
    var evidence: agent_stream.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    var request = testModelRequest(&delivery, &evidence, &cancelled, &callback_context);
    request.deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(75),
    });

    const started = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
    try std.testing.expectError(
        error.Timeout,
        streamPrepared(std.testing.allocator, request, endpoint, "{}"),
    );
    const elapsed_ms = started.durationTo(std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake)).raw.toMilliseconds();
    fixture.deinit();

    if (fixture.failure) |err| return err;
    try std.testing.expect(fixture.response_started.load(.seq_cst));
    try std.testing.expect(elapsed_ms < 1000);
    try std.testing.expectEqual(agent_stream.DeliveryCertainty.State.possibly_sent, delivery.load());
}

test "CLIProxy cancellation interrupts a stalled Responses stream" {
    var fixture = try StalledResponseFixture.init();
    defer fixture.deinit();
    try fixture.start();
    const endpoint = try std.fmt.allocPrint(
        std.testing.allocator,
        "http://127.0.0.1:{d}/v1/responses",
        .{fixture.port()},
    );
    defer std.testing.allocator.free(endpoint);
    var delivery = agent_stream.DeliveryCertainty.init();
    var evidence: agent_stream.AttemptEvidence = .{};
    var cancelled = std.atomic.Value(bool).init(false);
    var callback_context: u8 = 0;
    const request = testModelRequest(&delivery, &evidence, &cancelled, &callback_context);
    const Canceller = struct {
        fn run(started: *std.atomic.Value(bool), cancel_flag: *std.atomic.Value(bool)) void {
            while (!started.load(.seq_cst)) io_mod.sleep(5 * std.time.ns_per_ms);
            cancel_flag.store(true, .seq_cst);
        }
    };
    const canceller = try std.Thread.spawn(.{}, Canceller.run, .{ &fixture.response_started, &cancelled });
    defer canceller.join();

    try std.testing.expectError(
        error.Cancelled,
        streamPrepared(std.testing.allocator, request, endpoint, "{}"),
    );
    fixture.deinit();

    if (fixture.failure) |err| return err;
    try std.testing.expectEqual(agent_stream.DeliveryCertainty.State.possibly_sent, delivery.load());
}
