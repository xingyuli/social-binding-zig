const std = @import("std");
const Allocator = std.mem.Allocator;

const httpz = @import("httpz");
const Sqlite = @import("corner_stone/Sqlite.zig");
const llm = @import("middleware/llm.zig");
const utils = @import("utils/utils.zig");

config: *Config,
sqlite: *Sqlite,

llm_client: *llm.Client,
llm_session_cache: *LlmSessionCache,

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

pub const MessageRound = struct {
    id: []const u8,
    in: llm.ModelMessage,
    out: llm.ModelMessage,
    usage: llm.ModelUsage,
};

const ChatMessagesHandler = struct {
    pub fn alloc(allocator: Allocator, value: std.ArrayList(MessageRound)) Allocator.Error!*std.ArrayList(MessageRound) {
        const ptr = try allocator.create(std.ArrayList(MessageRound));
        ptr.* = std.ArrayList(MessageRound).init(allocator);

        try ptr.ensureTotalCapacity(value.items.len);
        for (value.items) |it| {
            try ptr.append(.{
                .id = try allocator.dupe(u8, it.id),
                .in = .{
                    .role = it.in.role,
                    .content = try allocator.dupe(u8, it.in.content),
                },
                .out = .{
                    .role = it.out.role,
                    .content = try allocator.dupe(u8, it.out.content),
                },
                .usage = it.usage,
            });
        }

        return ptr;
    }

    pub fn free(allocator: Allocator, value: *std.ArrayList(MessageRound)) void {
        for (value.items) |it| {
            allocator.free(it.in.content);
            allocator.free(it.out.content);
        }

        value.deinit();
        allocator.destroy(value);
    }
};

pub const LlmSessionCache = utils.collection.BlockingMap(std.ArrayList(MessageRound), ChatMessagesHandler);

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
