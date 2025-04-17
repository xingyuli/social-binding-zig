const std = @import("std");

pub fn findFirst(comptime T: type, list: std.ArrayList(T), predicate: fn (T) bool) error{NotFound}!T {
    return findFirstOrNull(T, list, predicate) orelse error.NotFound;
}

pub fn findFirstOrNull(comptime T: type, list: std.ArrayList(T), predicate: fn (T) bool) ?T {
    for (list.items) |it| {
        if (predicate(it)) {
            return it;
        }
    }
    return null;
}

pub fn any(comptime T: type, list: std.ArrayList(T), predicate: fn (T) bool) bool {
    return findFirstOrNull(T, list, predicate) != null;
}
