const std = @import("std");
const os = std.os;
const time = std.time;
const Timer = std.time.Timer;
const fmt = std.fmt;
const l = std.log.default;
const CommentResult = @import("comments.zig").CommentResult;
const nc = @import("notcurses.zig");
const NotCurses = nc.NotCurses;
const Direct = nc.Direct;
const Plane = nc.Plane;
const Pile = nc.Pile;
const Style = nc.Style;
const Align = nc.Align;
const Cell = nc.Cell;
const Key = nc.Key;

pub const UiMode = enum {
    stdout,
    direct,
    notcurses,
};

pub const Ui = struct {
    const Self = @This();
    printFn: fn (ui: Self, str: [:0]const u8) anyerror!void,
    printCommentFn: fn (ui: Self, comment: CommentResult) anyerror!void,
    sleepLoopFn: fn (ui: *Self, ms: u64) anyerror!void,
    deinitFn: fn (ui: Self) void,

    pub fn print(ui: Self, str: [:0]const u8) anyerror!void {
        return try ui.printFn(ui, str);
    }

    pub fn printComment(ui: Self, comment: CommentResult) anyerror!void {
        return try ui.printCommentFn(ui, comment);
    }

    pub fn sleepLoop(ui: *Self, ms: u64) anyerror!void {
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
    scrolling: bool = false,
    mouse_btn1_down: bool = false,

    pub fn init() !Self {
        var nc_opts = NotCurses.default_options;
        const n = try NotCurses.init(nc_opts);

        // Create planes
        const std_plane = try NotCurses.stdplane(n);
        var cols: usize = 0;
        var rows: usize = 0;
        Plane.dimYX(std_plane, &rows, &cols);
        // Text plane setup
        const text_plane = try Plane.create(std_plane, rows, cols, .{});
        var text_cell = Cell.charInitializer(' ');
        Plane.setBaseCell(text_plane, text_cell);

        // Info/Scroll plane setup
        const info_plane = try Plane.create(
            std_plane,
            1,
            cols,
            .{ .x = @intCast(isize, rows) - 1 },
        );
        Plane.moveBottom(info_plane);
        var info_cell = Cell.charInitializer(' ');
        Cell.setBbRgb(&info_cell, 0xf2e5bc);
        Plane.setBaseCell(info_plane, info_cell);
        var result = Plane.putText(info_plane, "Scroll to bottom", .{ .t_align = Align.center });

        try NotCurses.mouseEnable(n);
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

    pub fn sleepLoop(ui: *Ui, ns: u64) !void {
        errdefer ui.deinit();
        var self = @fieldParentPtr(Self, "ui", ui);
        const input_inactive_ns = time.ns_per_ms * 120;
        const input_active_ns = time.ns_per_ms * 60;
        var col_curr: isize = 0;
        var row_curr: isize = 0;
        const timer = try Timer.start();
        const start_time = timer.read();
        var input: nc.NotCurses.Input = undefined;

        while (true) {
            var input_update_ns: u64 = input_inactive_ns;
            var char_code: u32 = NotCurses.getcNblock(self.nc, &input);
            var scrolled = false;
            var row_change: isize = 0;

            while (char_code != std.math.maxInt(u32)) {
                // if (char_code != std.math.maxInt(u32)) {
                //     std.log.info("{} {}", .{ char_code, input });
                // }
                if (char_code == 'q') {
                    ui.deinit();
                    // TODO?: Might not clean up main loop
                    // Makes sure that cursor is visible and works
                    std.process.exit(0);
                } else if (char_code == Key.scroll_up) {
                    row_change += 1;
                    scrolled = true;
                } else if (char_code == Key.scroll_down) {
                    row_change -= 1;
                    scrolled = true;
                } else if (char_code == 'j') {
                    row_change -= 1;
                    scrolled = true;
                } else if (char_code == 'k') {
                    row_change += 1;
                    scrolled = true;
                } else if (char_code == Key.pgup) {
                    const std_plane = try NotCurses.stdplane(self.nc);
                    var cols: usize = 0;
                    var rows: usize = 0;
                    Plane.dimYX(std_plane, &rows, &cols);
                    row_change += @intCast(isize, rows) - 1;
                    scrolled = true;
                } else if (char_code == Key.pgdown) {
                    const std_plane = try NotCurses.stdplane(self.nc);
                    var cols: usize = 0;
                    var rows: usize = 0;
                    Plane.dimYX(std_plane, &rows, &cols);
                    row_change -= @intCast(isize, rows) - 1;
                    scrolled = true;
                } else if (char_code == Key.home) {
                    var cursor_row: usize = 0;
                    var cursor_col: usize = 0;
                    Plane.cursorYX(self.text_plane, &cursor_row, &cursor_col);
                    row_change += @intCast(isize, cursor_row);
                    scrolled = true;
                } else if (char_code == Key.end) {
                    var cursor_row: usize = 0;
                    var cursor_col: usize = 0;
                    Plane.cursorYX(self.text_plane, &cursor_row, &cursor_col);
                    row_change -= @intCast(isize, cursor_row);
                    scrolled = true;
                } else if (char_code == 'r') {
                    try NotCurses.render(self.nc);
                } else if (self.scrolling) {
                    if (char_code == Key.button1) {
                        input_update_ns = input_active_ns;
                        self.mouse_btn1_down = true;
                    } else if (char_code == Key.release) {
                        // scroll to bottom of input
                        self.mouse_btn1_down = false;
                        const std_plane = try NotCurses.stdplane(self.nc);
                        var cols: usize = 0;
                        var rows: usize = 0;
                        Plane.dimYX(std_plane, &rows, &cols);

                        if ((rows - 1) == input.y) {
                            Plane.moveBottom(self.info_plane);
                            var cursor_row: usize = 0;
                            var cursor_col: usize = 0;
                            Plane.cursorYX(self.text_plane, &cursor_row, &cursor_col);
                            const row = -(@intCast(isize, cursor_row) - (@intCast(isize, rows) - 1));
                            try Plane.moveYX(self.text_plane, row, 0);
                            self.scrolling = false;
                        }
                    }
                }
                char_code = NotCurses.getcNblock(self.nc, &input);
            }

            if (scrolled) {
                input_update_ns = input_active_ns;
                const std_plane = try NotCurses.stdplane(self.nc);
                var cols: usize = 0;
                var rows: usize = 0;
                Plane.dimYX(std_plane, &rows, &cols);

                var cursor_row: usize = 0;
                var cursor_col: usize = 0;
                Plane.cursorYX(self.text_plane, &cursor_row, &cursor_col);

                // Make sure there is anything to scroll
                if (cursor_row >= rows) {
                    Plane.getYX(self.text_plane, &row_curr, &col_curr);

                    // Don't cross text_plane edges
                    if (row_change != 0) {
                        const new_curr = blk: {
                            const wanted_curr = row_curr + row_change;

                            if (wanted_curr > 0) {
                                break :blk 0;
                            }

                            const bottom_edge = -(@intCast(isize, cursor_row) - @intCast(isize, rows) + 1);

                            if (bottom_edge > wanted_curr) {
                                break :blk bottom_edge;
                            }

                            break :blk wanted_curr;
                        };

                        try Plane.moveYX(self.text_plane, new_curr, col_curr);
                        row_curr = new_curr;
                    }

                    var last_row = @intCast(isize, rows) - 1 + (-row_curr);

                    if (cursor_row > last_row) {
                        self.scrolling = true;
                        Plane.moveTop(self.info_plane);
                    } else {
                        self.scrolling = false;
                        Plane.moveBottom(self.info_plane);
                    }
                }
                scrolled = false;
            }

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

        const body_str = try fmt.bufPrintZ(&buf, "{s}", .{c.body});
        try ui.print(body_str);
        // NOTE: separate print for newline  because body string might have invalid bytes
        try ui.print(try fmt.bufPrintZ(&buf, "\n", .{}));
    }

    pub fn print(ui: Ui, str: [:0]const u8) !void {
        if (str.len == 0) return;
        const self = @fieldParentPtr(Self, "ui", &ui);

        var cols: usize = 0;
        var rows: usize = 0;
        const std_plane = try NotCurses.stdplane(self.nc);
        Plane.dimYX(std_plane, &rows, &cols);

        var row_curr: usize = 0;
        var col_curr: usize = 0;
        Plane.cursorYX(self.text_plane, &row_curr, &col_curr);

        var result = Plane.putText(self.text_plane, str, .{ .t_align = Align.left });

        var bytes: usize = result.bytes;
        while (result.result == -1) {
            // NOTE: In case str contains invalid bytes putText print and moves cursor
            // until invalid byte. Although result.bytes reports back 0 bytes written.
            // Just don't bother trying to write rest of bytes.
            if (result.bytes == 0) {
                const col_old = col_curr;
                const row_old = row_curr;
                Plane.cursorYX(self.text_plane, &row_curr, &col_curr);
                if ((col_curr > col_old and row_curr == row_old) or
                    row_curr > row_old) break;
            }

            // Use row_curr to calculate new plane height.
            const new_height = row_curr + 12;
            try Plane.resizeSimple(self.text_plane, new_height, cols);
            _ = Plane.cursorMoveYX(
                self.text_plane,
                @intCast(isize, row_curr),
                @intCast(isize, col_curr),
            );

            result = Plane.putText(self.text_plane, str[bytes..], .{ .t_align = Align.left });
            Plane.cursorYX(self.text_plane, &row_curr, &col_curr);
            bytes += result.bytes;
        }

        if (!self.scrolling) {
            var row: isize = 0;
            var col: isize = 0;
            Plane.getYX(self.text_plane, &row, &col);
            Plane.cursorYX(self.text_plane, &row_curr, &col_curr);
            // Assumes row is negative
            const last_row = @intCast(isize, rows) - 1 + (-row);
            // Only runs when first putText fails
            if (row_curr > last_row) {
                const move_row = @intCast(isize, row_curr) - last_row;
                try Plane.moveYX(self.text_plane, row - move_row, col);
            }
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

    pub fn sleepLoop(ui: *Ui, ns: u64) !void {
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

    pub fn sleepLoop(ui: *Ui, ns: u64) !void {
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
