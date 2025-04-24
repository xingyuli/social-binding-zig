const std = @import("std");
const httpz = @import("httpz");

const App = @import("app.zig");
const routes = @import("routes/routes.zig");

const Sqlite = @import("corner_stone/Sqlite.zig");

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

    var app = App{
        .config = &app_config.value,
        .sqlite = &sqlite,
    };

    var server = try httpz.Server(*App).init(allocator, .{ .port = 5882 }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    routes.create(try server.router(.{}));

    try server.listen();
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
