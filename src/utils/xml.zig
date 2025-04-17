const std = @import("std");
const xml = @import("xml");
const Allocator = std.mem.Allocator;

const utils_text = @import("text.zig");

pub const XmlNode = struct {
    parent: ?*XmlNode,

    // topmost is 0
    level: u8,

    element_name: []const u8,
    element_value: ?[]const u8 = null,

    allocator: Allocator,

    pub fn init(allocator: Allocator, parent: ?*XmlNode, element_name: []const u8) !*XmlNode {
        const xml_node = try allocator.create(XmlNode);
        xml_node.* = XmlNode{
            .parent = parent,
            .level = if (parent) |it| it.level + 1 else 0,
            .element_name = try allocator.dupe(u8, element_name),

            .allocator = allocator,
        };
        return xml_node;
    }

    pub fn deinit(self: *XmlNode) void {
        self.allocator.free(self.element_name);
        if (self.element_value) |it| {
            self.allocator.free(it);
        }
        self.allocator.destroy(self);
    }
};

pub fn readFileAsNodes(allocator: Allocator, path: []const u8) !std.ArrayList(*XmlNode) {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try readAsNodes(allocator, file.reader());
}

pub fn readTextAsNodes(allocator: Allocator, text: []const u8) !std.ArrayList(*XmlNode) {
    var fbs = std.io.fixedBufferStream(text);
    return try readAsNodes(allocator, fbs.reader());
}

fn readAsNodes(allocator: Allocator, reader: anytype) !std.ArrayList(*XmlNode) {
    var doc = xml.streamingDocument(allocator, reader);
    defer doc.deinit();

    var doc_reader = doc.reader(allocator, .{});
    defer doc_reader.deinit();

    var nodes = std.ArrayList(*XmlNode).init(allocator);
    var current_node: ?*XmlNode = null;

    while (true) {
        const node = try doc_reader.read();
        switch (node) {
            .eof => break,
            .element_start => {
                current_node = try XmlNode.init(allocator, current_node, doc_reader.elementName());
                // std.debug.print("+ <{s} level={d}>\n", .{ current_node.?.elemement_name, current_node.?.level });
                try nodes.append(current_node.?);
            },
            .element_end => {
                // std.debug.print("- <{s}>\n", .{current_node.?.elemement_name});
                current_node = current_node.?.parent;
            },
            .text => {
                const text = try doc_reader.text();
                if (!utils_text.isEmptyStr(text)) {
                    // std.debug.print("  text of {s}: {s}\n", .{ current_node.?.elemement_name, text });
                    current_node.?.element_value = try allocator.dupe(u8, text);
                }
            },
            .cdata => {
                const cdata = try doc_reader.cdata();
                // std.debug.print("  cdata of {s}: {s}\n", .{ current_node.?.elemement_name, cdata });
                current_node.?.element_value = try allocator.dupe(u8, cdata);
            },
            else => std.debug.print(":( node type: {}\n", .{node}),
        }
    }

    return nodes;
}
