const std = @import("std");

pub const Sqlite = @import("../../corner_stone/Sqlite.zig");

pub const QueryContext = struct {
    sqlite: *Sqlite,
    arena: std.mem.Allocator,
};
