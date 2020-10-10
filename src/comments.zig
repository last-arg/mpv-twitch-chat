const std = @import("std");
const warn = std.debug.warn;
const mem = std.mem;
const fmt = std.fmt;
const Allocator = std.mem.Allocator;
const Parser = std.json.Parser;
const ArrayList = std.ArrayList;

const ESC_CHAR = [_]u8{27};
const BOLD = ESC_CHAR ++ "[1m";
const RESET = ESC_CHAR ++ "[0m";

pub const Comments = struct {
    offsets: []const f64,
    comments: []const Comment,
    allocator: *Allocator,
    next_index: usize = 0,
    chat_offset_correction: f64 = 0.0,
    // TODO?: Make these bools into enum instead?
    is_last: bool = false,
    is_first: bool = false,

    const Self = @This();
    const Comment = struct {
        name: []const u8,
        body: []u8,
    };

    pub fn init(allocator: *Allocator, json_str: []const u8, chat_offset_correction: f64) !Self {
        var self = Self{
            .offsets = undefined,
            .comments = undefined,
            .chat_offset_correction = chat_offset_correction,
            .allocator = allocator,
        };
        try self.parse(json_str);
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

            var offsets_array = try ArrayList(f64).initCapacity(self.allocator, num);
            errdefer offsets_array.deinit();

            var comments_array = try ArrayList(Comment).initCapacity(self.allocator, num);
            errdefer comments_array.deinit();

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
                    .name = name,
                    // .body = message_body[0..],
                    // TODO?: might be memory leak. might require separate freeing ???
                    .body = try mem.dupe(self.allocator, u8, message_body),
                    // .body = undefined,
                };
                // mem.copy(u8, new_comment.body, message_body[0..]);
                try comments_array.append(new_comment);

                try offsets_array.append(offset_seconds);
            }
            self.offsets = offsets_array.toOwnedSlice();
            self.comments = comments_array.toOwnedSlice();
            self.is_last = root.Object.getEntry("_next") == null;
            self.is_first = root.Object.getEntry("_prev") == null;
        } else {
            return error.NoCommentsJsonField;
        }
    }

    pub fn skipToNextIndex(self: *Self, time: f64) void {
        warn("==> Skip new comments\n", .{});
        const first = self.offsets[0];
        const last = self.offsets[self.offsets.len - 1];

        if (time > last) {
            self.next_index = self.offsets.len;
        }

        if (time < first) {
            self.next_index = 0;
        }

        for (self.offsets) |offset, i| {
            if (offset > time) {
                self.next_index = i;
                break;
            }
        }
    }

    pub fn nextCommentString(self: *Self, time: f64) !?[]u8 {
        if (self.next_index >= self.offsets.len) return null;
        if (self.offsets[self.next_index] > time) return null;

        const offset = self.offsets[self.next_index] + self.chat_offset_correction;
        const comment = self.comments[self.next_index];

        const hours = @floatToInt(u32, offset / (60 * 60));
        const minutes = @floatToInt(
            u32,
            (offset - @intToFloat(f64, hours * 60 * 60)) / 60,
        );

        const seconds = @floatToInt(
            u32,
            (offset - @intToFloat(f64, hours * 60 * 60) - @intToFloat(f64, minutes * 60)),
        );

        var buf: [2048]u8 = undefined; // NOTE: IRC max message length is 512 + extra
        const result = try fmt.bufPrint(buf[0..], "[{d}:{d:0>2}:{d:0>2}] " ++ BOLD ++ "{}" ++ RESET ++ ": {}\n", .{ hours, minutes, seconds, comment.name, comment.body });
        self.next_index += 1;
        return result;
    }

    pub fn deinit(self: Self) void {
        for (self.comments) |comment| {
            self.allocator.free(comment.body);
        }
        self.allocator.free(self.offsets);
        self.allocator.free(self.comments);
    }
};

test "Comments" {
    const json_str = @embedFile("../test/test-chat.json");
    var c = try Comments.init(std.testing.allocator, json_str);
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
