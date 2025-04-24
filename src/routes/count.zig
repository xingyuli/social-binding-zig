const std = @import("std");

const httpz = @import("httpz");
const Action = httpz.Action;
const Group = httpz.routing.Group;

const App = @import("../app.zig");

const db = @import("../middleware/db/db.zig");

pub fn mount(group: *Group(*App, Action(*App))) void {
    group.get("/users", countUsers, .{});
}

fn countUsers(app: *App, _: *httpz.Request, resp: *httpz.Response) !void {
    const result = db.account.countGrouped(.{
        .sqlite = app.sqlite,
        .arena = resp.arena,
    });

    var buffer = std.ArrayList(u8).init(resp.arena);
    try buffer.appendSlice("{");
    var iter = result.iterator();
    var first = true;
    while (iter.next()) |kv| {
        if (!first) try buffer.appendSlice(",");
        first = false;

        try buffer.writer().print("\"{s}\":{d}", .{ kv.key_ptr.*, kv.value_ptr.* });
    }
    try buffer.appendSlice("}");

    resp.body = buffer.items;
    resp.content_type = httpz.ContentType.JSON;
}
