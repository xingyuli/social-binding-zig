const std = @import("std");
const Allocator = std.mem.Allocator;

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

const Locks = std.ArrayList(std.Thread.Mutex);

fn TimestampedValue(comptime V: type) type {
    return struct {
        value: V,
        milli_ts: i64,
    };
}

// TODO sharded locking cannot protect concurrent resizing, extra cooperation is needed
pub fn BlockingStringMap(comptime V: type) type {
    return struct {
        const Self = @This();

        allocator: Allocator,

        m: *std.StringHashMap(TSV),
        locks: *Locks,

        const TSV = TimestampedValue(V);

        pub fn init(allocator: Allocator) !Self {
            const m = try allocator.create(std.StringHashMap(TSV));
            m.* = std.StringHashMap(TSV).init(allocator);

            const locks = try allocator.create(Locks);
            locks.* = Locks.init(allocator);
            // fixed to 16 locks
            try locks.appendNTimes(std.Thread.Mutex{}, 16);

            return .{
                .allocator = allocator,
                .m = m,
                .locks = locks,
            };
        }

        pub fn deinit(self: Self) void {
            self.locks.deinit();
            self.allocator.destroy(self.locks);

            self.m.deinit();
            self.allocator.destroy(self.m);
        }

        fn cleanup(self: *Self) !void {
            var keys_to_remove = std.ArrayList([]const u8).init(self.allocator);

            var iter = self.m.iterator();
            while (iter.next()) |kv| {
                const tsv = kv.value_ptr.*;
                const age = std.time.milliTimestamp() - tsv.milli_ts;
                if (age > 1000 * 30) {
                    try keys_to_remove.append(kv.key_ptr.*);
                }
            }

            for (keys_to_remove.items) |k| {
                _ = self.m.remove(k);
                std.debug.print(
                    "tid:{} time:{} fn:cleanup | remove key: {s}\n",
                    .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), k },
                );
            }
        }

        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            const result = try self.guard(
                "put",
                key,
                value,
                struct {
                    fn callback(ctx: GuardContext) Allocator.Error!GuardResult {
                        const v = TSV{ .value = ctx.value.?, .milli_ts = std.time.milliTimestamp() };
                        return .{ .put = try ctx.self.m.put(ctx.key, v) };
                    }
                }.callback,
            );

            // self.cleanup() catch unreachable;

            switch (result) {
                .put => return,
                .get => unreachable, // Should never happen
            }
        }

        pub fn putWithValueFn(self: *Self, key: []const u8, value: fn () V) Allocator.Error!void {
            const result = try self.guardFn(
                "put",
                key,
                value,
                struct {
                    fn callback(ctx: GuardFnContext) Allocator.Error!GuardResult {
                        const v = TSV{ .value = ctx.value.?(), .milli_ts = std.time.milliTimestamp() };
                        return .{ .put = try ctx.self.m.put(ctx.key, v) };
                    }
                }.callback,
            );

            // self.cleanup() catch unreachable;

            switch (result) {
                .put => return,
                .get => unreachable, // Should never happen
            }
        }

        pub fn putRaw(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            const v = TSV{ .value = value, .milli_ts = std.time.milliTimestamp() };
            try self.m.put(key, v);

            // self.cleanup() catch unreachable;
        }

        pub fn get(self: *Self, key: []const u8) ?V {
            const result = self.guard(
                "get",
                key,
                null,
                struct {
                    fn callback(ctx: GuardContext) Allocator.Error!GuardResult {
                        const v = ctx.self.m.get(ctx.key);
                        return .{ .get = if (v) |it| it.value else null };
                    }
                }.callback,
            ) catch unreachable;

            self.cleanup() catch |err| {
                std.debug.print("cleanup error: {}\n", .{err});
                return null;
            };

            switch (result) {
                .put => unreachable, // Should never happen
                .get => |v| return v,
            }
        }

        const GuardContext = struct {
            self: *Self,
            key: []const u8,
            value: ?V, // Optional value for put
        };

        const GuardResult = union(enum) {
            put: void,
            get: ?V,
        };

        const GuardCallback = fn (ctx: GuardContext) Allocator.Error!GuardResult;

        fn guard(self: *Self, op: []const u8, key: []const u8, value: ?V, comptime callback: GuardCallback) Allocator.Error!GuardResult {
            const hash = self.m.ctx.hash(key);
            const lock_index: u64 = hash % self.locks.items.len;

            std.debug.print(
                "tid:{} time:{} fn:guard | op: {s}, key: {s}, hash: {d}, lock_index: {d}\n",
                .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), op, key, hash, lock_index },
            );

            var l = &self.locks.items[lock_index];
            {
                l.lock();
                std.debug.print(
                    "tid:{} time:{} fn:guard | op: {s}, key: {s}, hash: {d}, lock_index: {d}, lock addr: {*} accuquired\n",
                    .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), op, key, hash, lock_index, l },
                );
            }
            defer {
                l.unlock();
                std.debug.print(
                    "tid:{} time:{} fn:guard | op: {s}, key: {s}, hash: {d}, lock_index: {d}, lock addr: {*} released\n",
                    .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), op, key, hash, lock_index, l },
                );
            }

            return callback(.{
                .self = self,
                .key = key,
                .value = value,
            });
        }

        pub fn lock(self: *Self, key: []const u8) void {
            const hash = self.m.ctx.hash(key);
            const lock_index: u64 = hash % self.locks.items.len;

            const l = &self.locks.items[lock_index];
            l.lock();
        }

        pub fn unlock(self: *Self, key: []const u8) void {
            const hash = self.m.ctx.hash(key);
            const lock_index: u64 = hash % self.locks.items.len;

            const l = &self.locks.items[lock_index];
            l.unlock();
        }

        const GuardFnContext = struct {
            self: *Self,
            key: []const u8,
            value: ?*const fn () V,
        };

        const GuardFnCallback = fn (ctx: GuardFnContext) Allocator.Error!GuardResult;

        fn guardFn(self: *Self, op: []const u8, key: []const u8, value: ?*const fn () V, comptime callback: GuardFnCallback) Allocator.Error!GuardResult {
            const hash = self.m.ctx.hash(key);
            const lock_index: u64 = hash % self.locks.items.len;

            std.debug.print(
                "tid:{} time:{} fn:guardFn | op: {s}, key: {s}, hash: {d}, lock_index: {d}\n",
                .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), op, key, hash, lock_index },
            );

            var l = &self.locks.items[lock_index];
            {
                l.lock();
                std.debug.print(
                    "tid:{} time:{} fn:guardFn | op: {s}, key: {s}, hash: {d}, lock_index: {d}, lock addr: {*} accuquired\n",
                    .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), op, key, hash, lock_index, l },
                );
            }
            defer {
                l.unlock();
                std.debug.print(
                    "tid:{} time:{} fn:guardFn | op: {s}, key: {s}, hash: {d}, lock_index: {d}, lock addr: {*} released\n",
                    .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), op, key, hash, lock_index, l },
                );
            }

            return callback(.{
                .self = self,
                .key = key,
                .value = value,
            });
        }
    };
}
