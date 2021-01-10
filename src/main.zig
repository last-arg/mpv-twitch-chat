const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const log = std.log.default;
const Mpv = @import("mpv.zig").Mpv;
const Comments = @import("comments.zig").Comments;
const CommentResult = @import("comments.zig").CommentResult;
const twitch = @import("twitch.zig");
const Thread = std.Thread;
const time = std.time;
const Timer = std.time.Timer;
const dd = @import("debug.zig").ttyWarn;

// NOTE: net.connectUnixSocket(path) doesn't support evented mode.
// pub const io_mode = .evented;

pub const log_level: std.log.Level = .info;

const g_host = "www.twitch.tv";
const g_port = 443;
const default_delay = 1.0; // seconds
const default_delay_ns = std.time.ns_per_s * default_delay;
const download_time = 3.0; // seconds. has to be natural number

const debug = true;

// Twitch API v5 chat emoticons
// https://dev.twitch.tv/docs/v5/reference/chat

const nc = @import("notcurses.zig");
const NotCurses = nc.NotCurses;
const Direct = nc.Direct;
const Plane = nc.Plane;
const Pile = nc.Pile;
const Style = nc.Style;

const UiNotCurses = struct {
    const Self = @This();
    nc: *NotCurses.T,
    text_plane: *Plane.T,
    ui: Ui,

    pub fn init() !Self {
        var nc_opts = NotCurses.default_options;
        const n = try NotCurses.init(nc_opts);
        return UiNotCurses{
            .nc = n,
            .text_plane = try createTextPlane(n),
            .ui = Ui{
                .deinitFn = deinit,
                .printFn = print,
                .printCommentFn = printComment,
                .sleepLoopFn = sleepLoop,
            },
        };
    }

    pub fn sleepLoop(ui: Ui, ns: u64) !void {
        const input_sleep_ns = time.ns_per_ms * 60;
        const self = @fieldParentPtr(Self, "ui", &ui);
        var col_curr: isize = 0;
        var row_curr: isize = 0;
        const timer = try Timer.start();
        const start_time = timer.read();

        while (true) {
            var char_code: u32 = 0;

            while (char_code != std.math.maxInt(u32)) {
                char_code = NotCurses.getcNblock(self.nc);
                // dd("code: {}\n", .{char_code});
                if (char_code == 'q') {
                    return;
                } else if (char_code == 'j') {
                    Plane.getYX(self.text_plane, &row_curr, &col_curr);
                    // TODO: don't scroll past panel top
                    try Plane.moveYX(self.text_plane, row_curr - 1, col_curr);
                } else if (char_code == 'k') {
                    Plane.getYX(self.text_plane, &row_curr, &col_curr);
                    // TODO: don't scroll past panel bottom
                    try Plane.moveYX(self.text_plane, row_curr + 1, col_curr);
                } else if (char_code == 'r') {
                    try NotCurses.render(self.nc);
                }
            }

            char_code = 0;
            try NotCurses.render(self.nc);
            if (timer.read() > ns) break;
            std.time.sleep(input_sleep_ns);
        }
    }

    fn createTextPlane(n: *NotCurses.T) !*Plane.T {
        const std_plane = try NotCurses.stdplane(n);
        var cols: usize = 0;
        var rows: usize = 0;
        Plane.dimYX(std_plane, &rows, &cols);

        return try Plane.create(std_plane, rows, cols);
    }

    pub fn printComment(ui: Ui, c: CommentResult) !void {
        const self = @fieldParentPtr(Self, "ui", &ui);
        var buf: [512]u8 = undefined; // NOTE: IRC max message length is 512 + extra

        Plane.setStyles(self.text_plane, Style.none);
        const time_str = try secondsToTimeString(&buf, c.time);
        try ui.print(time_str);

        Plane.stylesOn(self.text_plane, Style.bold);
        const name_str = try fmt.bufPrintZ(&buf, " {s}: ", .{c.name});
        try ui.print(name_str);
        Plane.stylesOff(self.text_plane, Style.bold);

        const body_str = try fmt.bufPrintZ(&buf, "{s}\n", .{c.body});
        try ui.print(body_str);
    }

    pub fn print(ui: Ui, str: [:0]const u8) !void {
        if (str.len == 0) return;
        const self = @fieldParentPtr(Self, "ui", &ui);
        var lines_added: usize = 0;

        var cols: usize = 0;
        var rows: usize = 0;
        Plane.dimYX(self.text_plane, &rows, &cols);
        var row_curr: usize = 0;
        var col_curr: usize = 0;
        Plane.cursorYX(self.text_plane, &row_curr, &col_curr);

        var result = Plane.putText(self.text_plane, str);

        var bytes: usize = result.bytes;
        while (result.result == -1) {
            rows += 1;
            try Plane.resizeSimple(self.text_plane, rows, cols);
            _ = Plane.cursorMoveYX(
                self.text_plane,
                @intCast(isize, row_curr),
                @intCast(isize, col_curr),
            );
            result = Plane.putText(self.text_plane, str[bytes..]);
            Plane.cursorYX(self.text_plane, &row_curr, &col_curr);
            bytes += result.bytes;
            lines_added += 1;
        }

        var row: isize = 0;
        var col: isize = 0;
        Plane.getYX(self.text_plane, &row, &col);
        try Plane.moveYX(self.text_plane, row - @intCast(isize, lines_added), col);

        try NotCurses.render(self.nc);
    }

    pub fn deinit(ui: Ui) void {
        const self = @fieldParentPtr(Self, "ui", &ui);
        NotCurses.stop(self.nc);
    }
};

const UiStdout = struct {
    const Self = @This();
    const stdout = std.io.getStdOut().outStream();
    const ESC_CHAR = [_]u8{27};
    const BOLD = ESC_CHAR ++ "[1m";
    const RESET = ESC_CHAR ++ "[0m";

    ui: Ui,

    pub fn init() !UiStdout {
        return UiStdout{
            .ui = Ui{
                .deinitFn = deinit,
                .printFn = print,
                .printCommentFn = printComment,
                .sleepLoopFn = sleepLoop,
            },
        };
    }

    pub fn sleepLoop(ui: Ui, ns: u64) !void {
        std.time.sleep(ns);
    }

    pub fn printComment(ui: Ui, c: CommentResult) !void {
        var time_buf: [16]u8 = undefined;
        const time_str = try secondsToTimeString(&time_buf, c.time);
        var buf: [2048]u8 = undefined; // NOTE: IRC max message length is 512 + extra
        const result = try fmt.bufPrintZ(
            buf[0..],
            "{s} " ++ BOLD ++ "{s}" ++ RESET ++ ": {s}\n",
            .{ time_str, c.name, c.body },
        );
        try ui.print(result);
    }

    pub fn print(ui: Ui, str: [:0]const u8) !void {
        try Self.stdout.writeAll(str);
    }

    pub fn deinit(ui: Ui) void {}
};

pub fn secondsToTimeString(buf: []u8, comment_seconds: f64) ![:0]u8 {
    const hours = @floatToInt(u32, comment_seconds / (60 * 60));
    const minutes = @floatToInt(
        u32,
        (comment_seconds - @intToFloat(f64, hours * 60 * 60)) / 60,
    );

    const seconds = @floatToInt(
        u32,
        (comment_seconds - @intToFloat(f64, hours * 60 * 60) - @intToFloat(f64, minutes * 60)),
    );

    const result = try fmt.bufPrintZ(
        buf,
        "[{d}:{d:0>2}:{d:0>2}]",
        .{ hours, minutes, seconds },
    );
    return result;
}

const UiDirect = struct {
    const Self = @This();
    const stdout = std.io.getStdOut().outStream();
    const ESC_CHAR = [_]u8{27};
    const BOLD = ESC_CHAR ++ "[1m";
    const RESET = ESC_CHAR ++ "[0m";

    direct: *Direct.T,
    ui: Ui,

    pub fn init() !Self {
        return Self{
            .direct = try Direct.init(),
            .ui = Ui{
                .deinitFn = deinit,
                .printFn = print,
                .printCommentFn = printComment,
                .sleepLoopFn = sleepLoop,
            },
        };
    }

    pub fn sleepLoop(ui: Ui, ns: u64) !void {
        std.time.sleep(ns);
    }

    pub fn printComment(ui: Ui, c: CommentResult) !void {
        const self = @fieldParentPtr(Self, "ui", &ui);

        var time_buf: [16]u8 = undefined;
        const time_str = try secondsToTimeString(&time_buf, c.time);
        try ui.print(time_str);
        var buf: [1024]u8 = undefined; // NOTE: IRC max message length is 512 + extra
        const result = try fmt.bufPrintZ(
            &buf,
            " {s}: ",
            .{c.name},
        );
        _ = Direct.stylesOn(self.direct, Style.bold);
        try ui.print(result);

        _ = Direct.stylesOff(self.direct, Style.bold);

        const body = try fmt.bufPrintZ(&buf, "{s}\n", .{c.body});
        try ui.print(body);
    }

    pub fn print(ui: Ui, str: [:0]const u8) !void {
        try std.io.cWriter(@ptrCast(*std.c.FILE, Direct.stdout)).print("{s}", .{str});
    }

    pub fn deinit(ui: Ui) void {
        const self = @fieldParentPtr(Self, "ui", &ui);
        Direct.stop(self.direct);
    }
};

const UiMode = enum {
    stdout,
    direct,
    notcurses,
};

const Ui = struct {
    const Self = @This();
    printFn: fn (ui: Self, str: [:0]const u8) anyerror!void,
    printCommentFn: fn (ui: Self, comment: CommentResult) anyerror!void,
    sleepLoopFn: fn (ui: Self, ms: u64) anyerror!void,
    deinitFn: fn (ui: Self) void,

    pub fn print(ui: Self, str: [:0]const u8) anyerror!void {
        return try ui.printFn(ui, str);
    }

    pub fn printComment(ui: Self, comment: CommentResult) anyerror!void {
        return try ui.printCommentFn(ui, comment);
    }

    pub fn sleepLoop(ui: Self, ms: u64) anyerror!void {
        return try ui.sleepLoopFn(ui, ms);
    }

    pub fn deinit(ui: Self) void {
        ui.deinitFn(ui);
    }
};

pub fn main() anyerror!void {
    // dd("\n==========================\n", .{});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    const stdout = std.io.getStdOut().outStream();

    var path_buf: [256]u8 = undefined;
    const path_fmt = "/v5/videos/{s}/comments?content_offset_seconds={d:.2}";

    // var mode_default = ;
    var output_mode: UiMode = .stdout;
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
        } else if (std.mem.eql(u8, "-help", arg) and std.mem.eql(u8, "-h", arg)) {
            // TODO: print help test
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

    output_mode = .direct;
    var ui = blk: {
        switch (output_mode) {
            .stdout => {
                var ui_mode = try UiStdout.init();
                break :blk &ui_mode.ui;
            },
            .direct => {
                var ui_mode = try UiDirect.init();
                break :blk &ui_mode.ui;
            },
            .notcurses => {
                var ui_mode = try UiNotCurses.init();
                break :blk &ui_mode.ui;
            },
        }
    };

    defer ui.deinit();

    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        chat_time = if (mpv.video_time < comments_delay) 0.0 else mpv.video_time - comments_delay;
        while (comments.getNextComment(chat_time)) |comment| {
            try ui.printComment(comment);
        }

        switch (download.state) {
            .Using => {
                if (((!comments.has_prev and mpv.video_time < first_offset) or
                    (!comments.has_next and mpv.video_time > last_offset)) and
                    mpv.video_time > (last_offset - download_time))
                {
                    log.info("Downloading new comments", .{});
                    comments_new.comments.items.len = 0;
                    comments_new.offsets.items.len = 0;
                    const offset = blk: {
                        if (mpv.video_time < first_offset or mpv.video_time > last_offset) {
                            break :blk chat_time;
                        }
                        break :blk last_offset - comments_delay;
                    };
                    download.path = try std.fmt.bufPrint(&path_buf, path_fmt, .{ video_id, last_offset });
                    th = try Thread.spawn(&download, Download.download);
                    continue;
                }
            },
            .Finished => {
                log.info("Finished downloading comments", .{});
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
                    log.info("Load new comments", .{});
                    var tmp = comments;
                    comments = comments_new;
                    comments_new = tmp;
                    comments.skipToNextIndex(chat_time);
                    first_offset = first_new;
                    last_offset = last_new;
                    download.state = .Using;
                } else if (last_offset <= chat_time or first_new >= chat_time) {
                    log.info("Comments out of range. Downloading new comments", .{});
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

        try ui.sleepLoop(delay_ns);
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
