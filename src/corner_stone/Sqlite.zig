const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("sqlite3.h");
});

db: *c.sqlite3,

const SqliteError = error{
    DatabaseOpenFailed,
    QueryFailed,
};

pub const ResultRow = std.StringHashMap(?[]u8);
pub const ResultSet = std.ArrayList(ResultRow);

const log = std.log.scoped(.corner_stone__sqlite);

const Self = @This();

pub fn init(filename: []const u8) SqliteError!Self {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const c_filename: [*c]u8 = arena.allocator().dupeZ(u8, filename) catch unreachable;

    var db: ?*c.sqlite3 = null;
    const rc = c.sqlite3_open(c_filename, &db);
    if (rc != c.SQLITE_OK) {
        log.debug("Cannot open database: {s}", .{c.sqlite3_errmsg(db)});
        return SqliteError.DatabaseOpenFailed;
    }

    return Self{
        .db = db.?,
    };
}

pub fn deinit(self: Self) void {
    _ = c.sqlite3_close(self.db);
}

pub fn exec(self: Self, arena: Allocator, sql: []const u8) SqliteError!*ResultSet {
    const c_sql: [*c]u8 = arena.dupeZ(u8, sql) catch unreachable;

    // see: https://sqlite.org/c3ref/exec.html
    var result_set = ResultSet.init(arena);

    // std.debug.print("exec_query | result_set ptr: {?*}\n", .{&result_set});

    var err_msg: [*c]u8 = null;
    const rc_select = c.sqlite3_exec(self.db, c_sql, query_callback, &result_set, &err_msg);
    if (rc_select != c.SQLITE_OK) {
        log.debug("SQL error: {s}", .{err_msg});
        c.sqlite3_free(err_msg);
        return SqliteError.QueryFailed;
    }

    log.debug("Query executed successfully: {s}", .{sql});

    for (result_set.items) |it| {
        var iter = it.iterator();
        while (iter.next()) |kv| {
            log.debug("{s}: {?s}", .{ kv.key_ptr.*, kv.value_ptr.* });
        }
    }

    return &result_set;
}

// TODO fn: execute query with named parameters
// var stmt: ?*c.sqlite3_stmt = null;
// c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);

fn query_callback(user_data: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, az_col_name: [*c][*c]u8) callconv(.c) c_int {
    const aligned_ptr = @as(*align(@alignOf(ResultSet)) anyopaque, @alignCast(user_data.?));
    const result_set: *ResultSet = @ptrCast(aligned_ptr);

    // std.debug.print("query_callback | result_set ptr: {?*}\n", .{result_set});

    var row = ResultRow.init(result_set.allocator);

    const col_count: usize = @intCast(argc);
    for (0..col_count) |i| {
        const col_name = az_col_name[i];
        const col_value: ?[*c]u8 = argv[i] orelse null;

        // std.debug.print("{s}: {?s}\n", .{ std.mem.span(col_name), std.mem.span(col_value) });

        const col_name_copy = result_set.allocator.dupeZ(u8, std.mem.span(col_name)) catch unreachable;

        var col_value_copy: ?[]u8 = null;
        if (col_value) |it| {
            col_value_copy = result_set.allocator.dupeZ(u8, std.mem.span(it)) catch unreachable;
        }

        row.put(col_name_copy, col_value_copy) catch unreachable;
    }

    result_set.append(row) catch unreachable;

    return 0;
}
