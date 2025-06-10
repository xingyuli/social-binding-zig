const std = @import("std");

const common = @import("common.zig");
const Sqlite = common.Sqlite;
const QueryContext = common.QueryContext;

pub const ChatMessage = struct {
    id: []const u8,
    role: []const u8,
    content: []const u8,
    conversation_id: []const u8,
    parent_message_id: ?[]const u8,
    created_at: ?i64 = null,
    updated_at: ?i64 = null,
};

pub fn saveMessage(ctx: QueryContext, msg: *ChatMessage) !void {
    const sql =
        \\INSERT INTO chat_message (id, role, content, conversation_id, parent_message_id, created_at, updated_at)
        \\  VALUES (?, ?, ?, ?, ?, ?, ?)
    ;

    const params = [_]Sqlite.Param{
        .{ .text = msg.id },
        .{ .text = msg.role },
        .{ .text = msg.content },
        .{ .text = msg.conversation_id },
        .{ .text = msg.parent_message_id },
        .{ .int64 = std.time.timestamp() },
        .{ .int64 = std.time.timestamp() },
    };

    try ctx.sqlite.exec_prepared(ctx.arena, sql, &params);
}

pub fn findById(ctx: QueryContext, id: []const u8) ?ChatMessage {
    return findOneByParam(ctx, "id", id) catch unreachable;
}

pub fn findAllByConversationId(ctx: QueryContext, conversation_id: []const u8) std.ArrayList(ChatMessage) {
    const sql = std.fmt.allocPrint(
        ctx.arena,
        // `user` prompt then `assistant` answer
        "SELECT * FROM chat_message WHERE is_deleted = 0 AND conversation_id = '{s}' ORDER BY created_at, role DESC",
        .{conversation_id},
    ) catch unreachable;

    const result_set = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;

    var l = std.ArrayList(ChatMessage).init(ctx.arena);

    for (result_set.items) |*it| {
        l.append(toModel(it)) catch unreachable;
    }

    return l;
}

pub fn markMessageCycleAsDeleted(ctx: QueryContext, parent_message_id: []const u8) void {
    var pmid = parent_message_id;
    var possible: ?ChatMessage = null;

    while (true) {
        possible = findOneByParam(ctx, "parent_message_id", pmid) catch unreachable;
        if (possible) |found| {
            pmid = found.id;
            deleteById(ctx, found.id);
        } else break;
    }
}

fn findOneByParam(ctx: QueryContext, column: []const u8, value: []const u8) !?ChatMessage {
    const sql = std.fmt.allocPrint(
        ctx.arena,
        "SELECT * FROM chat_message WHERE is_deleted = 0 AND {s} = '{s}'",
        .{ column, value },
    ) catch unreachable;

    const result_set = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;

    return switch (result_set.items.len) {
        0 => null,
        1 => toModel(&result_set.items[0]),
        else => error.TooManyRows,
    };
}

fn deleteById(ctx: QueryContext, id: []const u8) void {
    const sql = std.fmt.allocPrint(
        ctx.arena,
        "UPDATE chat_message SET is_deleted = 1 WHERE id = '{s}'",
        .{id},
    ) catch unreachable;

    _ = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;
}

fn toModel(r: *Sqlite.ResultRow) ChatMessage {
    return .{
        .id = r.get("id").?.?,
        .role = r.get("role").?.?,
        .content = r.get("content").?.?,
        .conversation_id = r.get("conversation_id").?.?,
        .parent_message_id = r.get("parent_message_id").?,
        .created_at = std.fmt.parseInt(i64, r.get("created_at").?.?, 10) catch unreachable,
        .updated_at = std.fmt.parseInt(i64, r.get("updated_at").?.?, 10) catch unreachable,
    };
}
