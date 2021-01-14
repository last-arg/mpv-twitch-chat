const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const l = std.log.default;
const Mpv = @import("mpv.zig").Mpv;
const Comments = @import("comments.zig").Comments;
const CommentResult = @import("comments.zig").CommentResult;
const twitch = @import("twitch.zig");
const ui = @import("ui.zig");
const Thread = std.Thread;
const dd = @import("debug.zig").ttyWarn;

// NOTE: net.connectUnixSocket(path) doesn't support evented mode.
// pub const io_mode = .evented;

pub const log_level: std.log.Level = .info;

var first_log = false;
var log_file_path: ?[]const u8 = null;
pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = "[" ++ @tagName(level) ++ "] ";
    if (log_file_path) |file_path| {
        var log_file: std.fs.File = undefined;
        defer log_file.close();
        if (!first_log) {
            log_file = std.fs.cwd().createFile(file_path, .{ .truncate = true }) catch return;
            first_log = true;
        } else {
            log_file = std.fs.cwd().openFile(file_path, .{ .write = true }) catch |err| {
                warn("{}\n", .{err});
                return;
            };
        }
        if (!log_file.isTty()) {
            log_file.seekFromEnd(0) catch return;
        }
        nosuspend log_file.writer().print(prefix ++ format ++ "\n", args) catch return;
    } else {
        const stderr = std.io.getStdErr().writer();
        const held = std.debug.getStderrMutex().acquire();
        defer held.release();
        nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
    }
}

const g_host = "www.twitch.tv";
const g_port = 443;
const default_delay = 1.0; // seconds
const default_delay_ns = std.time.ns_per_s * default_delay;
const download_time = 3.0; // seconds. has to be natural number

const debug = true;

// Twitch API v5 chat emoticons
// https://dev.twitch.tv/docs/v5/reference/chat

pub fn main() anyerror!void {
    // dd("\n==========================\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    const stdout = std.io.getStdOut().outStream();

    var path_buf: [256]u8 = undefined;
    const path_fmt = "/v5/videos/{s}/comments?content_offset_seconds={d:.2}";

    var output_mode: ui.UiMode = .stdout;
    // output_mode = .notcurses;
    var opt_log_file: []const u8 = "stdout";
    var socket_path: []const u8 = "/tmp/mpv-twitch-socket";
    var comments_delay: f32 = 0.0;

    var arg_it = std.process.args();
    _ = arg_it.skip();
    while (arg_it.nextPosix()) |arg| {
        if (std.mem.eql(u8, "-comments-delay", arg)) {
            const value = arg_it.nextPosix() orelse {
                warn("Option '-comments-delay' requires value (integer or float)", .{});
                return;
            };
            // TODO?: remove negation?
            comments_delay = -(try fmt.parseFloat(f32, value));
        } else if (std.mem.eql(u8, "-socket-path", arg)) {
            socket_path = arg_it.nextPosix() orelse {
                warn("Option '-socket-path' requires path", .{});
                return;
            };
        } else if (std.mem.eql(u8, "-output-mode", arg)) {
            var arg_value = arg_it.nextPosix() orelse {
                warn("Option '-output-mode' requires one these value: stdout, direct, notcurses", .{});
                return;
            };
            if (std.mem.eql(u8, "stdout", arg_value)) {
                output_mode = .stdout;
            } else if (std.mem.eql(u8, "direct", arg_value)) {
                output_mode = .direct;
            } else if (std.mem.eql(u8, "notcurses", arg_value)) {
                output_mode = .notcurses;
            } else {
                warn("Option '-output-mode' contains invalid value '{s}'\nValid '-output-mode' values: {s}, {s}, {s}", .{
                    arg_value,
                    "stdout",
                    "direct",
                    "notcurses",
                });
                return;
            }
        } else if (std.mem.eql(u8, "-log-file", arg)) {
            // TODO: should different output modes have different log file defaults?
            const value = arg_it.nextPosix() orelse {
                warn("Option '-log-file' requires path or `stdout` ", .{});
                return;
            };
            if (std.mem.eql(u8, "stdout", value)) {
                log_file_path = null;
            } else {
                log_file_path = value;
            }
        } else if (std.mem.eql(u8, "-help", arg) or std.mem.eql(u8, "-h", arg)) {
            const help_text =
                \\mpv-vod-chat [options]
                \\
                \\Options:
                \\  -h, -help        Print help text
                \\  -socket-path     Default: '/tmp/mpv-twitch-socket'. Set mpv players socket path
                \\  -comments-delay  When comments are displayed compared to video time
                \\  -output-mode     Default: stdout. Can enter one three: stdout, direct, notcurses.
                \\  -log-file        Default: stdout. Can output application log messages to stdout, a file or tty.
                \\
            ;

            warn("{}", .{help_text});
            return;
        }
    }

    var mpv = Mpv.init(allocator, socket_path) catch |err| {
        warn("Failed to find mpv socket path: {s}\n", .{socket_path});
        return err;
    };
    defer mpv.deinit();
    // const start_time = mpv.video_time;

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
        std.log.info("Download and load first comments", .{});
        const path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, chat_time });
        const json_resp = try twitch.httpsRequest(allocator, g_host, g_port, path);
        defer allocator.free(json_resp);
        // const json_resp = @embedFile("../test/skadoodle-chat.json");
        try comments.parse(json_resp);
    }

    var first_offset = comments.offsets.items[0];
    var last_offset = comments.offsets.items[comments.offsets.items.len - 1];

    var comments_new: Comments = try Comments.init(allocator, comments_delay);

    var mutex = std.Mutex{};
    var th: *Thread = undefined;
    var download = Download{
        .allocator = allocator,
        .data = "",
        .state = .Using,
        .hostname = g_host,
        .port = g_port,
        .path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, last_offset }),
        .lock = &mutex,
    };

    // TODO?: Implement video state detection: playing or paused
    // try mpv.requestProperty("playback-time");
    // try mpv.readResponses();

    // if (mpv.video_time > start_time) {
    // }

    var ui_mode = blk: {
        switch (output_mode) {
            .stdout => {
                var ui_mode = try ui.UiStdout.init();
                break :blk &ui_mode.ui;
            },
            .direct => {
                var ui_mode = try ui.UiDirect.init();
                break :blk &ui_mode.ui;
            },
            .notcurses => {
                var ui_mode = try ui.UiNotCurses.init();
                break :blk &ui_mode.ui;
            },
        }
    };
    defer ui_mode.deinit();

    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;
        while (comments.getNextComment(chat_time)) |comment| {
            try ui_mode.printComment(comment);
        }

        switch (download.state) {
            .Using => {
                if (((!comments.has_prev and mpv.video_time < first_offset) or
                    (!comments.has_next and mpv.video_time > last_offset)) and
                    mpv.video_time > (last_offset - download_time))
                {
                    std.log.info("Downloading new comments", .{});
                    comments_new.comments.items.len = 0;
                    comments_new.offsets.items.len = 0;
                    const offset = blk: {
                        // if (mpv.video_time < first_offset or mpv.video_time > last_offset) {
                        //     break :blk chat_time;
                        // }
                        break :blk last_offset - comments_delay;
                    };
                    download.path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, last_offset });
                    th = try Thread.spawn(&download, Download.download);
                    continue;
                }
            },
            .Finished => {
                std.log.info("Finished downloading comments", .{});
                th.wait();
                try comments_new.parse(download.data);
                download.freeData();
                download.state = .Ready;
                const first_new = comments_new.offsets.items[0];
                const last_new = comments_new.offsets.items[comments_new.offsets.items.len - 1];
                continue;
            },
            .Ready => {
                const first_new = comments_new.offsets.items[0];
                const last_new = comments_new.offsets.items[comments_new.offsets.items.len - 1];
                if (chat_time > first_new and chat_time < last_new) {
                    std.log.info("Load new comments", .{});
                    var tmp = comments;
                    comments = comments_new;
                    comments_new = tmp;
                    comments.skipToNextIndex(chat_time);
                    first_offset = first_new;
                    last_offset = last_new;
                    download.state = .Using;
                } else if (last_offset <= chat_time or first_new >= chat_time) {
                    std.log.info("Comments out of range. Downloading new comments", .{});
                    comments_new.comments.items.len = 0;
                    comments_new.offsets.items.len = 0;
                    download.path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, chat_time });
                    th = try Thread.spawn(&download, Download.download);
                }
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

        try ui_mode.sleepLoop(delay_ns);
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
    lock: *std.Mutex,

    pub fn download(dl: *Self) !void {
        const held = dl.lock.acquire();
        defer held.release();

        dl.state = .Downloading;
        dl.data = try twitch.httpsRequest(
            dl.allocator,
            dl.hostname,
            dl.port,
            dl.path,
        );
        dl.state = .Finished;
    }

    pub fn freeData(dl: Self) void {
        dl.allocator.free(dl.data);
    }
};
