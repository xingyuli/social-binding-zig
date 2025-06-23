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

    var nodes = try utils.xml.readTextAsNodes(resp.arena, req_body);
    defer {
        for (nodes.items) |it| {
            it.deinit();
        }
        nodes.deinit();
    }

    const from_user_name = try utils.collection.findFirst(*XmlNode, &nodes, xmlNodeNamePredicate("FromUserName"));

    const msg_type_node = try utils.collection.findFirst(*XmlNode, &nodes, xmlNodeNamePredicate("MsgType"));
    const msg_type = utils.enums.fromStringOrNull(MsgType, msg_type_node.element_value.?);

    var resp_body: []const u8 = undefined;

    if (msg_type) |it| {
        switch (it) {
            .event => {
                const event = try utils.collection.findFirst(*XmlNode, &nodes, xmlNodeNamePredicate("Event"));
                resp_body = handleEvent(
                    .{ .sqlite = app.sqlite, .arena = resp.arena },
                    event.element_value.?,
                    from_user_name.element_value.?,
                );
            },
            .text, .image, .voice, .video, .shortvideo, .location, .link => {
                const to_user_name = try utils.collection.findFirst(*XmlNode, &nodes, xmlNodeNamePredicate("ToUserName"));
                const content = try utils.collection.findFirst(*XmlNode, &nodes, xmlNodeNamePredicate("Content"));
                const msg_id = try utils.collection.findFirst(*XmlNode, &nodes, xmlNodeNamePredicate("MsgId"));

                var out_content: []const u8 = undefined;
                if (!utils.text.isEmptyStr(content.element_value)) {
                    const from_user_name_value = from_user_name.element_value.?;
                    const msg_id_value = msg_id.element_value.?;
                    const content_value = content.element_value.?;

                    log.debug("cache size: {d}", .{app.llm_session_cache.m.count()});

                    // extend session
                    app.llm_session_cache.refresh(from_user_name_value);

                    const cached_result = app.llm_session_cache.get(from_user_name_value);

                    var need_chat = true;
                    if (cached_result) |r| {
                        for (r.items, 0..) |item, index| {
                            log.debug(
                                "[{d}] prompt_tokens: {d}, completion_tokens: {d}, total_tokens: {d}\n\tid: {s}\n\tin: {s},\n\tout: {?s}",
                                .{
                                    index,
                                    item.usage.prompt_tokens,
                                    item.usage.completion_tokens,
                                    item.usage.total_tokens,
                                    item.id,
                                    item.in.content,
                                    item.out.content,
                                },
                            );
                        }

                        if (getCachedByMsgId(r, msg_id_value)) |cached| {
                            out_content = try concatWithTokenStat(resp, cached.out.content, cached.usage);
                            need_chat = false;
                        }
                    }

                    if (need_chat) {
                        const chat_resp = try sendChat(app, from_user_name_value, msg_id_value, content_value, cached_result, resp);
                        defer chat_resp.deinit();
                        out_content = try concatWithTokenStat(resp, chat_resp.value.choices[0].message.content, chat_resp.value.usage);
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

fn sendChat(
    app: *App,
    from_user_name: []const u8,
    msg_id: []const u8,
    content: []const u8,
    cached_result: ?*std.ArrayList(App.MessageRound),
    resp: *httpz.Response,
) !std.json.Parsed(llm.ResponseModel) {
    app.llm_session_cache.lock(from_user_name);
    defer app.llm_session_cache.unlock(from_user_name);

    var messages = std.ArrayList(llm.ModelMessage).init(resp.arena);
    defer messages.deinit();

    if (cached_result) |r| {
        for (r.items) |it| {
            try messages.append(it.in);
            try messages.append(it.out);
        }
    }

    try messages.append(.{ .role = .user, .content = content });

    const model = try app.llm_client_v2.chatCompletionWithMessages(
        llm.Provider.SparkLite,
        app.config.llm_api_keys.spark_lite.?,
        messages.items,
    );

    const answer = model.value.choices[0].message.content;

    if (cached_result) |r| {
        try r.append(.{
            .id = try app.llm_session_cache.allocator.dupe(u8, msg_id),
            .in = .{ .role = .user, .content = try app.llm_session_cache.allocator.dupe(u8, content) },
            .out = .{ .role = .assistant, .content = try app.llm_session_cache.allocator.dupe(u8, answer) },
            .usage = model.value.usage,
        });
    } else {
        var l = std.ArrayList(App.MessageRound).init(resp.arena);
        try l.append(.{
            .id = msg_id,
            .in = .{ .role = .user, .content = content },
            .out = .{ .role = .assistant, .content = answer },
            .usage = model.value.usage,
        });
        try app.llm_session_cache.putRaw(from_user_name, l);
    }

    return model;
}

fn concatWithTokenStat(resp: *httpz.Response, out: []const u8, usage: llm.ModelUsage) ![]const u8 {
    return try std.fmt.allocPrint(resp.arena, "会话统计: 输入 {d}/{d}, 输出 {d}/{d}\n\n{s}", .{
        usage.prompt_tokens,
        llm.Provider.SparkLite.in_limit,
        usage.completion_tokens,
        llm.Provider.SparkLite.out_limit,
        out,
    });
}

fn xmlNodeNamePredicate(comptime element_name: []const u8) fn (*XmlNode) bool {
    return struct {
        fn predicate(node: *XmlNode) bool {
            return std.mem.eql(u8, node.element_name, element_name);
        }
    }.predicate;
}

fn getCachedByMsgId(l: *std.ArrayList(App.MessageRound), msg_id: []const u8) ?App.MessageRound {
    for (l.items) |it| {
        if (std.mem.eql(u8, it.id, msg_id)) {
            return it;
        }
    }
    return null;
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
