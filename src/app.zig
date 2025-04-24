const std = @import("std");

const httpz = @import("httpz");
const Sqlite = @import("corner_stone/Sqlite.zig");
const llm = @import("middleware/llm.zig");

config: *Config,
sqlite: *Sqlite,
llm_client: *llm.Client,

const log = std.log.scoped(.app);

const Self = @This();

pub const Config = struct {
    db_file: []const u8,
    llm_api_key: []const u8,
    wx: WxConfig,
};
const WxConfig = struct {
    token: []const u8,
};

pub fn dispatch(self: *Self, action: httpz.Action(*Self), req: *httpz.Request, resp: *httpz.Response) !void {
    var iter = req.headers.iterator();
    while (iter.next()) |kv| {
        log.debug("header {s}: {s}", .{ kv.key, kv.value });
    }

    var timer = try std.time.Timer.start();

    try action(self, req, resp);

    // ns -> ms
    const elapsed = timer.lap() / std.time.ns_per_ms;
    log.info("{} {s} {d}ms", .{ req.method, req.url.path, elapsed });
}
