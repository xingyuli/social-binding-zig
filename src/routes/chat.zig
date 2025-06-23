const std = @import("std");

const httpz = @import("httpz");
const Action = httpz.Action;
const Group = httpz.routing.Group;

const utils = @import("../utils/utils.zig");
const App = @import("../app.zig");

const db = @import("../middleware/db/db.zig");
const llm = @import("../middleware/llm.zig");

const log = std.log.scoped(.routes__chat);

const uuid = @import("uuid");

pub fn mount(group: *Group(*App, Action(*App))) void {
    group.post("/session", chatSession, .{});
    group.post("/stream", chatStream, .{});
}

// serves the ChatGPT-Web
fn chatSession(app: *App, req: *httpz.Request, resp: *httpz.Response) !void {
    _ = app;
    _ = req;

    resp.body =
        \\{
        \\  "status": "Success",
        \\  "message": "",
        \\  "data": { "auth": false, "model": "ChatGPTAPI" }
        \\}
    ;
}

fn chatStream(app: *App, req: *httpz.Request, resp: *httpz.Response) !void {
    var req_body = req.json(ChatRequest) catch unreachable orelse unreachable;

    var parent_message_id: ?[]const u8 = null;
    if (req_body.options) |options| {
        parent_message_id = options.parentMessageId;
    }

    const conversation = try buildConversation(app, resp.arena, &req_body);

    const stream = try resp.startEventStreamSync();
    var context = ChatStreamContext{
        .app = app,
        .arena = resp.arena,
        .stream = stream,

        .prompt_msg = &conversation.messages.getLast(),
        .conversation_id = conversation.id,
        .parent_message_id = parent_message_id,
    };
    // TODO possible to specify bailian model name via request
    try app.llm_client_v2.chatStream(
        llm.Provider.AliQwenPlus,
        app.config.llm_api_keys.ali_qwen_plus.?,
        conversation.messages.items,
        true,
        &context,
        onStreamMessageForSSE,
    );
}

fn buildConversation(app: *App, arena: std.mem.Allocator, payload: *ChatRequest) !Conversation {
    var l = std.ArrayList(llm.ModelMessage).init(arena);

    try l.append(.{ .role = .system, .content = payload.systemMessage });

    var conversation_id: []const u8 = undefined;

    if (payload.options) |options| {
        if (options.parentMessageId) |parent_msg_id| {
            const ctx = db.QueryContext{ .sqlite = app.sqlite, .arena = arena };
            if (db.chat.findById(ctx, parent_msg_id)) |p_msg| {
                conversation_id = p_msg.conversation_id;

                db.chat.markMessageCycleAsDeleted(ctx, parent_msg_id);

                const hist_msgs = db.chat.findAllByConversationId(ctx, p_msg.conversation_id);
                for (hist_msgs.items) |it| {
                    try l.append(.{
                        .role = utils.enums.fromStringOrNull(llm.ModelMessageRole, it.role).?,
                        .content = it.content,
                    });
                }
            } else unreachable;
        } else {
            conversation_id = try arena.dupe(u8, &uuid.urn.serialize(uuid.v4.new()));
        }
    } else {
        conversation_id = try arena.dupe(u8, &uuid.urn.serialize(uuid.v4.new()));
    }

    try l.append(.{ .role = .user, .content = payload.prompt });

    return .{ .id = conversation_id, .messages = l };
}

const Conversation = struct {
    id: []const u8,
    messages: std.ArrayList(llm.ModelMessage),
};

const ChatStreamContext = struct {
    app: *App,
    arena: std.mem.Allocator,
    stream: std.net.Stream,

    prompt_msg: *const llm.ModelMessage,
    conversation_id: []const u8,
    parent_message_id: ?[]const u8,

    is_first: bool = true,
};

fn onStreamMessageForSSE(context: anytype, msg: *llm.ChatMessage, is_last: bool) void {
    const stream: std.net.Stream = context.stream;

    const prompt_msg: *const llm.ModelMessage = context.prompt_msg;
    const conversation_id = context.conversation_id;
    const parent_message_id: ?[]const u8 = context.parent_message_id;

    var buf = std.ArrayList(u8).init(context.arena);
    defer buf.deinit();
    std.json.stringify(msg, .{}, buf.writer()) catch unreachable;

    writeContent(stream, buf.items) catch |err| switch (err) {
        error.BrokenPipe => {
            log.info("Connection is closed by remote peer", .{});
        },
        error.WouldBlock => {
            // simply ignore
        },
        else => unreachable,
    };

    if (is_last) {
        const app: *App = context.app;

        var db_prompt_msg: db.chat.ChatMessage = .{
            .id = &uuid.urn.serialize(uuid.v7.new()),
            .role = @tagName(prompt_msg.role),
            .content = prompt_msg.content,
            .conversation_id = conversation_id,
            .parent_message_id = parent_message_id,
        };

        var db_answer_msg: db.chat.ChatMessage = .{
            .id = msg.id.?,
            .role = @tagName(msg.role),
            .content = msg.text,
            .conversation_id = conversation_id,
            .parent_message_id = db_prompt_msg.id,
        };

        const ctx = db.QueryContext{ .sqlite = app.sqlite, .arena = context.arena };
        // TODO feat: batch insert ?
        db.chat.saveMessage(ctx, &db_prompt_msg) catch unreachable;
        db.chat.saveMessage(ctx, &db_answer_msg) catch unreachable;
    }

    context.is_first = false;
}

fn writeContent(stream: std.net.Stream, content: []u8) std.net.Stream.WriteError!void {
    try stream.writeAll(content);
    try stream.writeAll("\n\n");
}

// *********************
// ***** protocols *****
// *********************

const ChatRequest = struct {
    prompt: []const u8,
    options: ?ChatRequestOptions = null,
    systemMessage: []const u8,
    temperature: f64,
    top_p: f64,
};

const ChatRequestOptions = struct {
    parentMessageId: ?[]const u8 = null,
};
