const std = @import("std");

pub fn fromStringOrNull(comptime T: type, str: []const u8) ?T {
    inline for (@typeInfo(T).@"enum".fields) |it| {
        if (std.mem.eql(u8, str, it.name)) {
            return @field(T, it.name);
        }
    }
    return null;
}
