const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn findFirst(comptime T: type, list: *std.ArrayList(T), predicate: fn (T) bool) error{NotFound}!T {
    return findFirstOrNull(T, list, predicate) orelse error.NotFound;
}

pub fn findFirstOrNull(comptime T: type, list: *std.ArrayList(T), predicate: fn (T) bool) ?T {
    for (list.items) |it| {
        if (predicate(it)) {
            return it;
        }
    }
    return null;
}

pub fn any(comptime T: type, list: *std.ArrayList(T), predicate: fn (T) bool) bool {
    return findFirstOrNull(T, list, predicate) != null;
}

const Locks = std.ArrayList(std.Thread.Mutex);

fn TimestampedValue(comptime V: type) type {
    return struct {
        const Self = @This();

        value: *V,
        milli_ts: i64,

        fn of(value: *V) Self {
            return .{
                .value = value,
                .milli_ts = std.time.milliTimestamp(),
            };
        }
    };
}

pub fn BlockingStringMap() type {
    return BlockingMap([]const u8, StringHandler);
}

pub const StringHandler = struct {
    pub fn alloc(allocator: Allocator, value: []const u8) Allocator.Error!*[]const u8 {
        const ptr = try allocator.create([]const u8);
        ptr.* = try allocator.dupe(u8, value);
        return ptr;
    }

    pub fn free(allocator: Allocator, value: *[]const u8) void {
        allocator.free(value.*);
        allocator.destroy(value);
    }
};

pub const ArrayListStringHandler = struct {
    pub fn alloc(allocator: Allocator, value: std.ArrayList([]const u8)) Allocator.Error!*std.ArrayList([]const u8) {
        const ptr = try allocator.create(std.ArrayList([]const u8));
        ptr.* = std.ArrayList([]const u8).init(allocator);

        try ptr.ensureTotalCapacity(value.items.len);
        for (value.items) |it| {
            try ptr.append(try allocator.dupe(u8, it));
        }

        return ptr;
    }

    pub fn free(allocator: Allocator, value: *std.ArrayList([]const u8)) void {
        for (value.items) |it| {
            allocator.free(it);
        }

        value.deinit();
        allocator.destroy(value);
    }
};

/// Key and value memory are all managed by this map. Deinitialize with `deinit`.
/// Handler defines how to clone and free values of type V.
// TODO sharded locking cannot protect concurrent resizing, extra cooperation is needed
pub fn BlockingMap(comptime V: type, comptime Handler: type) type {
    comptime {
        if (!@hasDecl(Handler, "alloc") or !@hasDecl(Handler, "free")) {
            @compileError("Handler must have alloc and free methods");
        }

        const alloc_type = @TypeOf(Handler.alloc);
        if (alloc_type != fn (Allocator, V) Allocator.Error!*V) {
            @compileError("Handler.alloc must have signature `fn(Allocator, V) Allocator.Error!*V`");
        }

        const free_type = @TypeOf(Handler.free);
        if (free_type != fn (Allocator, *V) void) {
            @compileError("Handler.free must have signature `fn(Allocator, *V) void`");
        }
    }

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

        pub fn deinit(self: *Self) void {
            self.cleanup(null, null) catch |err| {
                std.debug.print("deinit cleanup error: {}\n", .{err});
                return;
            };

            self.locks.deinit();
            self.allocator.destroy(self.locks);

            self.m.deinit();
            self.allocator.destroy(self.m);
        }

        pub fn refresh(self: *Self, key: []const u8) void {
            _ = self.guard("refresh", key, null, struct {
                fn callback(ctx: GuardContext) Allocator.Error!GuardResult {
                    const v = ctx.self.m.getPtr(ctx.key);
                    if (v) |vv| {
                        vv.milli_ts = std.time.milliTimestamp();
                    }
                    return .{ .get = null };
                }
            }.callback) catch unreachable;
        }

        pub fn cleanup(self: *Self, exclude_key: ?[]const u8, age_limit_in_sec: ?i64) !void {
            // TODO this lock all mutex, possible to optimize?
            for (self.locks.items) |*l| l.lock();
            defer for (self.locks.items) |*l| l.unlock();

            var keys_to_remove = std.ArrayList([]const u8).init(self.allocator);
            defer keys_to_remove.deinit();

            var iter = self.m.iterator();
            while (iter.next()) |kv| {
                if (age_limit_in_sec) |sec| {
                    const age = std.time.milliTimestamp() - kv.value_ptr.*.milli_ts;
                    if (age > 1000 * sec) {
                        if (exclude_key == null or !std.mem.eql(u8, exclude_key.?, kv.key_ptr.*)) {
                            try keys_to_remove.append(kv.key_ptr.*);
                        }
                    }
                } else {
                    if (exclude_key == null or !std.mem.eql(u8, exclude_key.?, kv.key_ptr.*)) {
                        try keys_to_remove.append(kv.key_ptr.*);
                    }
                }
            }

            for (keys_to_remove.items) |k| {
                const v = self.m.get(k);

                _ = self.m.remove(k);

                if (v) |it| {
                    Handler.free(self.allocator, it.value);
                }

                std.debug.print(
                    "tid:{} time:{} fn:cleanup | remove key: {s}\n",
                    .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), k },
                );

                self.allocator.free(k);
            }
        }

        pub fn put(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            const result = try self.guard(
                "put",
                key,
                .{ .direct = value },
                struct {
                    fn callback(ctx: GuardContext) Allocator.Error!GuardResult {
                        freeOldValueIfExists(ctx.self, ctx.key);

                        // value is guaranteed non-null for put
                        try ctx.self.m.put(
                            ctx.key,
                            try createTSV(ctx.self, ctx.value.?.direct.?),
                        );

                        return .{ .put = {} };
                    }
                }.callback,
            );

            switch (result) {
                .put => return,
                .get => unreachable, // Should never happen
            }
        }

        pub fn putWithValueFn(self: *Self, key: []const u8, value: fn () V) Allocator.Error!void {
            const result = try self.guard(
                "put",
                key,
                .{ .fn_ptr = value },
                struct {
                    fn callback(ctx: GuardContext) Allocator.Error!GuardResult {
                        freeOldValueIfExists(ctx.self, ctx.key);
                        try ctx.self.m.put(
                            ctx.key,
                            try createTSV(ctx.self, ctx.value.?.fn_ptr.?()),
                        );
                        return .{ .put = {} };
                    }
                }.callback,
            );

            switch (result) {
                .put => return,
                .get => unreachable, // Should never happen
            }
        }

        pub fn putRaw(self: *Self, key: []const u8, value: V) Allocator.Error!void {
            self.freeOldValueIfExists(key);
            try self.m.put(
                try self.getManagedKey(key),
                try self.createTSV(value),
            );
        }

        fn freeOldValueIfExists(self: *Self, key: []const u8) void {
            if (self.m.contains(key)) {
                const old_v = self.m.get(key);
                if (old_v) |it| {
                    Handler.free(self.allocator, it.value);
                }
            }
        }

        fn getManagedKey(self: *Self, unmanaged_key: []const u8) ![]const u8 {
            if (self.m.getKey(unmanaged_key)) |managed_key| {
                return managed_key;
            }
            return try self.allocator.dupe(u8, unmanaged_key);
        }

        fn createTSV(self: *Self, unmanaged_value: V) Allocator.Error!TSV {
            return TSV.of(try Handler.alloc(self.allocator, unmanaged_value));
        }

        pub fn get(self: *Self, key: []const u8) ?*V {
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
            ) catch |err| {
                std.debug.print("Error in get: {}\n", .{err});
                return null;
            };

            self.cleanup(key, 60) catch |err| {
                std.debug.print("cleanup error: {}\n", .{err});
                return null;
            };

            switch (result) {
                .put => unreachable, // Should never happen
                .get => |v| return v,
            }
        }

        const GuardValue = union(enum) {
            direct: ?V,
            fn_ptr: ?*const fn () V,
        };

        const GuardContext = struct {
            self: *Self,
            key: []const u8,
            value: ?GuardValue,
        };

        const GuardResult = union(enum) {
            put: void,
            get: ?*V,
        };

        const GuardCallback = fn (ctx: GuardContext) Allocator.Error!GuardResult;

        fn guard(
            self: *Self,
            op: []const u8,
            key: []const u8,
            value: ?GuardValue,
            comptime callback: GuardCallback,
        ) Allocator.Error!GuardResult {
            const hash = self.m.ctx.hash(key);
            const lock_index: u64 = hash % self.locks.items.len;

            std.debug.print(
                "tid:{} time:{} fn:guard | op: {s}, key: {s}, hash: {d}, lock_index: {d}\n",
                .{ std.Thread.getCurrentId(), std.time.nanoTimestamp(), op, key, hash, lock_index },
            );

            // TODO support re-entrancy
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

            const managed_key = try self.getManagedKey(key);
            defer if (!self.m.contains(managed_key)) self.allocator.free(managed_key);

            return callback(.{
                .self = self,
                .key = managed_key,
                .value = value,
            });
        }

        /// Must be paired with `unlock` to avoid deadlock.
        pub fn lock(self: *Self, key: []const u8) void {
            const hash = self.m.ctx.hash(key);
            const lock_index: u64 = hash % self.locks.items.len;

            const l = &self.locks.items[lock_index];
            l.lock();
        }

        // Must be called after `lock` to release the mutex.
        pub fn unlock(self: *Self, key: []const u8) void {
            const hash = self.m.ctx.hash(key);
            const lock_index: u64 = hash % self.locks.items.len;

            const l = &self.locks.items[lock_index];
            l.unlock();
        }
    };
}

const testing = std.testing;

test "BlockingStringMap basic put and get" {
    var map = try BlockingStringMap().init(testing.allocator);
    defer map.deinit();

    try map.put("k1", "v1");

    try testing.expectEqualStrings("v1", map.get("k1").?.*);
    try testing.expectEqual(null, map.get("k2"));
}

test "BlockingStringMap putWithValueFn" {
    var map = try BlockingStringMap().init(testing.allocator);
    defer map.deinit();

    const valueFn = struct {
        fn getValue() []const u8 {
            return "v";
        }
    }.getValue;

    try map.putWithValueFn("k", valueFn);

    try testing.expectEqualStrings("v", map.get("k").?.*);
}

test "BlockingStringMap concurrent put and get" {
    var map = try BlockingStringMap().init(testing.allocator);
    defer map.deinit();

    const Worker = struct {
        fn putWorker(m: *BlockingStringMap()) !void {
            try m.put("k", "v");
        }
        fn getWorker(m: *BlockingStringMap()) !void {
            std.Thread.sleep(std.time.ns_per_ms * 100); // Wait for put
            try testing.expectEqualStrings("v", m.get("k").?.*);
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.putWorker, .{&map});
    const t2 = try std.Thread.spawn(.{}, Worker.getWorker, .{&map});

    t1.join();
    t2.join();
}

test "BlockingStringMap cleanup age-based" {
    var map = try BlockingStringMap().init(testing.allocator);
    defer map.deinit();

    try map.put("k1", "v1");
    try map.put("k2", "v2");

    // Set custom timestamps to simulate old entries
    var iter = map.m.iterator();
    while (iter.next()) |kv| {
        kv.value_ptr.milli_ts = std.time.milliTimestamp() - 40_000;
    }

    // Insert a fresh key
    try map.put("k3", "v3");

    // Cleanup entries older than 30 seconds, exclude k3
    try map.cleanup("k3", 30);

    try testing.expectEqual(null, map.get("k1"));
    try testing.expectEqual(null, map.get("k2"));
    try testing.expectEqualStrings("v3", map.get("k3").?.*);
}

test "BlockingStringMap memory management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var map = try BlockingStringMap().init(allocator);
    try map.put("k1", "v1");
    try map.put("k2", "v2");

    // `get` triggers `cleanup`, but no keys' age is old enough
    _ = map.get("k1");
    try testing.expectEqual(true, map.m.contains("k1") and map.m.contains("k2"));

    // deinit will free remaning resources
    map.deinit();

    // Check for leaks via gpa.deinit()
}

test "BlockingStringMap manual lock and unlock" {
    var map = try BlockingStringMap().init(testing.allocator);
    defer map.deinit();

    // Separated code block scope, otherwise the consequent `map.get` will panic
    // with Deadlock. Current Zig `Mutex` is not re-entrant-able.
    {
        map.lock("k1");
        defer map.unlock("k1");

        try map.putRaw("k1", "v1");
    }

    try testing.expectEqualStrings("v1", map.get("k1").?.*);
}

test "BlockingMap basic put and get with ArrayList([]const u8)" {
    var map = try BlockingMap(std.ArrayList([]const u8), ArrayListStringHandler).init(testing.allocator);
    defer map.deinit();

    var list = std.ArrayList([]const u8).init(testing.allocator);
    defer list.deinit();

    try list.append("item1");
    try list.append("item2");

    try map.put("k1", list);

    if (map.get("k1")) |value| {
        try testing.expectEqual(2, value.items.len);
        try testing.expectEqualStrings("item1", value.items[0]);
        try testing.expectEqualStrings("item2", value.items[1]);
    } else {
        try testing.expect(false);
    }

    try testing.expectEqual(null, map.get("k2"));
}

const ModelMessage = struct {
    role: ModelMessageRole,
    content: []const u8,
};

const ModelMessageRole = enum {
    user,
    assistant,
};

const ArrayListMessageHandler = struct {
    fn alloc(allocator: Allocator, value: std.ArrayList(ModelMessage)) Allocator.Error!*std.ArrayList(ModelMessage) {
        const ptr = try allocator.create(std.ArrayList(ModelMessage));
        ptr.* = std.ArrayList(ModelMessage).init(allocator);

        try ptr.ensureTotalCapacity(value.items.len);
        for (value.items) |it| {
            try ptr.append(.{
                .role = it.role,
                .content = try allocator.dupe(u8, it.content),
            });
        }

        return ptr;
    }

    fn free(allocator: Allocator, value: *std.ArrayList(ModelMessage)) void {
        for (value.items) |it| {
            allocator.free(it.content);
        }

        value.deinit();
        allocator.destroy(value);
    }
};

test "BlockingMap basic put and get with ArrayList(ModelMessage)" {
    var map = try BlockingMap(std.ArrayList(ModelMessage), ArrayListMessageHandler).init(testing.allocator);
    defer map.deinit();

    var list = std.ArrayList(ModelMessage).init(testing.allocator);
    defer list.deinit();

    try list.append(.{ .role = .user, .content = "question" });
    try list.append(.{ .role = .assistant, .content = "answer" });

    try map.put("k1", list);

    // Verify initial state
    if (map.get("k1")) |v| {
        try testing.expectEqual(2, v.items.len);

        try testing.expectEqual(ModelMessageRole.user, v.items[0].role);
        try testing.expectEqualStrings("question", v.items[0].content);

        try testing.expectEqual(ModelMessageRole.assistant, v.items[1].role);
        try testing.expectEqualStrings("answer", v.items[1].content);
    } else {
        try testing.expect(false);
    }

    // Update the list in place
    if (map.get("k1")) |v| {
        try v.append(.{ .role = .user, .content = try map.allocator.dupe(u8, "hello") });
    }

    // Verify updated state
    if (map.get("k1")) |v| {
        try testing.expectEqual(3, v.items.len);

        try testing.expectEqual(ModelMessageRole.user, v.items[0].role);
        try testing.expectEqualStrings("question", v.items[0].content);

        try testing.expectEqual(ModelMessageRole.assistant, v.items[1].role);
        try testing.expectEqualStrings("answer", v.items[1].content);

        try testing.expectEqual(ModelMessageRole.user, v.items[2].role);
        try testing.expectEqualStrings("hello", v.items[2].content);
    } else {
        try testing.expect(false);
    }

    try testing.expectEqual(null, map.get("k2"));
}
