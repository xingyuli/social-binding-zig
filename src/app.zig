config: *Config,

pub const Config = struct {
    wx: WxConfig,
};
const WxConfig = struct {
    token: []const u8,
};
