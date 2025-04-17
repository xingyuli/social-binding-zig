const std = @import("std");

const httpz = @import("httpz");
const Action = httpz.Action;
const Group = httpz.routing.Group;

const utils = @import("../utils/utils.zig");
const XmlNode = utils.xml.XmlNode;
const App = @import("../app.zig");

pub fn mount(group: *Group(*App, Action(*App))) void {
    group.get("", verifySignature, .{});
    group.post("", handleMessage, .{});
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

    if (utils.text.isEmptyStr(signature) or utils.text.isEmptyStr(timestamp) or utils.text.isEmptyStr(nonce)) {
        resp.status = 400;
        return;
    }

    std.debug.print("s: {s}, t: {s}, n: {s}, e: {s}\n", .{ signature.?, timestamp.?, nonce.?, echostr orelse "" });

    var params = [_][]const u8{ app.config.wx.token, timestamp.?, nonce.? };

    std.mem.sort([]const u8, &params, {}, utils.text.StringOrder.asc);
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

fn handleMessage(app: *App, req: *httpz.Request, resp: *httpz.Response) !void {
    _ = app;

    const req_body = req.body().?;
    std.debug.print("received req_body: {s}\n", .{req_body});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const nodes = try utils.xml.readTextAsNodes(arena.allocator(), req_body);
    defer {
        for (nodes.items) |it| {
            it.deinit();
        }
        nodes.deinit();
    }

    const msg_type_node = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("MsgType"));
    const msg_type = utils.enums.fromStringOrNull(MsgType, msg_type_node.element_value.?);

    var resp_body: []const u8 = undefined;

    if (msg_type) |it| {
        switch (it) {
            .event => {
                // TODO handle event: subscribe, unsubscribe
            },
            .text, .image, .voice, .video, .shortvideo, .location, .link => {
                const from_user_name = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("FromUserName"));
                const to_user_name = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("ToUserName"));
                resp_body = try handleNormalMessage(resp.arena, from_user_name.element_value.?, to_user_name.element_value.?);
            },
        }
    } else {
        resp_body = "success";
    }

    resp.body = resp_body;
}

fn xmlNodeNamePredicate(comptime element_name: []const u8) fn (*XmlNode) bool {
    return struct {
        fn predicate(node: *XmlNode) bool {
            return std.mem.eql(u8, node.element_name, element_name);
        }
    }.predicate;
}

fn handleNormalMessage(allocator: std.mem.Allocator, from_user_name: []const u8, to_user_name: []const u8) ![]const u8 {
    const text_output_template =
        \\<xml>
        \\  <ToUserName><![CDATA[{s}]]></ToUserName>
        \\  <FromUserName><![CDATA[{s}]]></FromUserName>
        \\  <CreateTime>{d}</CreateTime>
        \\  <MsgType><![CDATA[text]]></MsgType>
        \\  <Content><![CDATA[{s}]]></Content>
        \\</xml>
    ;

    const create_time: i64 = @divFloor(std.time.milliTimestamp(), 1000);
    const content = "handle normal message";
    return try std.fmt.allocPrint(allocator, text_output_template, .{ from_user_name, to_user_name, create_time, content });
}

// *********************
// ***** protocols *****
// *********************

const MsgType = enum {
    event,
    text,
    image,
    voice,
    video,
    shortvideo,
    location,
    link,
};
