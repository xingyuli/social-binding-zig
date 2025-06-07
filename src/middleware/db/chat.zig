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
    const sql = std.fmt.allocPrint(
        ctx.arena,
        "SELECT * FROM chat_message WHERE id = '{s}'",
        .{id},
    ) catch unreachable;

    const result_set = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;

    return if (result_set.items.len > 0) toModel(&result_set.items[0]) else null;
}

pub fn findAllByConversationId(ctx: QueryContext, conversation_id: []const u8) std.ArrayList(ChatMessage) {
    const sql = std.fmt.allocPrint(
        ctx.arena,
        // `user` prompt then `assistant` answer
        "SELECT * FROM chat_message WHERE conversation_id = '{s}' ORDER BY created_at, role DESC",
        .{conversation_id},
    ) catch unreachable;

    const result_set = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;

    var l = std.ArrayList(ChatMessage).init(ctx.arena);

    for (result_set.items) |*it| {
        l.append(toModel(it)) catch unreachable;
    }

    return l;
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
