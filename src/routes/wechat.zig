const std = @import("std");

const httpz = @import("httpz");
const Action = httpz.Action;
const Group = httpz.routing.Group;

const App = @import("../app.zig");

pub fn mount(group: *Group(*App, Action(*App))) void {
    group.get("", verifySignature, .{});
}

// *******************
// ***** actions *****
// *******************

fn verifySignature(app: *App, req: *httpz.Request, resp: *httpz.Response) !void {
    const query = try req.query();

    const signature = query.get("signature");
    const timestamp = query.get("timestamp");
    const nonce = query.get("nonce");
    const echostr = query.get("echostr");

    if (isEmptyStr(signature) or isEmptyStr(timestamp) or isEmptyStr(nonce)) {
        resp.status = 400;
        return;
    }

    std.debug.print("s: {s}, t: {s}, n: {s}, e: {s}\n", .{ signature.?, timestamp.?, nonce.?, echostr orelse "" });

    var params = [_][]const u8{ app.config.wx.token, timestamp.?, nonce.? };

    std.mem.sort([]const u8, &params, {}, StringOrder.asc);
    for (params) |it| {
        std.debug.print("{s}\n", .{it});
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const combined = try std.mem.concat(arena.allocator(), u8, &params);
    std.debug.print("combined: {s}\n", .{combined});

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &digest, .{});

    var hex: [std.crypto.hash.Sha1.digest_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    std.debug.print("hex: {s}\n", .{hex});

    if (std.mem.eql(u8, &hex, signature.?)) {
        resp.body = echostr.?;
    } else {
        resp.body = "-1";
    }
}

// *****************
// ***** other *****
// *****************

fn isEmptyStr(str: ?[]const u8) bool {
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

const StringOrder = struct {
    pub fn asc(_: void, lhs: []const u8, rhs: []const u8) bool {
        return std.mem.lessThan(u8, lhs, rhs);
    }
};
