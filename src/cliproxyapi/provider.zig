const std = @import("std");
const config = @import("config.zig");
const agent_stream = @import("../core/agent/stream_provider.zig");
const builtin_gateway = @import("../builtins/gateway.zig");
const credentials = @import("../core/auth/credentials.zig");
const gateway_provider = @import("../core/gateway/gateway_provider.zig");
const model_catalog = @import("../core/gateway/model_catalog.zig");
const output_contracts = @import("../core/output/output_contracts.zig");
const io_mod = @import("../core/shared/io.zig");
const secret = @import("../core/auth/secret.zig");
const types = @import("../core/shared/types.zig");

const Allocator = std.mem.Allocator;
const max_response_bytes = 32 * 1024 * 1024;

pub const models_path = "/v1/models?client_version=nfx";
pub const retry_count: usize = 1;

pub const agent_stream_provider = agent_stream.Provider{
    .build_fn = buildRequest,
    .stream_fn = streamResponse,
};

pub const model_catalog_provider = model_catalog.Provider{
    .fetch_fn = fetchModelCatalog,
};

pub const cli_model_catalog_provider = gateway_provider.CliModelCatalogProvider{
    .fetch_fn = fetchCliModelCatalog,
};

pub fn gatewayProvider() gateway_provider.Provider {
    var result = builtin_gateway.provider;
    result.agent_stream = agent_stream_provider;
    result.chat_url = .{ .resolve_fn = resolveChatUrl };
    result.cli_model_catalog = cli_model_catalog_provider;
    result.credits = .{ .fetch_fn = fetchCredits };
    result.model_catalog = model_catalog_provider;
    return result;
}

fn resolveChatUrl(_: ?*anyopaque, fallback: []const u8) []const u8 {
    return fallback;
}

fn buildRequest(_: ?*anyopaque, alloc: Allocator, request: agent_stream.BuildRequest) ![]u8 {
    if (request.verified_images != null or request.response_format != null) {
        return error.CliproxyStructuredOrImageInputUnsupported;
    }
    if (request.budget) |budget| {
        if (budget.cancel_flag) |flag| if (flag.load(.seq_cst)) return error.Cancelled;
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"model\":");
    try std.json.Stringify.value(normalizeModel(request.model), .{}, &out.writer);
    try out.writer.writeAll(",\"store\":false,\"stream\":true,\"instructions\":");
    try writeInstructions(&out.writer, request.messages);
    try out.writer.writeAll(",\"input\":[");
    try writeInputMessages(&out.writer, request.messages);
    try out.writer.writeAll("],\"text\":{\"verbosity\":\"low\"},\"include\":[\"reasoning.encrypted_content\"],\"tool_choice\":");
    try std.json.Stringify.value(request.tool_choice.label(), .{}, &out.writer);
    try out.writer.writeAll(",\"parallel_tool_calls\":true");

    try writeTools(alloc, &out.writer, request.serialized_tools, request.selected_dynamic_tool_schemas);
    if (request.provider_options.reasoning) |effort| {
        try out.writer.writeAll(",\"reasoning\":{\"effort\":");
        try std.json.Stringify.value(effort.label(), .{}, &out.writer);
        try out.writer.writeAll(",\"summary\":\"auto\"}");
    }
    if (request.provider_options.fast) try out.writer.writeAll(",\"service_tier\":\"priority\"");
    if (request.max_output_tokens) |limit| try out.writer.print(",\"max_output_tokens\":{d}", .{limit});
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn normalizeModel(model: []const u8) []const u8 {
    const prefix = "openai/";
    return if (std.mem.startsWith(u8, model, prefix)) model[prefix.len..] else model;
}

fn writeInstructions(writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    var joined: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer joined.deinit();
    var count: usize = 0;
    for (messages) |message| {
        if (message.role != .system) continue;
        const content = message.content orelse continue;
        if (content.len == 0) continue;
        if (count > 0) try joined.writer.writeAll("\n\n");
        try joined.writer.writeAll(content);
        count += 1;
    }
    try std.json.Stringify.value(if (count == 0) "You are a helpful assistant." else joined.written(), .{}, writer);
}

fn writeInputMessages(writer: *std.Io.Writer, messages: []const types.ChatMessage) !void {
    var emitted: usize = 0;
    for (messages) |message| {
        if (message.role == .system) continue;
        if (message.content) |content| {
            if (emitted > 0) try writer.writeByte(',');
            switch (message.role) {
                .user => {
                    try writer.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeAll("}]}");
                },
                .assistant => {
                    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",\"content\":[{\"type\":\"output_text\",\"text\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeAll(",\"annotations\":[]}]}");
                },
                .tool => {
                    try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
                    try std.json.Stringify.value(callId(message.tool_call_id orelse ""), .{}, writer);
                    try writer.writeAll(",\"output\":");
                    try std.json.Stringify.value(content, .{}, writer);
                    try writer.writeByte('}');
                },
                .system => unreachable,
            }
            emitted += 1;
        }
        if (message.role == .assistant) {
            for (message.tool_calls) |tool_call| {
                if (emitted > 0) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"function_call\",\"call_id\":");
                try std.json.Stringify.value(callId(tool_call.id), .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tool_call.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tool_call.arguments_json, .{}, writer);
                try writer.writeByte('}');
                emitted += 1;
            }
        }
    }
}

fn callId(id: []const u8) []const u8 {
    const separator = std.mem.findScalar(u8, id, '|') orelse return id;
    return id[0..separator];
}

fn writeTools(
    alloc: Allocator,
    writer: *std.Io.Writer,
    serialized_tools: []const u8,
    dynamic_tools: []const []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, serialized_tools, .{}) catch return error.InvalidCliproxyTools;
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidCliproxyTools;

    var emitted: usize = 0;
    var tools: std.Io.Writer.Allocating = .init(alloc);
    defer tools.deinit();
    for (parsed.value.array.items) |tool| try writeToolValue(&tools.writer, tool, &emitted);
    for (dynamic_tools) |serialized| {
        var dynamic = std.json.parseFromSlice(std.json.Value, alloc, serialized, .{}) catch return error.InvalidCliproxyTools;
        defer dynamic.deinit();
        try writeToolValue(&tools.writer, dynamic.value, &emitted);
    }
    if (emitted == 0) return;
    try writer.writeAll(",\"tools\":[");
    try writer.writeAll(tools.written());
    try writer.writeByte(']');
}

fn writeToolValue(writer: *std.Io.Writer, tool: std.json.Value, emitted: *usize) !void {
    if (tool != .object) return;
    const kind = tool.object.get("type") orelse return;
    if (kind != .string or !std.mem.eql(u8, kind.string, "function")) return;
    const name = tool.object.get("name") orelse return;
    const schema = tool.object.get("inputSchema") orelse tool.object.get("parameters") orelse return;
    if (name != .string) return;
    if (emitted.* > 0) try writer.writeByte(',');
    try writer.writeAll("{\"type\":\"function\",\"name\":");
    try std.json.Stringify.value(name.string, .{}, writer);
    if (tool.object.get("description")) |description| if (description == .string) {
        try writer.writeAll(",\"description\":");
        try std.json.Stringify.value(description.string, .{}, writer);
    };
    try writer.writeAll(",\"parameters\":");
    try std.json.Stringify.value(schema, .{}, writer);
    try writer.writeAll(",\"strict\":false}");
    emitted.* += 1;
}

fn streamResponse(_: ?*anyopaque, alloc: Allocator, request: agent_stream.Request) !agent_stream.Result {
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    var connection = try config.load(alloc);
    defer connection.deinit(alloc);

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{connection.api_key});
    defer secret.zeroAndFree(alloc, auth_header);
    var response_body: std.Io.Writer.Allocating = .init(alloc);
    defer response_body.deinit();
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();

    request.delivery.markPossiblySent();
    const result = try client.fetch(.{
        .location = .{ .url = connection.inference_url },
        .method = .POST,
        .payload = request.payload,
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = "nfx-cliproxyapi/0.0.4" },
            .accept_encoding = .omit,
        },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "text/event-stream" },
            .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
            .{ .name = "originator", .value = "nfx" },
        },
        .response_writer = &response_body.writer,
    });
    request.attempt_evidence.provider_admitted = true;
    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;

    if (result.status != .ok) {
        return .{
            .status = result.status,
            .err_body = try alloc.dupe(u8, response_body.written()),
            .ownership = .owned,
        };
    }
    if (response_body.written().len > max_response_bytes) return error.CliproxyResponseTooLarge;
    return parseResponsesSse(alloc, response_body.written(), request);
}

const PendingTool = struct {
    output_index: usize,
    call_id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *PendingTool, alloc: Allocator) void {
        alloc.free(self.call_id);
        alloc.free(self.name);
        self.arguments.deinit(alloc);
    }
};

fn parseResponsesSse(alloc: Allocator, bytes: []const u8, request: agent_stream.Request) !agent_stream.Result {
    var content: std.ArrayList(u8) = .empty;
    errdefer content.deinit(alloc);
    var tools: std.ArrayList(types.ToolCall) = .empty;
    errdefer {
        for (tools.items) |tool| types.freeToolCall(alloc, tool);
        tools.deinit(alloc);
    }
    var pending: std.ArrayList(PendingTool) = .empty;
    defer {
        for (pending.items) |*tool| tool.deinit(alloc);
        pending.deinit(alloc);
    }
    var generation_id: ?[]u8 = null;
    errdefer if (generation_id) |id| alloc.free(id);
    var usage: types.Usage = .{};
    var finish_reason: ?types.ProviderFinishReason = null;

    var blocks = std.mem.splitSequence(u8, bytes, "\n\n");
    while (blocks.next()) |block| {
        if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
        var lines = std.mem.splitScalar(u8, block, '\n');
        var payload: ?[]const u8 = null;
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "data:")) payload = std.mem.trim(u8, line[5..], " \t");
        }
        const data = payload orelse continue;
        if (data.len == 0 or std.mem.eql(u8, data, "[DONE]")) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, alloc, data, .{}) catch return error.InvalidCliproxyResponse;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const event_type_value = parsed.value.object.get("type") orelse continue;
        if (event_type_value != .string) continue;
        const event_type = event_type_value.string;

        if (std.mem.eql(u8, event_type, "response.created")) {
            if (parsed.value.object.get("response")) |response| if (response == .object) {
                if (response.object.get("id")) |id| {
                    if (id == .string and generation_id == null) generation_id = try alloc.dupe(u8, id.string);
                }
            };
        } else if (std.mem.eql(u8, event_type, "response.output_text.delta") or std.mem.eql(u8, event_type, "response.refusal.delta")) {
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            try content.appendSlice(alloc, delta);
            request.on_content_chunk(request.callback_ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.reasoning_summary_text.delta") or std.mem.eql(u8, event_type, "response.reasoning_text.delta")) {
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            if (request.on_reasoning_chunk) |callback| callback(request.callback_ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.output_item.added")) {
            const item = parsed.value.object.get("item") orelse continue;
            if (item != .object) continue;
            const item_type = stringField(item.object, "type") orelse continue;
            if (!std.mem.eql(u8, item_type, "function_call")) continue;
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const call_id = stringField(item.object, "call_id") orelse continue;
            const name = stringField(item.object, "name") orelse continue;
            var tool = PendingTool{
                .output_index = output_index,
                .call_id = try alloc.dupe(u8, call_id),
                .name = try alloc.dupe(u8, name),
            };
            errdefer tool.deinit(alloc);
            if (stringField(item.object, "arguments")) |arguments| try tool.arguments.appendSlice(alloc, arguments);
            try pending.append(alloc, tool);
            if (request.on_tool_start) |callback| callback(request.callback_ctx, call_id, name, null);
        } else if (std.mem.eql(u8, event_type, "response.function_call_arguments.delta")) {
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const delta = stringField(parsed.value.object, "delta") orelse continue;
            if (findPendingTool(pending.items, output_index)) |tool| try tool.arguments.appendSlice(alloc, delta);
            if (request.on_tool_input_chunk) |callback| callback(request.callback_ctx, delta);
        } else if (std.mem.eql(u8, event_type, "response.output_item.done")) {
            const item = parsed.value.object.get("item") orelse continue;
            if (item != .object) continue;
            const item_type = stringField(item.object, "type") orelse continue;
            if (!std.mem.eql(u8, item_type, "function_call")) continue;
            const output_index = integerField(parsed.value.object, "output_index") orelse continue;
            const pending_tool = findPendingTool(pending.items, output_index);
            const call_id_value = stringField(item.object, "call_id") orelse if (pending_tool) |tool| tool.call_id else continue;
            const name_value = stringField(item.object, "name") orelse if (pending_tool) |tool| tool.name else continue;
            const arguments_value = stringField(item.object, "arguments") orelse if (pending_tool) |tool| tool.arguments.items else "{}";
            const id = try alloc.dupe(u8, call_id_value);
            errdefer alloc.free(id);
            const name = try alloc.dupe(u8, name_value);
            errdefer alloc.free(name);
            const arguments = try alloc.dupe(u8, arguments_value);
            errdefer alloc.free(arguments);
            try tools.append(alloc, .{
                .id = id,
                .name = name,
                .arguments_json = arguments,
            });
        } else if (std.mem.eql(u8, event_type, "response.completed") or std.mem.eql(u8, event_type, "response.done") or std.mem.eql(u8, event_type, "response.incomplete")) {
            const response = parsed.value.object.get("response") orelse continue;
            if (response != .object) continue;
            if (generation_id == null) {
                if (stringField(response.object, "id")) |id| generation_id = try alloc.dupe(u8, id);
            }
            if (response.object.get("usage")) |usage_value| if (usage_value == .object) {
                usage.input_tokens = unsignedField(usage_value.object, "input_tokens");
                usage.output_tokens = unsignedField(usage_value.object, "output_tokens");
            };
            const status = stringField(response.object, "status") orelse "completed";
            finish_reason = if (tools.items.len > 0)
                .tool_calls
            else if (std.mem.eql(u8, status, "incomplete"))
                .length
            else
                .stop;
        } else if (std.mem.eql(u8, event_type, "response.failed") or std.mem.eql(u8, event_type, "error")) {
            return error.CliproxyProviderError;
        }
    }
    if (finish_reason == null) return error.CliproxyStreamEndedEarly;

    const owned_content = if (content.items.len > 0) try content.toOwnedSlice(alloc) else null;
    if (owned_content == null) content.deinit(alloc);
    const owned_tools = try tools.toOwnedSlice(alloc);
    return .{
        .status = .ok,
        .completion = .{
            .content = owned_content,
            .tool_calls = owned_tools,
            .generation_id = generation_id,
            .finish_reason = finish_reason,
            .usage = usage,
        },
        .ownership = .owned,
    };
}

fn findPendingTool(tools: []PendingTool, output_index: usize) ?*PendingTool {
    for (tools) |*tool| if (tool.output_index == output_index) return tool;
    return null;
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, name: []const u8) ?usize {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn unsignedField(object: std.json.ObjectMap, name: []const u8) ?u64 {
    const value = object.get(name) orelse return null;
    if (value != .integer or value.integer < 0) return null;
    return @intCast(value.integer);
}

fn fetchModelCatalog(_: ?*anyopaque, alloc: Allocator, input: model_catalog.FetchInput) Allocator.Error!model_catalog.ProviderResult {
    if (input.cancel_flag) |flag| if (flag.load(.seq_cst)) return .{ .failure = .{ .category = .cancellation } };
    var connection = config.load(alloc) catch return .{ .failure = .{ .category = .runtime } };
    defer connection.deinit(alloc);
    return fetchCatalogUrl(alloc, connection.models_url, connection.api_key);
}

fn fetchCatalogUrl(alloc: Allocator, url: []const u8, api_key: []const u8) Allocator.Error!model_catalog.ProviderResult {
    const auth_header = std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key}) catch return error.OutOfMemory;
    defer secret.zeroAndFree(alloc, auth_header);
    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const response = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = "nfx-cliproxyapi/0.0.4" },
            .accept_encoding = .omit,
        },
        .response_writer = &body.writer,
    }) catch return .{ .failure = .{ .category = .transport, .retryable = true } };
    if (response.status != .ok) return .{ .failure = model_catalog.failureForHttpStatus(response.status) };
    return parseCatalog(alloc, body.written()) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => .{ .failure = .{ .category = .malformed_response } },
    };
}

pub fn validateCredentials(alloc: Allocator, base_url: []const u8, api_key: []const u8) !void {
    const normalized = try config.normalizeBaseUrl(alloc, base_url);
    defer alloc.free(normalized);
    const models_url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ normalized, models_path });
    defer alloc.free(models_url);
    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{api_key});
    defer secret.zeroAndFree(alloc, auth_header);

    var discard_buffer: [4096]u8 = undefined;
    var body = std.Io.Writer.Discarding.init(&discard_buffer);
    var client: std.http.Client = .{ .allocator = alloc, .io = io_mod.getIo() };
    defer client.deinit();
    const response = client.fetch(.{
        .location = .{ .url = models_url },
        .method = .GET,
        .headers = .{
            .authorization = .{ .override = auth_header },
            .user_agent = .{ .override = "nfx-cliproxyapi/0.0.4" },
            .accept_encoding = .omit,
        },
        .response_writer = &body.writer,
    }) catch return error.CliproxyConnectionFailed;
    if (response.status == .unauthorized or response.status == .forbidden) return error.CliproxyAuthenticationFailed;
    if (response.status != .ok) return error.CliproxyValidationFailed;
}

fn parseCatalog(alloc: Allocator, bytes: []const u8) !model_catalog.ProviderResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCliproxyCatalog;
    const models_value = parsed.value.object.get("models") orelse parsed.value.object.get("data") orelse return error.InvalidCliproxyCatalog;
    if (models_value != .array) return error.InvalidCliproxyCatalog;

    var entries: std.ArrayList(model_catalog.ModelCatalogEntry) = .empty;
    errdefer model_catalog.freeModelCatalog(alloc, &entries);
    for (models_value.array.items) |model| {
        if (model != .object) continue;
        if (stringField(model.object, "visibility")) |visibility| if (std.ascii.eqlIgnoreCase(visibility, "hide")) continue;
        const id = stringField(model.object, "slug") orelse stringField(model.object, "id") orelse continue;
        if (id.len == 0) continue;
        var efforts: std.ArrayList(types.ReasoningEffort) = .empty;
        errdefer efforts.deinit(alloc);
        if (model.object.get("supported_reasoning_levels")) |levels| if (levels == .array) {
            for (levels.array.items) |level| {
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
        const entry = model_catalog.ModelCatalogEntry{
            .id = try alloc.dupe(u8, id),
            .model_type = try alloc.dupe(u8, "language"),
            .has_tool_use = true,
            .has_reasoning = efforts.items.len > 0,
            .reasoning_efforts = efforts,
            .supports_fast_mode = supports_fast,
            .has_vision = has_vision,
            .context_window = @intCast(@min(context_window, std.math.maxInt(u32))),
            .max_tokens = 16_384,
        };
        try entries.append(alloc, entry);
    }
    return .{ .catalog = entries };
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

test "builds OpenAI Responses request from fx messages and tools" {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = "system" },
        .{ .role = .user, .content = "hello" },
    };
    const body = try buildRequest(null, std.testing.allocator, .{
        .model = "openai/gpt-5.6-sol",
        .serialized_tools = "[{\"type\":\"function\",\"name\":\"read_file\",\"description\":\"Read\",\"inputSchema\":{\"type\":\"object\"}}]",
        .messages = &messages,
        .tool_choice = .auto,
        .provider_options = .{ .reasoning = types.ReasoningEffort.literal("high"), .fast = true },
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.find(u8, body, "\"model\":\"gpt-5.6-sol\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"instructions\":\"system\"") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"parameters\":{\"type\":\"object\"}") != null);
    try std.testing.expect(std.mem.find(u8, body, "\"service_tier\":\"priority\"") != null);
}

test "parses Responses SSE content, tools, and usage" {
    const Capture = struct {
        content: std.ArrayList(u8) = .empty,
        fn chunk(raw: *anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.content.appendSlice(std.testing.allocator, bytes) catch unreachable;
        }
    };
    var capture: Capture = .{};
    defer capture.content.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    var delivery = agent_stream.DeliveryCertainty.init();
    var evidence: agent_stream.AttemptEvidence = .{};
    const sse =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"path\\\":\\\"README.md\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"README.md\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5}}}\n\n";
    var result = try parseResponsesSse(std.testing.allocator, sse, .{
        .api_key = "key",
        .team = null,
        .model = "gpt-5.6-sol",
        .retry_count = 1,
        .chat_url = "",
        .payload = "{}",
        .trace_ctx = .{},
        .content_capture_limit = null,
        .delivery = &delivery,
        .attempt_evidence = &evidence,
        .callback_ctx = &capture,
        .on_content_chunk = Capture.chunk,
        .on_tool_start = null,
        .on_reasoning_chunk = null,
        .cancel_flag = &cancelled,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", result.completion.content.?);
    try std.testing.expectEqual(@as(usize, 1), result.completion.tool_calls.len);
    try std.testing.expectEqualStrings("call_1", result.completion.tool_calls[0].id);
    try std.testing.expectEqual(@as(?u64, 10), result.completion.usage.input_tokens);
    try std.testing.expectEqual(types.ProviderFinishReason.tool_calls, result.completion.finish_reason.?);
}
