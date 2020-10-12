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

    // const video_id = try t.urlToVideoId(mpv.video_path);
    const video_id = "762169747";

    const ssl = try SSL.init(allocator);
    defer ssl.deinit();
    var twitch = Twitch.init(allocator, video_id, ssl);

    warn("==> Download comments\n", .{});
    var chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;

    const json_str = try twitch.downloadComments(chat_time);
    // const json_str = @embedFile("../test/skadoodle-chat.json");

    var comments = try Comments.init(allocator, json_str, chat_offset);
    defer comments.deinit();

    var download = Download{
        .twitch = twitch,
        .chat_time = chat_time,
        .body = json_str,
        .state = .Using,
    };
    download.freeBody();
    errdefer download.freeBody();

    var th: *Thread = undefined;
    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;
        while (try comments.nextCommentString(chat_time)) |str| {
            try stdout.writeAll(str);
        }

        const first_offset = comments.offsets[0] - chat_offset;
        const last_offset = comments.offsets[comments.offsets.len - 1] - chat_offset;
        if (download.state == .Using and
            ((!comments.has_prev and mpv.video_time < first_offset) or
            (!comments.has_next and mpv.video_time > last_offset)))
        {
            warn("==> Start download new comments\n", .{});
            download.chat_time = chat_time;
            th = try Thread.spawn(&download, Download.download);
            continue;
        } else if (download.state == .Finished) {
            warn("==> Finished downloading new comments\n", .{});
            comments.deinit();
            try comments.parse(download.body);
            chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;
            comments.skipToNextIndex(chat_time);
            download.freeBody();
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
    body: []const u8,

    pub fn download(self: *Self) !void {
        self.state = .Downloading;
        self.body = try self.twitch.downloadComments(self.chat_time);
        self.state = .Finished;
    }

    pub fn freeBody(self: Self) void {
        self.twitch.allocator.free(self.body);
    }
};
