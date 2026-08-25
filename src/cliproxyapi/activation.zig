const config = @import("config.zig");
const credentials = @import("../core/auth/credentials.zig");

pub fn activate(comptime App: type, app: *App) !void {
    try app.auth.refreshSourceInventory(app.alloc);
    var credential = (try credentials.loadSource(
        app.alloc,
        app.auth.oauthTransport(),
        app.auth.secretStore(),
        .ai_gateway_api_key,
    )) orelse return error.NfxCredentialUnavailable;
    defer credential.deinit(app.alloc);

    var owned_model = try app.alloc.dupe(u8, config.default_model);
    errdefer app.alloc.free(owned_model);

    app.provider_selection.adoptOwned(.gateway, &owned_model);
    _ = app.auth.adoptCredential(app.alloc, &credential);
}
