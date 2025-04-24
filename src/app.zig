const std = @import("std");

const httpz = @import("httpz");
const Sqlite = @import("corner_stone/Sqlite.zig");

config: *Config,
sqlite: *Sqlite,

const Self = @This();

pub const Config = struct {
    db_file: []const u8,
    wx: WxConfig,
};
const WxConfig = struct {
    token: []const u8,
};

pub fn dispatch(self: *Self, action: httpz.Action(*Self), req: *httpz.Request, resp: *httpz.Response) !void {
    var iter = req.headers.iterator();
    while (iter.next()) |kv| {
        std.log.debug("header {s}: {s}", .{ kv.key, kv.value });
    }

    var timer = try std.time.Timer.start();

    try action(self, req, resp);

    // ns -> us
    const elapsed = timer.lap() / 1000;
    std.log.info("{} {s} {d}", .{ req.method, req.url.path, elapsed });
}
