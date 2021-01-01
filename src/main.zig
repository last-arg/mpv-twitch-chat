const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const log = std.log.default;
const Mpv = @import("mpv.zig").Mpv;
const Comments = @import("comments.zig").Comments;
const twitch = @import("twitch.zig");
const Thread = std.Thread;
const time = std.time;
const nc = @cImport({
    @cInclude("notcurses/notcurses.h");
    @cInclude("notcurses/direct.h");
    @cInclude("notcurses/nckeys.h");
    @cInclude("notcurses/version.h");
});

// NOTE: net.connectUnixSocket(path) doesn't support evented mode.
// pub const io_mode = .evented;

pub const log_level: std.log.Level = .info;

const g_host = "www.twitch.tv";
const g_port = 443;
const default_delay = 1.0; // seconds
const default_delay_ns = std.time.ns_per_s * 1.0;
const download_time = 3.0; // seconds. has to be natural number

const debug = true;

pub fn main() anyerror!void {
    // warn("MAIN\n", .{});
    // // const nc_struct = nc.notcurses_init(null, null);
    // const v = nc.notcurses_version();
    // warn("notcurses version: {}\n", .{v});
    // var c: ?u8 = 1;
    // var i: usize = 0;
    // while (c != @as(u8, 0x00)) : (i += 1) {
    //     c = v[i];
    //     warn("{c}", .{c});
    // }

    // if (true) return;
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
        mpv.video_path = try std.mem.dupe(allocator, u8, "https://www.twitch.tv/videos/855788435");
    }
    const video_id = try twitch.urlToVideoId(mpv.video_path);
    // const video_id = "855035286";

    var chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;

    var comments = try Comments.init(allocator, comments_delay);
    defer comments.deinit();

    {
        log.info("Download and load first comments", .{});
        const path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, chat_time });
        const json_resp = try twitch.httpsRequest(allocator, g_host, g_port, path);
        defer allocator.free(json_resp);
        // const json_resp = @embedFile("../test/skadoodle-chat.json");
        try comments.parse(json_resp);
    }

    var first_offset = comments.offsets.items[0];
    var last_offset = comments.offsets.items[comments.offsets.items.len - 1];

    // TODO: download next comments right now
    var comments_new: Comments = try Comments.init(allocator, comments_delay);

    var th: *Thread = undefined;
    var download = Download{
        .allocator = allocator,
        .data = "",
        .state = .Downloading,
        .hostname = g_host,
        .port = g_port,
        .path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, last_offset }),
    };
    th = try Thread.spawn(&download, Download.download);

    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;
        while (try comments.nextCommentString(chat_time)) |str| {
            try stdout.writeAll(str);
        }

        switch (download.state) {
            .Using => {
                if (((!comments.has_prev and mpv.video_time < first_offset) or
                    (!comments.has_next and mpv.video_time > last_offset)) and
                    mpv.video_time > (last_offset - download_time))
                {
                    log.info("Start downloading comments", .{});
                    comments_new.comments.items.len = 0;
                    comments_new.offsets.items.len = 0;
                    download.path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, last_offset });
                    th = try Thread.spawn(&download, Download.download);
                    continue;
                }
            },
            .Finished => {
                log.info("Finished downloading comments", .{});
                try comments_new.parse(download.data);
                download.freeData();
                download.state = .Ready;
                continue;
            },
            .Ready => {
                // TODO: if ready is fired to many times download new comments
                // Or keep track of mpv seek event firing
                chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;
                const first = comments_new.offsets.items[0];
                const last = comments_new.offsets.items[comments_new.offsets.items.len - 1];
                if (chat_time > first and chat_time < last) {
                    log.info("Load new comments", .{});
                    var tmp = comments;
                    comments = comments_new;
                    comments_new = tmp;
                    comments.skipToNextIndex(chat_time);
                    first_offset = first;
                    last_offset = last;
                    download.state = .Using;
                }
                // th.wait();
            },
            .Downloading => {},
        }

        const delay_ns: u64 = blk: {
            if (comments.next_index < comments.offsets.items.len) {
                const next_offset = comments.offsets.items[comments.next_index];
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
        Ready,
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
