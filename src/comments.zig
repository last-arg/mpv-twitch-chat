const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const Parser = std.json.Parser;
const ArrayList = std.ArrayList;

pub const CommentResult = struct {
    name: []const u8,
    body: []u8,
    time: f64,
};

pub const Comments = struct {
    offsets: Offsets,
    comments: CommentArray,
    allocator: *Allocator,
    next_index: usize = 0,
    chat_offset_correction: f64 = 0.0,
    has_next: bool = false,
    has_prev: bool = false,

    const Self = @This();
    const Comment = struct {
        name: []const u8,
        body: []u8,
    };

    const Offsets = ArrayList(f64);
    const CommentArray = ArrayList(Comment);

    pub fn init(allocator: *Allocator, chat_offset_correction: f64) !Self {
        var self = Self{
            .offsets = try Offsets.initCapacity(allocator, 60),
            .comments = try CommentArray.initCapacity(allocator, 60),
            .chat_offset_correction = chat_offset_correction,
            .allocator = allocator,
        };
        return self;
    }

    pub fn parse(self: *Self, json_str: []const u8) !void {
        var p = Parser.init(self.allocator, false);
        defer p.deinit();

        var tree = try p.parse(json_str);
        defer tree.deinit();

        const root = tree.root;

        if (root.Object.getEntry("comments")) |comments| {
            const num = comments.value.Array.items.len;

            for (comments.value.Array.items) |comment| {
                const commenter = comment.Object.getEntry("commenter").?.value;
                const name = commenter.Object.getEntry("display_name").?.value.String;

                const message = comment.Object.getEntry("message").?.value;
                const message_body = message.Object.getEntry("body").?.value.String;

                // NOTE: can be a float or int
                const offset_seconds = blk: {
                    const offset_value = comment.Object.getEntry("content_offset_seconds").?.value;
                    switch (offset_value) {
                        .Integer => |integer| break :blk @intToFloat(f64, integer),
                        .Float => |float| break :blk float,
                        else => unreachable,
                    }
                };

                var new_comment = Comment{
                    .name = try mem.dupe(self.allocator, u8, name),
                    .body = try mem.dupe(self.allocator, u8, message_body),
                };
                try self.comments.append(new_comment);

                try self.offsets.append(offset_seconds);
            }
            self.has_next = root.Object.getEntry("_next") == null;
            self.has_prev = root.Object.getEntry("_prev") == null;
        } else {
            return error.NoCommentsJsonField;
        }
    }

    pub fn skipToNextIndex(self: *Self, time: f64) void {
        const first = self.offsets.items[0];
        const last = self.offsets.items[self.offsets.items.len - 1];

        if (time > last) {
            self.next_index = self.offsets.items.len;
        }

        if (time < first) {
            self.next_index = 0;
        }

        for (self.offsets.items) |offset, i| {
            if (offset > time) {
                self.next_index = i;
                break;
            }
        }
    }

    pub fn getNextComment(self: *Self, time: f64) ?CommentResult {
        if (self.next_index >= self.offsets.items.len) return null;
        if (self.offsets.items[self.next_index] > time) return null;
        const offset = self.offsets.items[self.next_index] + self.chat_offset_correction;
        const comment = self.comments.items[self.next_index];
        self.next_index += 1;
        return CommentResult{
            .name = comment.name,
            .body = comment.body,
            .time = offset,
        };
    }

    pub fn deinit(self: Self) void {
        for (self.comments.items) |comment| {
            self.allocator.free(comment.body);
        }
        self.offsets.deinit();
        self.comments.deinit();
    }
};

// TODO: fix test
test "Comments" {
    const json_str = @embedFile("../test/test-chat.json");
    var c = try Comments.init(std.testing.allocator, json_str, 0.0);
    defer c.deinit();

    // Parsing
    {
        std.testing.expect(c.comments.len == 59);
        std.testing.expect(c.comments.len == c.offsets.len);
        std.testing.expect(mem.eql(u8, c.comments[0].name, "chasapikos"));
        std.testing.expect(mem.eql(u8, c.comments[0].body, "BibleThump BibleThump BibleThump BibleThump BibleThump BibleThump BibleThump BibleThump"));
        std.testing.expect(c.offsets[0] == 12959.997);
    }

    // Generate comment
    {
        std.testing.expect((try c.generateComment(1.0)) == null);
        const str = try c.generateComment(12959.999);
        std.testing.expect(str.?.len > 0);
    }
}
