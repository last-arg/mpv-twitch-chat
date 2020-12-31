const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const Mpv = @import("mpv.zig").Mpv;
const Comments = @import("comments.zig").Comments;
const twitch = @import("twitch.zig");
const Thread = std.Thread;
const time = std.time;

// NOTE: net.connectUnixSocket(path) doesn't support evented mode.
// pub const io_mode = .evented;

const g_host = "www.twitch.tv";
const g_port = 443;
const default_delay = 1.0;
const default_delay_ns = std.time.ns_per_s * 1.0;

const debug = false;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    const stdout = std.io.getStdOut().outStream();

    var path_buf: [256]u8 = undefined;
    const path_fmt = "/v5/videos/{s}/comments?content_offset_seconds={d:.2}";

    var socket_path: []const u8 = "/tmp/mpv-twitch-socket";
    var comments_delay: f32 = 0.0;

    var arg_it = std.process.args();
    _ = arg_it.skip();
    while (arg_it.nextPosix()) |arg| {
        // TODO: add -delay option
        if (std.mem.eql(u8, "-comments-delay", arg)) {
            const value = arg_it.nextPosix() orelse {
                warn("Option '-comments-delay' requires value (integer or float)", .{});
                return;
            };
            // TODO?: remove negation?
            comments_delay = -(try fmt.parseFloat(f32, value));
        } else if (std.mem.eql(u8, "--socket-path", arg)) {
            socket_path = arg_it.nextPosix() orelse {
                warn("Option '-socket-path' requires path", .{});
                return;
            };
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

    // Debug
    if (debug) {
        allocator.free(mpv.video_path);
        mpv.video_path = try std.mem.dupe(allocator, u8, "https://www.twitch.tv/videos/855035286");
    }
    const video_id = try twitch.urlToVideoId(mpv.video_path);
    // const video_id = "855035286";

    var chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;

    var comments = blk: {
        warn("==> Download comments\n", .{});
        const path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, chat_time });
        const json_resp = try twitch.httpsRequest(allocator, g_host, g_port, path);
        defer allocator.free(json_resp);
        // const json_resp = @embedFile("../test/skadoodle-chat.json");
        break :blk try Comments.init(allocator, json_resp, comments_delay);
    };
    defer comments.deinit();

    var download = Download{
        .allocator = allocator,
        .data = "",
        .state = .Using,
        .hostname = g_host,
        .port = g_port,
        .path = "",
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
            download.path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, chat_time });
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

        const delay_ns: u64 = blk: {
            if (comments.next_index < comments.offsets.len) {
                const next_offset = comments.offsets[comments.next_index];
                const new_delay = next_offset - chat_time;
                if (new_delay < default_delay and new_delay > 0) {
                    break :blk @floatToInt(u64, (std.time.ns_per_s + 1) * new_delay);
                }
                break :blk default_delay_ns;
            }
            break :blk default_delay_ns;
        };
        std.time.sleep(delay_ns);
    }
}

const Download = struct {
    const Self = @This();
    allocator: *Allocator,
    hostname: [:0]const u8,
    port: u16,
    path: []const u8,
    state: enum {
        Using,
        Downloading,
        Finished,
    },
    data: []const u8,

    pub fn download(self: *Self) !void {
        self.state = .Downloading;
        self.data = try twitch.httpsRequest(
            self.allocator,
            self.hostname,
            self.port,
            self.path,
        );
        self.state = .Finished;
    }

    pub fn freeData(self: Self) void {
        self.allocator.free(self.data);
    }
};
