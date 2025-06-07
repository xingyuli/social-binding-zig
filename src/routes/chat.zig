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

    // opiton 1. direct processing: works, but stuck with one final shot

    // // ChatGPT-Web consumes this:
    // resp.content_type = .BINARY;

    // var context = StreamContext{ .resp = resp };
    // try app.llm_client_v2.chatStream(
    //     llm.Provider.AliQwenTurbo,
    //     &messages,
    //     &context,
    //     true,
    //     onStreamMessage,
    // );

    // option 2. built-in SSE sync: works

    const stream = try resp.startEventStreamSync();
    var context = ChatStreamContext{
        .app = app,
        .arena = resp.arena,
        .stream = stream,

        .prompt_msg = &conversation.messages.getLast(),
        .conversation_id = conversation.id,
        .parent_message_id = parent_message_id,
    };
    try app.llm_client_v2.chatStream(
        llm.Provider.AliQwenTurbo,
        conversation.messages.items,
        true,
        &context,
        onStreamMessageForSSE,
    );
    stream.close();
}

// option 1

// const StreamContext = struct {
//     resp: *httpz.Response,
//     is_first: bool = true,
// };

// fn onStreamMessage(context: anytype, msg: *llm.ChatMessage) void {
//     const resp = context.resp;

//     var buf = std.ArrayList(u8).init(resp.arena);
//     defer buf.deinit();
//     std.json.stringify(msg, .{}, buf.writer()) catch unreachable;

//     if (!context.is_first) {
//         resp.writer().writeByte('\n') catch unreachable;
//     }

//     _ = resp.writer().write(buf.items) catch unreachable;

//     context.is_first = false;
// }

// option 2

fn buildConversation(app: *App, arena: std.mem.Allocator, payload: *ChatRequest) !Conversation {
    var l = std.ArrayList(llm.ModelMessage).init(arena);

    try l.append(.{ .role = .system, .content = payload.systemMessage });

    var conversation_id: []const u8 = undefined;

    if (payload.options) |options| {
        if (options.parentMessageId) |parent_msg_id| {
            const optional_p_msg = db.chat.findById(
                .{ .sqlite = app.sqlite, .arena = arena },
                parent_msg_id,
            );
            if (optional_p_msg) |p_msg| {
                conversation_id = p_msg.conversation_id;

                const hist_msgs = db.chat.findAllByConversationId(
                    .{ .sqlite = app.sqlite, .arena = arena },
                    p_msg.conversation_id,
                );
                for (hist_msgs.items) |it| {
                    try l.append(.{
                        .role = utils.enums.fromStringOrNull(llm.ModelMessageRole, it.role).?,
                        .content = it.content,
                    });
                }
            }
        } else {
            conversation_id = try arena.dupe(u8, &uuid.urn.serialize(uuid.v4.new()));
        }
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
    const prompt_msg: *const llm.ModelMessage = context.prompt_msg;
    const conversation_id = context.conversation_id;
    const parent_message_id: ?[]const u8 = context.parent_message_id;

    var buf = std.ArrayList(u8).init(context.arena);
    defer buf.deinit();
    std.json.stringify(msg, .{}, buf.writer()) catch unreachable;

    var content = buf.items;
    if (!context.is_first) {
        content = std.fmt.allocPrint(context.arena, "\n{s}", .{buf.items}) catch unreachable;
    }
    context.stream.writeAll(content) catch unreachable;

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

        // TODO feat: batch insert ?
        db.chat.saveMessage(.{ .sqlite = app.sqlite, .arena = context.arena }, &db_prompt_msg) catch unreachable;
        db.chat.saveMessage(.{ .sqlite = app.sqlite, .arena = context.arena }, &db_answer_msg) catch unreachable;
    }

    context.is_first = false;
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
