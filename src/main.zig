const std = @import("std");
const httpz = @import("httpz");

const App = @import("app.zig");
const routes = @import("routes/routes.zig");

const Sqlite = @import("corner_stone/Sqlite.zig");
const llm = @import("middleware/llm.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const file_content = try loadFileContent(allocator, "config.json");
    defer allocator.free(file_content);

    var app_config = try loadAppConfig(allocator, file_content);
    defer app_config.deinit();

    var sqlite = try Sqlite.init(app_config.value.db_file);
    defer sqlite.deinit();

    var llm_client = try llm.Client.init(app_config.value.llm_api_key, allocator);
    defer llm_client.deinit();

    var llm_session_cache = try App.LlmSessionCache.init(allocator);
    defer llm_session_cache.deinit();

    var llm_client_v2 = llm.ClientV2.init(app_config.value.llm_api_key, allocator);
    defer llm_client_v2.deinit();

    var app = App{
        .config = &app_config.value,
        .sqlite = &sqlite,

        .llm_client = &llm_client,
        .llm_session_cache = &llm_session_cache,

        .llm_client_v2 = &llm_client_v2,
    };

    var server = try httpz.Server(*App).init(allocator, .{ .port = 5882 }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    routes.create(try server.router(.{}));

    const thread = try std.Thread.spawn(.{}, cleanupLlmSessionCache, .{app.llm_session_cache});
    defer thread.join();

    try server.listen();
}

fn cleanupLlmSessionCache(cache: *App.LlmSessionCache) !void {
    while (true) {
        std.Thread.sleep(std.time.ns_per_s * 10);
        try cache.cleanup(null, 60);
    }
}

// -------------------------
// ----- configuration -----
// -------------------------

fn loadFileContent(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, 1024);
}

fn loadAppConfig(allocator: std.mem.Allocator, content: []const u8) !std.json.Parsed(App.Config) {
    return try std.json.parseFromSlice(App.Config, allocator, content, .{ .ignore_unknown_fields = true });
}
