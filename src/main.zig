const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const fmt = std.fmt;
const Mpv = @import("mpv.zig").Mpv;
const Comments = @import("comments.zig").Comments;
const t = @import("twitch.zig");
const Twitch = t.Twitch;
const SSL = @import("ssl.zig").SSL;
const Thread = std.Thread;
const time = std.time;

// NOTE: net.connectUnixSocket(path) doesn't support evented mode.
// pub const io_mode = .evented;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    const stdout = std.io.getStdOut().outStream();

    var arg_it = std.process.args();
    _ = arg_it.skip();
    const chat_offset = blk: {
        if (arg_it.nextPosix()) |value| {
            break :blk try fmt.parseFloat(f64, value);
        }
        warn("No CLI arguments.\n", .{});
        break :blk 0.0;
    };

    warn("==> Connect to MPV socket\n", .{});
    var mpv = try Mpv.init(allocator, "/tmp/mpv-twitch-socket");
    defer mpv.deinit();

    const video_id = try t.urlToVideoId(mpv.video_path);
    // const video_id = "762169747";

    const ssl = try SSL.init(allocator);
    defer ssl.deinit();
    var twitch = Twitch.init(allocator, video_id, ssl);
    var chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;

    var comments = blk: {
        warn("==> Download comments\n", .{});
        const json_str = try twitch.downloadComments(chat_time);
        defer allocator.free(json_str);
        // const json_str = @embedFile("../test/skadoodle-chat.json");
        break :blk try Comments.init(allocator, json_str, chat_offset);
    };
    defer comments.deinit();

    var download = Download{
        .twitch = twitch,
        .chat_time = chat_time,
        .data = "",
        .state = .Using,
    };

    var th: *Thread = undefined;
    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;
        while (try comments.nextCommentString(chat_time)) |str| {
            try stdout.writeAll(str);
        }

        // TODO: move outside of loop
        // TODO: update when new comments downloaded
        const first_offset = comments.offsets[0];
        const last_offset = comments.offsets[comments.offsets.len - 1];
        if (download.state == .Using and
            ((!comments.has_prev and mpv.video_time < first_offset) or
            (!comments.has_next and mpv.video_time > last_offset)))
        {
            warn("==> Download new comments\n", .{});
            download.chat_time = chat_time;
            th = try Thread.spawn(&download, Download.download);
            continue;
        } else if (download.state == .Finished) {
            warn("==> Downloaded new comments\n", .{});
            comments.deinit();
            try comments.parse(download.data);
            chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;
            comments.skipToNextIndex(chat_time);
            download.freeData();
            download.state = .Using;
            // th.wait();
        }

        std.time.sleep(std.time.ns_per_s * 0.5);
    }
}

const Download = struct {
    const Self = @This();
    twitch: Twitch,
    chat_time: f64,
    state: enum {
        Using,
        Downloading,
        Finished,
    },
    data: []const u8,

    pub fn download(self: *Self) !void {
        self.state = .Downloading;
        self.data = try self.twitch.downloadComments(self.chat_time);
        self.state = .Finished;
    }

    pub fn freeData(self: Self) void {
        self.twitch.allocator.free(self.data);
    }
};
