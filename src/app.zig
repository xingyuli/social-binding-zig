const Sqlite = @import("corner_stone/Sqlite.zig");

config: *Config,
sqlite: *Sqlite,

pub const Config = struct {
    db_file: []const u8,
    wx: WxConfig,
};
const WxConfig = struct {
    token: []const u8,
};
