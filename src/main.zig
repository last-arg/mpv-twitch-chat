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

const default_delay = std.time.ns_per_s * 1.0;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    const stdout = std.io.getStdOut().outStream();

    var socket_path: []const u8 = "/tmp/mpv-twitch-socket";
    var comments_delay: f32 = 0.0;

    var arg_it = std.process.args();
    _ = arg_it.skip();
    while (arg_it.nextPosix()) |arg| {
        if (std.mem.eql(u8, "-comments-delay", arg)) {
            const value = arg_it.nextPosix() orelse {
                warn("No value (integer or float) enter for option -comments-delay\n", .{});
                break;
            };
            // TODO?: remove negation?
            comments_delay = -(try fmt.parseFloat(f32, value));
        } else if (std.mem.eql(u8, "--socket-path", arg)) {
            const value = arg_it.nextPosix() orelse {
                warn("No value (integer or float) enter for option -socket-path\n", .{});
                break;
            };
            socket_path = value;
        } else if (std.mem.eql(u8, "-help", arg) and std.mem.eql(u8, "-h", arg)) {
            // TODO: print help test
            return;
        }
    }

    var mpv = Mpv.init(allocator, socket_path) catch |err| {
        warn("Failed to find mpv socket path: {}\n", .{socket_path});
        return err;
    };
    defer mpv.deinit();

    const video_id = try t.urlToVideoId(mpv.video_path);
    // const video_id = "762169747";

    const ssl = try SSL.init(allocator);
    defer ssl.deinit();
    var twitch = Twitch.init(allocator, video_id, ssl);
    var chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;

    var comments = blk: {
        warn("==> Download comments\n", .{});
        const json_str = try twitch.downloadComments(chat_time);
        defer allocator.free(json_str);
        // const json_str = @embedFile("../test/skadoodle-chat.json");
        break :blk try Comments.init(allocator, json_str, comments_delay);
    };
    defer comments.deinit();

    var download = Download{
        .twitch = twitch,
        .chat_time = chat_time,
        .data = "",
        .state = .Using,
    };

    var th: *Thread = undefined;
    var first_offset = comments.offsets[0];
    var last_offset = comments.offsets[comments.offsets.len - 1];
    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;
        while (try comments.nextCommentString(chat_time)) |str| {
            try stdout.writeAll(str);
        }

        // TODO: start downloading comments before last comment
        if (download.state == .Using and
            ((!comments.has_prev and mpv.video_time < first_offset) or
            (!comments.has_next and mpv.video_time > last_offset)))
        {
            warn("==> Start downloading comments\n", .{});
            download.chat_time = chat_time;
            th = try Thread.spawn(&download, Download.download);
            continue;
        } else if (download.state == .Finished) {
            warn("==> Finished downloading comments\n", .{});
            comments.deinit();
            try comments.parse(download.data);
            chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;
            comments.skipToNextIndex(chat_time);
            first_offset = comments.offsets[0];
            last_offset = comments.offsets[comments.offsets.len - 1];
            download.freeData();
            download.state = .Using;
            // th.wait();
        }

        const delay: u64 = blk: {
            if (comments.next_index < comments.offsets.len) {
                const next_offset = comments.offsets[comments.next_index];
                const new_delay = next_offset - chat_time;
                if (new_delay < default_delay and new_delay > 0) {
                    break :blk @floatToInt(u64, (std.time.ns_per_s + 1) * new_delay);
                }
            }
            break :blk default_delay;
        };
        std.time.sleep(delay);
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
