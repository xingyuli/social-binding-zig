const std = @import("std");

const httpz = @import("httpz");
const Action = httpz.Action;
const Group = httpz.routing.Group;

const utils = @import("../utils/utils.zig");
const XmlNode = utils.xml.XmlNode;
const App = @import("../app.zig");

const db = @import("../middleware/db/db.zig");
const llm = @import("../middleware/llm.zig");

const log = std.log.scoped(.routes__wechat);

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

    log.debug("s: {s}, t: {s}, n: {s}, e: {s}", .{ signature.?, timestamp.?, nonce.?, echostr orelse "" });

    var params = [_][]const u8{ app.config.wx.token, timestamp.?, nonce.? };

    std.mem.sort([]const u8, &params, {}, utils.text.StringOrder.asc);
    for (params) |it| {
        log.debug("{s}", .{it});
    }

    const combined = try std.mem.concat(resp.arena, u8, &params);
    log.debug("combined: {s}", .{combined});

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(combined, &digest, .{});

    var hex: [std.crypto.hash.Sha1.digest_length * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{s}", .{std.fmt.fmtSliceHexLower(&digest)}) catch unreachable;
    log.debug("hex: {s}", .{hex});

    if (std.mem.eql(u8, &hex, signature.?)) {
        resp.body = echostr.?;
    } else {
        resp.body = "-1";
    }
}

fn handleMessage(app: *App, req: *httpz.Request, resp: *httpz.Response) !void {
    const req_body = req.body().?;
    log.debug("received req_body: {s}", .{req_body});

    const nodes = try utils.xml.readTextAsNodes(resp.arena, req_body);
    defer {
        for (nodes.items) |it| {
            it.deinit();
        }
        nodes.deinit();
    }

    const from_user_name = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("FromUserName"));

    const msg_type_node = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("MsgType"));
    const msg_type = utils.enums.fromStringOrNull(MsgType, msg_type_node.element_value.?);

    var resp_body: []const u8 = undefined;

    if (msg_type) |it| {
        switch (it) {
            .event => {
                const event = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("Event"));
                resp_body = handleEvent(
                    .{ .sqlite = app.sqlite, .arena = resp.arena },
                    event.element_value.?,
                    from_user_name.element_value.?,
                );
            },
            .text, .image, .voice, .video, .shortvideo, .location, .link => {
                const to_user_name = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("ToUserName"));
                const content = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("Content"));
                const msg_id = try utils.collection.findFirst(*XmlNode, nodes, xmlNodeNamePredicate("MsgId"));

                var out_content: []const u8 = undefined;
                if (!utils.text.isEmptyStr(content.element_value)) {
                    const msg_id_value = msg_id.element_value.?;
                    const cached_result = app.llm_cache.get(msg_id_value);

                    if (cached_result) |r| {
                        out_content = r;
                    } else {
                        app.llm_cache.lock(msg_id_value);
                        defer app.llm_cache.unlock(msg_id_value);

                        const model = try app.llm_client.chatCompletion(llm.Provider.SparkLite, content.element_value.?);
                        defer model.deinit();

                        const answer = try app.llm_cache.allocator.dupe(u8, model.value.choices[0].message.content);
                        try app.llm_cache.putRaw(try app.llm_cache.allocator.dupe(u8, msg_id_value), answer);
                        out_content = answer;
                    }
                } else {
                    out_content = "来都来了，说点什么吧 😊";
                }

                resp_body = try handleNormalMessage(
                    resp.arena,
                    from_user_name.element_value.?,
                    to_user_name.element_value.?,
                    out_content,
                );
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

fn handleEvent(ctx: db.QueryContext, event: []const u8, from_user_name: []const u8) []const u8 {
    if (std.mem.eql(u8, event, "subscribe")) {
        db.account.onWxSubscribe(ctx, from_user_name);
    } else if (std.mem.eql(u8, event, "unsubscribe")) {
        db.account.onWxUnsubscribe(ctx, from_user_name);
    }

    return "success";
}

fn handleNormalMessage(
    allocator: std.mem.Allocator,
    from_user_name: []const u8,
    to_user_name: []const u8,
    content: []const u8,
) ![]const u8 {
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

    return try std.fmt.allocPrint(allocator, text_output_template, .{
        from_user_name,
        to_user_name,
        create_time,
        content,
    });
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
