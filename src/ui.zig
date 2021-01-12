const std = @import("std");
const os = std.os;
const time = std.time;
const Timer = std.time.Timer;
const fmt = std.fmt;
const CommentResult = @import("comments.zig").CommentResult;
const nc = @import("notcurses.zig");
const NotCurses = nc.NotCurses;
const Direct = nc.Direct;
const Plane = nc.Plane;
const Pile = nc.Pile;
const Style = nc.Style;

pub const UiMode = enum {
    stdout,
    direct,
    notcurses,
};

pub const Ui = struct {
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

pub const UiNotCurses = struct {
    const Self = @This();
    nc: *NotCurses.T,
    text_plane: *Plane.T,
    info_plane: *Plane.T,
    ui: Ui,

    pub fn init() !Self {
        var nc_opts = NotCurses.default_options;
        const n = try NotCurses.init(nc_opts);

        // Create planes
        const std_plane = try NotCurses.stdplane(n);
        var cols: usize = 0;
        var rows: usize = 0;
        Plane.dimYX(std_plane, &rows, &cols);
        const text_plane = try Plane.create(std_plane, rows, cols, .{});
        const info_plane = try Plane.create(
            std_plane,
            3,
            cols,
            .{ .x = @intCast(isize, rows) - 3 },
        );

        // Setup info_plane plane
        var result = Plane.putText(info_plane, "Scroll to bottom", .{ .t_align = nc.Align.left });

        return UiNotCurses{
            .nc = n,
            .text_plane = text_plane,
            .info_plane = info_plane,
            .ui = Ui{
                .deinitFn = deinit,
                .printFn = print,
                .printCommentFn = printComment,
                .sleepLoopFn = sleepLoop,
            },
        };
    }

    pub fn sleepLoop(ui: Ui, ns: u64) !void {
        const input_inactive_ns = time.ns_per_ms * 120;
        const input_active_ns = time.ns_per_ms * 60;
        const self = @fieldParentPtr(Self, "ui", &ui);
        var col_curr: isize = 0;
        var row_curr: isize = 0;
        const timer = try Timer.start();
        const start_time = timer.read();

        while (true) {
            var input_update_ns: u64 = input_inactive_ns;
            var char_code: u32 = 0;

            while (char_code != std.math.maxInt(u32)) {
                char_code = NotCurses.getcNblock(self.nc);
                // dd("code: {}\n", .{char_code});
                if (char_code == 'q') {
                    ui.deinit();
                    // TODO?: Might not clean up main loop
                    // Makes sure that cursor is visible and works
                    std.process.exit(0);
                } else if (char_code == 'j') {
                    input_update_ns = input_active_ns;
                    Plane.getYX(self.text_plane, &row_curr, &col_curr);
                    // TODO: don't scroll past panel top
                    try Plane.moveYX(self.text_plane, row_curr - 1, col_curr);
                } else if (char_code == 'k') {
                    input_update_ns = input_active_ns;
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
            std.time.sleep(input_update_ns);
        }
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

        // TODO: check if cursor is visible or not for scrolling

        var cols: usize = 0;
        var rows: usize = 0;
        // Plane.dimYX(self.text_plane, &rows, &cols);
        const std_plane = try NotCurses.stdplane(self.nc);
        Plane.dimYX(std_plane, &rows, &cols);

        var row_curr: usize = 0;
        var col_curr: usize = 0;
        Plane.cursorYX(self.text_plane, &row_curr, &col_curr);

        var result = Plane.putText(self.text_plane, str, .{ .t_align = nc.Align.left });

        var bytes: usize = result.bytes;
        while (result.result == -1) {
            // Use row_curr to calculate new plane height.
            // plane_current_height = row_curr + 1
            const new_height = row_curr + 12;
            try Plane.resizeSimple(self.text_plane, new_height, cols);
            _ = Plane.cursorMoveYX(
                self.text_plane,
                @intCast(isize, row_curr),
                @intCast(isize, col_curr),
            );
            result = Plane.putText(self.text_plane, str[bytes..], .{ .t_align = nc.Align.left });
            Plane.cursorYX(self.text_plane, &row_curr, &col_curr);
            bytes += result.bytes;
        }

        // TODO: Might only run when first putText fails
        var row: isize = 0;
        var col: isize = 0;
        Plane.getYX(self.text_plane, &row, &col);
        Plane.cursorYX(self.text_plane, &row_curr, &col_curr);
        // Assumes row is negative
        const last_row = @intCast(isize, rows) - 1 + (-row);
        if (row_curr > last_row) {
            const move_row = @intCast(isize, row_curr) - last_row;
            try Plane.moveYX(self.text_plane, row - move_row, col);
        }

        try NotCurses.render(self.nc);
    }

    pub fn deinit(ui: Ui) void {
        const self = @fieldParentPtr(Self, "ui", &ui);
        NotCurses.stop(self.nc);
    }
};

pub const UiStdout = struct {
    const Self = @This();
    const stdout = std.io.getStdOut().writer();
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

pub const UiDirect = struct {
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
        const result = try fmt.bufPrintZ(&buf, " {s}: ", .{c.name});
        _ = Direct.stylesOn(self.direct, Style.bold);
        try ui.print(result);
        _ = Direct.stylesOff(self.direct, Style.bold);

        const body = try fmt.bufPrintZ(&buf, "{s}\n", .{c.body});
        try ui.print(body);
    }

    pub fn print(ui: Ui, str: [:0]const u8) !void {
        try std.io.cWriter(@ptrCast(*std.c.FILE, Direct.stdout)).writeAll(str);
    }

    pub fn deinit(ui: Ui) void {
        const self = @fieldParentPtr(Self, "ui", &ui);
        Direct.stop(self.direct);
    }
};
