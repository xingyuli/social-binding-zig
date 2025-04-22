const std = @import("std");

const common = @import("common.zig");
const Sqlite = common.Sqlite;
const QueryContext = common.QueryContext;

const AccountType = enum {
    WECHAT,
};

const AccountStatus = enum {
    SUBSCRIBED,
    UNSUBSCRIBED,
};

pub fn onWxSubscribe(ctx: QueryContext, open_id: []const u8) void {
    const account = findOneByExtIdentifier(ctx, AccountType.WECHAT, open_id);

    if (account) |it| {
        const id = std.fmt.parseInt(u64, it.get("id").?.?, 10) catch unreachable;
        updateStatus(ctx, AccountStatus.SUBSCRIBED, id);
    } else {
        addAccount(ctx, open_id);
    }
}

pub fn onWxUnsubscribe(ctx: QueryContext, open_id: []const u8) void {
    const account = findOneByExtIdentifier(ctx, AccountType.WECHAT, open_id);
    if (account) |it| {
        const id = std.fmt.parseInt(u64, it.get("id").?.?, 10) catch unreachable;
        updateStatus(ctx, AccountStatus.UNSUBSCRIBED, id);
    }
}

fn findOneByExtIdentifier(ctx: QueryContext, account_type: AccountType, ext_identifier: []const u8) ?Sqlite.ResultRow {
    const sql = std.fmt.allocPrint(ctx.arena, "SELECT * FROM account WHERE type = '{s}' AND ext_identifier = '{s}'", .{
        @tagName(account_type),
        ext_identifier,
    }) catch unreachable;

    const result_set = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;

    return if (result_set.items.len > 0) result_set.items[0] else null;
}

fn updateStatus(ctx: QueryContext, status: AccountStatus, id: u64) void {
    const sql = std.fmt.allocPrint(ctx.arena, "UPDATE account SET status = '{s}', updated_at = {d} WHERE id = {d}", .{
        @tagName(status),
        std.time.timestamp(),
        id,
    }) catch unreachable;

    _ = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;
}

fn addAccount(ctx: QueryContext, ext_identifier: []const u8) void {
    const sql = std.fmt.allocPrint(ctx.arena, "INSERT INTO account (type, ext_identifier, status, created_at, updated_at) values ('{s}', '{s}', '{s}', {d}, {d})", .{
        @tagName(AccountType.WECHAT),
        ext_identifier,
        @tagName(AccountStatus.SUBSCRIBED),
        std.time.timestamp(),
        std.time.timestamp(),
    }) catch unreachable;

    _ = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;
}

pub fn countGrouped(ctx: QueryContext) std.StringHashMap(u64) {
    const sql = std.fmt.allocPrint(ctx.arena, "SELECT type, COUNT(*) as count FROM account WHERE status = '{s}' GROUP BY type", .{
        @tagName(AccountStatus.SUBSCRIBED),
    }) catch unreachable;

    const result_set = ctx.sqlite.exec(ctx.arena, sql) catch unreachable;

    var result = std.StringHashMap(u64).init(ctx.arena);
    for (result_set.items) |it| {
        const account_type = it.get("type").?.?;
        const count = std.fmt.parseInt(u64, it.get("count").?.?, 10) catch unreachable;
        result.put(account_type, count) catch unreachable;
    }

    inline for (@typeInfo(AccountType).@"enum".fields) |it| {
        const v = result.get(it.name);

        if (v == null) {
            result.put(it.name, 0) catch unreachable;
        }
    }

    return result;
}
