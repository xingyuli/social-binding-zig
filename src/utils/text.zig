const std = @import("std");

pub fn isEmptyStr(str: ?[]const u8) bool {
    if (str == null) {
        return true;
    }
    for (str.?) |c| {
        if (!std.ascii.isWhitespace(c)) {
            return false;
        }
    }
    return true;
}

pub const StringOrder = struct {
    pub fn asc(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.lessThan(u8, lhs, rhs);
    }
};
