const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.middleware__llm);

pub const Provider = struct {
    base_url: []const u8,
    api_path_chat_completions: []const u8,
    model: []const u8,

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
};

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
        const full_api_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ provider.base_url, provider.api_path_chat_completions });
        defer self.allocator.free(full_api_path);

        const uri = std.Uri.parse(full_api_path) catch unreachable;

        var bearer: [1024]u8 = undefined;
        var request = try self.client.open(.POST, uri, .{ .server_header_buffer = self.header_buf, .headers = .{
            .authorization = .{ .override = std.fmt.bufPrint(&bearer, "Bearer {s}", .{self.api_key}) catch unreachable },
            .content_type = .{ .override = "application/json" },
        } });
        defer request.deinit();

        const model = try RequestModel.create(provider.model, question, self.allocator);
        defer self.allocator.free(model.messages);

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

const RequestModel = struct {
    model: []const u8,
    messages: []ModelMessage,
    stream: bool = false,

    fn create(model: []const u8, content: []const u8, allocator: Allocator) !RequestModel {
        var messages = try allocator.alloc(ModelMessage, 1);
        messages[0] = ModelMessage{
            .role = .user,
            .content = content,
        };

        return RequestModel{
            .model = model,
            .messages = messages,
        };
    }
};

pub const ModelMessage = struct {
    role: ModelMessageRole,
    content: []const u8,
};

pub const ResponseModel = struct {
    id: []const u8,
    object: []const u8,
    created: u32,
    model: []const u8,
    choices: []ModelChoice,
    usage: ModelUsage,
};

const ModelChoice = struct {
    index: u8,
    message: ModelMessage,
    finish_reason: []const u8,
};

const ModelUsage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,

    // prompt_tokens_details

    // these two fields are not returned by AliQwen
    // prompt_cache_hit_tokens: u32,
    // prompt_cache_miss_tokens: u32,
};

pub const ModelMessageRole = enum {
    user,
    assistant,
};
