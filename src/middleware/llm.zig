const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.middleware__llm);

pub const Provider = struct {
    base_url: []const u8,
    api_path_chat_completions: []const u8,
    model: []const u8,

    in_limit: i32 = -1,
    out_limit: i32 = -1,

    pub const DeepSeek = Provider{
        .base_url = "https://api.deepseek.com",
        .api_path_chat_completions = "/chat/completions",
        .model = "deepseek-chat",
    };

    pub const MiniMax = Provider{
        .base_url = "https://api.minimax.chat/v1",
        .api_path_chat_completions = "/text/chatcompletion_v2",
        .model = "MiniMax-Text-01",
    };

    pub const AliQwenPlus = Provider{
        .base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1",
        .api_path_chat_completions = "/chat/completions",
        .model = "qwen-plus",
    };

    pub const AliQwenTurbo = Provider{
        .base_url = "https://dashscope.aliyuncs.com/compatible-mode/v1",
        .api_path_chat_completions = "/chat/completions",
        .model = "qwen-turbo",
    };

    pub const SparkLite = Provider{
        .base_url = "https://spark-api-open.xf-yun.com/v1",
        .api_path_chat_completions = "/chat/completions",
        .model = "lite",

        // 最大输入长度: 8K
        .in_limit = 1024 * 8,

        // 最大输出长度: 4K
        .out_limit = 1024 * 4,
    };
};

// TODO remove Client once ClientV2 has been running for a long period
pub const Client = struct {
    api_key: []const u8,
    allocator: Allocator,

    client: std.http.Client = undefined,
    header_buf: []u8 = undefined,
    resp_body_buf: []u8 = undefined,

    pub fn init(api_key: []const u8, allocator: Allocator) !Client {
        return .{
            .api_key = api_key,
            .allocator = allocator,

            .client = .{ .allocator = allocator },
            .header_buf = try allocator.alloc(u8, 1024 * 8),
            .resp_body_buf = try allocator.alloc(u8, 1024 * 8),
        };
    }

    pub fn deinit(self: *Client) void {
        self.allocator.free(self.resp_body_buf);
        self.allocator.free(self.header_buf);
        self.client.deinit();
    }

    pub fn chatCompletion(self: *Client, provider: Provider, question: []const u8) !std.json.Parsed(ResponseModel) {
        var messages = [_]ModelMessage{
            .{ .role = .user, .content = question },
        };
        return self.chatCompletionWithMessages(provider, &messages);
    }

    pub fn chatCompletionWithMessages(self: *Client, provider: Provider, messages: []ModelMessage) !std.json.Parsed(ResponseModel) {
        var model = RequestModel{
            .model = provider.model,
            .messages = messages,
        };
        return self.doChatCompletion(provider, &model);
    }

    fn doChatCompletion(self: *Client, provider: Provider, model: *RequestModel) !std.json.Parsed(ResponseModel) {
        const full_api_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ provider.base_url, provider.api_path_chat_completions });
        defer self.allocator.free(full_api_path);

        const uri = std.Uri.parse(full_api_path) catch unreachable;

        var bearer: [1024]u8 = undefined;
        var request = try self.client.open(.POST, uri, .{ .server_header_buffer = self.header_buf, .headers = .{
            .authorization = .{ .override = std.fmt.bufPrint(&bearer, "Bearer {s}", .{self.api_key}) catch unreachable },
            .content_type = .{ .override = "application/json" },
        } });
        defer request.deinit();

        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();

        try std.json.stringify(model, .{}, json_buffer.writer());
        const body = json_buffer.items;

        log.debug("Request body: {s}", .{body});

        request.transfer_encoding = .{ .content_length = body.len };

        try request.send();

        try request.writeAll(body);

        try request.finish();

        try request.wait();

        const resp_body_size = try request.reader().readAll(self.resp_body_buf);
        const resp_text = self.resp_body_buf[0..resp_body_size];

        log.debug("Response body: {s}", .{resp_text});

        return try std.json.parseFromSlice(ResponseModel, self.allocator, resp_text, .{ .ignore_unknown_fields = true });
    }
};

pub const RequestModel = struct {
    model: []const u8,
    messages: []ModelMessage,
    stream: bool = false,
    enable_search: ?bool = null,
};

pub const ModelMessage = struct {
    role: ModelMessageRole,
    content: []const u8,
};

pub const ResponseModel = struct {
    // not returned by SparkLite
    // id: []const u8,
    // object: []const u8,
    // created: u32,
    // model: []const u8,

    choices: []ModelChoice,
    usage: ModelUsage,
};

pub const ModelChoice = struct {
    index: u8,
    message: ModelMessage,

    // not returned by SparkLite
    // finish_reason: []const u8,
};

pub const ModelUsage = struct {
    // 用户输入信息, 消耗的token数量
    prompt_tokens: u32,

    // 大模型输出信息, 消耗的token数量
    completion_tokens: u32,

    // 用户输入+大模型输出, 总的token数量
    total_tokens: u32,

    // prompt_tokens_details

    // these two fields are not returned by AliQwen
    // prompt_cache_hit_tokens: u32,
    // prompt_cache_miss_tokens: u32,
};

pub const ModelMessageRole = enum {
    user,
    assistant,
    system,
};

pub const ChatStreamCallback = fn (context: anytype, *ChatMessage, is_last: bool) void;

pub const ClientV2 = struct {
    allocator: Allocator,
    client: std.http.Client,

    pub fn init(allocator: Allocator) ClientV2 {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *ClientV2) void {
        self.client.deinit();
    }

    // ----- one-shot -----

    pub fn chatCompletion(
        self: *ClientV2,
        provider: Provider,
        api_key: []const u8,
        question: []const u8,
    ) !std.json.Parsed(ResponseModel) {
        var messages = [_]ModelMessage{
            .{ .role = .user, .content = question },
        };
        return self.chatCompletionWithMessages(provider, api_key, &messages);
    }

    pub fn chatCompletionWithMessages(
        self: *ClientV2,
        provider: Provider,
        api_key: []const u8,
        messages: []ModelMessage,
    ) !std.json.Parsed(ResponseModel) {
        var model = RequestModel{
            .model = provider.model,
            .messages = messages,
        };
        return self.doChatCompletion(provider, api_key, &model);
    }

    fn doChatCompletion(
        self: *ClientV2,
        provider: Provider,
        api_key: []const u8,
        model: *RequestModel,
    ) !std.json.Parsed(ResponseModel) {
        var cc = ChatCompletion.init(self.allocator, &self.client);
        defer cc.deinit();

        try cc.send(provider, api_key, model);

        const resp_text = try cc.request.?.reader().readAllAlloc(self.allocator, 1024 * 8);
        // defer self.allocator.free(resp_text);

        log.debug("Response body: {s}", .{resp_text});

        return try std.json.parseFromSlice(ResponseModel, self.allocator, resp_text, .{ .ignore_unknown_fields = true });
    }

    // ----- stream -----

    pub fn chatStream(
        self: *ClientV2,
        provider: Provider,
        api_key: []const u8,
        messages: []ModelMessage,
        enable_search: ?bool,
        context: anytype,
        on_message: ChatStreamCallback,
    ) !void {
        var model = RequestModel{
            .model = provider.model,
            .messages = messages,
            .stream = true,
            .enable_search = enable_search,
        };
        try self.doChatStream(provider, api_key, &model, context, on_message);
    }

    fn doChatStream(
        self: *ClientV2,
        provider: Provider,
        api_key: []const u8,
        model: *RequestModel,
        context: anytype,
        on_message: ChatStreamCallback,
    ) !void {
        var cc = ChatCompletion.init(self.allocator, &self.client);
        defer cc.deinit();

        try cc.send(provider, api_key, model);

        var stream_buf: [1024 * 4]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&stream_buf);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_allocator = arena.allocator();
        defer arena.deinit();

        var msg: ChatMessage = .{
            .role = .assistant,
            .text = "",
        };

        while (true) {
            // Reset buffer position for new data
            fbs.reset();

            // Read a chunk of the response
            const bytes_read = try cc.request.?.reader().read(fbs.buffer[fbs.pos..]);
            if (bytes_read == 0) {
                // End of stream
                break;
            }

            // Update the buffer position
            fbs.pos += bytes_read;

            try self.processSSE(fbs.getWritten(), arena_allocator, &msg, context, on_message);
        }
    }

    fn processSSE(
        self: *ClientV2,
        buffer: []const u8,
        allocator: Allocator,
        msg: *ChatMessage,
        context: anytype,
        on_message: ChatStreamCallback,
    ) !void {
        log.debug("Received chunk: {s}", .{buffer});

        var lines = std.mem.splitSequence(u8, buffer, "\n");

        var json_buffer = std.ArrayList(u8).init(self.allocator);
        defer json_buffer.deinit();

        while (lines.next()) |line| {
            if (line.len == 0) {
                // Skip empty line
                continue;
            }

            if (std.mem.startsWith(u8, line, "data: ")) {
                const data = line[6..];
                if (std.mem.eql(u8, data, "[DONE]")) {
                    log.debug("Stream completed with [DONE]", .{});
                    on_message(context, msg, true);
                    return;
                }

                const typesafe_data = try std.json.parseFromSliceLeaky(
                    ChatCompletionStreamResponse,
                    allocator,
                    data,
                    .{ .ignore_unknown_fields = true },
                );

                msg.id = typesafe_data.id;

                if (typesafe_data.choices.len > 0) {
                    const delta = typesafe_data.choices[0].delta;
                    msg.delta = delta.content;
                    if (delta.content) |content| {
                        var fragments = [_][]const u8{ msg.text, content };
                        msg.text = try std.mem.concat(allocator, u8, &fragments);
                    }
                    msg.role = delta.role;
                    msg.detail = typesafe_data;

                    on_message(context, msg, false);
                }
            }
        }
    }

    // ----- common -----

    const ChatCompletion = struct {
        allocator: Allocator,
        client: *std.http.Client,

        request: ?*std.http.Client.Request = null,

        fn init(allocator: Allocator, client: *std.http.Client) @This() {
            return .{
                .allocator = allocator,
                .client = client,
            };
        }

        fn send(self: *@This(), provider: Provider, api_key: []const u8, model: *RequestModel) !void {
            const full_api_path = try std.fmt.allocPrint(
                self.allocator,
                "{s}{s}",
                .{ provider.base_url, provider.api_path_chat_completions },
            );
            defer self.allocator.free(full_api_path);

            const uri = std.Uri.parse(full_api_path) catch unreachable;

            const bearer = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{api_key});
            defer self.allocator.free(bearer);

            var header_buf: [1024]u8 = undefined;

            var request = try self.client.open(.POST, uri, .{
                .server_header_buffer = &header_buf,
                .headers = .{
                    .authorization = .{ .override = bearer },
                    .content_type = .{ .override = "application/json" },
                },
            });

            const body = try std.json.stringifyAlloc(self.allocator, model, .{ .emit_null_optional_fields = false });
            defer self.allocator.free(body);

            log.debug("Request body: {s}", .{body});

            request.transfer_encoding = .{ .content_length = body.len };

            try request.send();

            try request.writeAll(body);

            try request.finish();

            try request.wait();

            self.request = &request;
        }

        fn deinit(self: *@This()) void {
            if (self.request) |req| {
                req.deinit();
            }
        }
    };
};

pub const ChatMessage = struct {
    id: ?[]const u8 = null,
    text: []const u8,
    role: ModelMessageRole,
    // name: ?[]const u8 = null,
    delta: ?[]const u8 = null,
    detail: ?ChatCompletionStreamResponse = null,
};

const ChatCompletionStreamResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []StreamChoice,
};

const StreamChoice = struct {
    delta: StreamChoiceDelta,
    index: u64,
    finish_reason: ?[]const u8 = null,
};

const StreamChoiceDelta = struct {
    role: ModelMessageRole = .assistant,
    content: ?[]const u8 = null,
};
