const std = @import("std");
const httpz = @import("httpz");
const dt = @import("datetime");

const App = @import("app.zig");
const routes = @import("routes/routes.zig");

const Sqlite = @import("corner_stone/Sqlite.zig");
const llm = @import("middleware/llm.zig");

pub const std_options = std.Options{
    .log_level = .debug,
    .logFn = logFn,
};

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [32]u8 = undefined;
    const now = dt.datetime.Datetime.now().shiftTimezone(dt.timezones.Asia.Shanghai);
    const now_str = now.formatISO8601Buf(&buf, true) catch return;

    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const stderr = std.io.getStdErr().writer();
    var bw = std.io.bufferedWriter(stderr);
    const writer = bw.writer();

    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend {
        writer.print("{s} ", .{now_str}) catch return;
        writer.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch return;
        bw.flush() catch return;
    }
}

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

    var llm_session_cache = try App.LlmSessionCache.init(allocator);
    defer llm_session_cache.deinit();

    var llm_client = llm.ClientV2.init(allocator);
    defer llm_client.deinit();

    var app = App{
        .config = &app_config.value,
        .sqlite = &sqlite,

        .llm_client_v2 = &llm_client,
        .llm_session_cache = &llm_session_cache,
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
