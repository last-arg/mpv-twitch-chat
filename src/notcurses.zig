const std = @import("std");
const warn = std.debug.warn;
const log = std.log.default;

const nc = @cImport({
    @cDefine("_XOPEN_SOURCE", {}); // To enable fn wcwidth
    @cInclude("notcurses/notcurses.h");
    @cInclude("notcurses/direct.h");
    @cInclude("notcurses/nckeys.h");
    @cInclude("notcurses/version.h");
});

// pub const log_level: std.log.Level = .info;

// Notcurses plane transparent background example
// https://github.com/dankamongmen/notcurses/blob/0aa060b9f12402e73e3d956360b3bcce34a1971e/tests/reel.cpp#L287

// For outputting to stdout have to use imported c function printf (c.zig) or
// cWriter (io/c_writer.zig).
//
// Seems like can display images but can't set image size

pub const Align = enum {
    unaligned = nc.NCALIGN_UNALIGNED,
    left = nc.NCALIGN_LEFT,
    center = nc.NCALIGN_CENTER,
    right = nc.NCALIGN_RIGHT,
};

pub const Key = struct {
    pub const button1 = nc.NCKEY_BUTTON1;
    pub const release = nc.NCKEY_RELEASE;
    pub const scroll_up = nc.NCKEY_SCROLL_UP;
    pub const scroll_down = nc.NCKEY_SCROLL_DOWN;
    pub const pgdown = nc.NCKEY_PGDOWN;
    pub const pgup = nc.NCKEY_PGUP;
    pub const home = nc.NCKEY_HOME;
    pub const end = nc.NCKEY_END;
};

pub const Style = struct {
    pub const none = nc.NCSTYLE_NONE;
    pub const mask = nc.NCSTYLE_MASK;
    pub const standout = nc.NCSTYLE_STANDOUT;
    pub const underline = nc.NCSTYLE_UNDERLINE;
    pub const reverse = nc.NCSTYLE_REVERSE;
    pub const blink = nc.NCSTYLE_BLINK;
    pub const dim = nc.NCSTYLE_DIM;
    pub const bold = nc.NCSTYLE_BOLD;
    pub const invis = nc.NCSTYLE_INVIS;
    pub const protect = nc.NCSTYLE_PROTECT;
    pub const italic = nc.NCSTYLE_ITALIC;
    pub const struck = nc.NCSTYLE_STRUCK;
};

pub const Tablet = struct {
    const T = nc.struct_nctablet;

    // TODO?: Depending on nctablet_plane return might be better to return null
    // instead of error
    pub fn plane(t: *T) !*Plane.T {
        const result = nc.nctablet_plane(t) orelse {
            log.warn("Failed to get tablet's plane", .{});
            return error.TabletPlaneFailed;
        };
        return result;
    }
};
pub const Reel = struct {
    const T = nc.struct_ncreel;
    const Options = nc.ncreel_options;

    pub fn create(p: *Plane.T, opts: Options) !*T {
        var reel = nc.ncreel_create(p, &opts) orelse {
            log.warn("Failed to create 'Reel'", .{});
            return error.ReelCreateFailed;
        };
        return reel;
    }

    pub fn destroy(r: *T) void {
        nc.ncreel_destroy(r);
    }

    // TODO: figure out 'opaque_' type
    // TODO?: put optional params into struct?
    pub fn add(
        r: *T,
        next_tab: ?*Tablet.T,
        prev_tab: ?*Tablet.T,
        cb: nc.tabletcb,
        opaque_: ?*c_void,
    ) !*Tablet.T {
        var tablet = nc.ncreel_add(
            r,
            next_tab,
            prev_tab,
            cb orelse tabletCb,
            opaque_,
        ) orelse {
            log.warn("Failed to create new tablet for reel", .{});
            return error.ReelAddFailed;
        };
        return tablet;
    }

    fn tabletCb(tab: ?*nc.nctablet, render_from_top: bool) callconv(.C) c_int {
        var plane_current = Tablet.plane(tab.?) catch |err| {
            log.err("Table callback failed\n", .{});
            return 0;
        };
        var rows: usize = 0;
        var cols: usize = 0;
        Plane.dimYX(plane_current, &rows, &cols);
        return 20;
    }

    pub fn next(r: *T) ?*Tablet.T {
        return nc.ncreel_next(r);
    }

    pub fn prev(r: *T) ?*Tablet.T {
        return nc.ncreel_prev(r);
    }

    // Return true if input is relevant
    pub fn offerInput(r: *T, input: *nc.ncinput) bool {
        return nc.ncreel_offer_input(r, input);
    }

    pub fn plane(r: *T) *Plane.T {
        return nc.ncreel_plane(r).?;
    }

    pub fn redraw(r: *T) void {
        if (nc.ncreel_redraw(r) < 0) {
            log.warn("Failed redraw reel\n", .{});
        }
    }
};

pub const Pile = struct {
    pub fn create(n: *NotCurses.T, plane_opts: Plane.Options) !*Plane.T {
        var result = nc.ncpile_create(n, &plane_opts) orelse {
            log.warn("Failed to create new plane", .{});
            return error.PileCreateFailed;
        };
        return result;
    }

    pub fn render(p: *Plane.T) !void {
        if (nc.ncpile_render(p) < 0) {
            log.warn("Pile.render failed", .{});
            return error.PileRenderFailed;
        }
    }

    pub fn rasterize(p: *Plane.T) !void {
        if (nc.ncpile_rasterize(p) < 0) {
            log.warn("Pile.rasterize failed", .{});
            return error.PileRasterizeFailed;
        }
    }
};

fn defaultResizeCb(p: ?*Plane.T) callconv(.C) c_int {
    var rows: usize = 0;
    var cols: usize = 0;
    Plane.dimYX(p.?, &rows, &cols);
    return 0;
}

pub const Plane = struct {
    pub const T = nc.struct_ncplane;
    pub const Options = nc.ncplane_options;

    pub const CreateOptions = struct {
        x: isize = 0,
        y: isize = 0,
        flags: usize = 0,
    };

    // TODO: implement rest of CreateOptions args
    pub fn create(plane: *T, rows: usize, cols: usize, opts: CreateOptions) !*T {
        const plane2_opts = nc.ncplane_options{
            .y = @intCast(c_int, opts.x),
            .x = @intCast(c_int, opts.y),
            .rows = @intCast(c_int, rows),
            .cols = @intCast(c_int, cols),
            .userptr = null,
            .name = "", // For debugging
            // .resizecb = fn_cb_param orelse planeResize,
            .resizecb = defaultResizeCb,
            .flags = opts.flags,
        };

        var result = nc.ncplane_create(plane, &plane2_opts) orelse {
            log.warn("Failed to create new plane", .{});
            return error.PlaneCreateFailed;
        };
        return result;
    }

    pub fn erase(p: *T) void {
        nc.ncplane_erase(p);
    }

    pub fn moveBottom(p: *T) void {
        nc.ncplane_move_bottom(p);
    }

    pub fn moveTop(p: *T) void {
        nc.ncplane_move_top(p);
    }

    pub fn dimYX(p: *T, rows: *usize, cols: *usize) void {
        var rows_result: c_int = 0;
        var cols_result: c_int = 0;
        nc.ncplane_dim_yx(p, &rows_result, &cols_result);
        cols.* = @intCast(usize, cols_result);
        rows.* = @intCast(usize, rows_result);
    }

    // TODO?: can fail?
    pub fn setBaseCell(p: *T, c: Cell.T) void {
        _ = nc.ncplane_set_base_cell(p, &c);
    }

    pub fn setScrolling(p: *T, scrollp: bool) void {
        const prev_state = nc.ncplane_set_scrolling(p, scrollp);
    }

    pub fn putChar(p: *T, char: u8) isize {
        return @intCast(isize, nc.ncplane_putchar(p, char));
    }

    const TextReturn = struct {
        bytes: usize,
        result: isize,
    };

    const TextOptions = struct {
        t_align: Align = .left,
    };

    pub fn putText(
        p: *T,
        str: [:0]const u8,
        opts: TextOptions,
    ) TextReturn {
        var bytes: usize = 0;
        const alignment = @intToEnum(nc.ncalign_e, @enumToInt(opts.t_align));
        const result = nc.ncplane_puttext(p, -1, alignment, str, &bytes);
        return .{ .bytes = bytes, .result = @intCast(isize, result) };
    }

    pub fn putStr(p: *T, str: [:0]const u8) isize {
        return nc.ncplane_putstr(p, @ptrCast([*]const u8, str));
    }

    pub fn resizeSimple(p: *T, rows: usize, cols: usize) !void {
        if (nc.ncplane_resize_simple(p, @intCast(c_int, rows), @intCast(c_int, cols)) < 0) {
            return error.PlaneResizeSimpleFailed;
        }
    }

    pub fn moveYX(p: *T, rows: isize, cols: isize) !void {
        if (nc.ncplane_move_yx(p, @intCast(c_int, rows), @intCast(c_int, cols)) < 0) {
            return error.PlaneMoveYXFailed;
        }
    }

    pub fn getYX(p: *T, row: *isize, col: *isize) void {
        var r: c_int = 0;
        var c: c_int = 0;
        nc.ncplane_yx(p, &r, &c);
        row.* = @intCast(isize, r);
        col.* = @intCast(isize, c);
    }

    pub fn cursorYX(p: *T, row: *usize, col: *usize) void {
        var r: c_int = 0;
        var c: c_int = 0;
        nc.ncplane_cursor_yx(p, &r, &c);
        row.* = @intCast(usize, r);
        col.* = @intCast(usize, c);
    }

    pub fn cursorMoveYX(p: *T, row: isize, col: isize) isize {
        return nc.ncplane_cursor_move_yx(p, @intCast(c_int, row), @intCast(c_int, col));
    }

    pub fn setStyles(p: *T, styles: usize) void {
        nc.ncplane_set_styles(p, @intCast(c_uint, styles));
    }

    pub fn stylesOn(p: *T, styles: usize) void {
        nc.ncplane_styles_on(p, @intCast(c_uint, styles));
    }

    pub fn stylesOff(p: *T, styles: usize) void {
        nc.ncplane_styles_off(p, @intCast(c_uint, styles));
    }

    pub fn vprintfYX(p: *T, row: isize, col: isize, format: [:0]const u8) isize {
        var va_list = nc.struct___va_list_tag{
            .gp_offset = 0,
            .fp_offset = 0,
            .overflow_arg_area = null,
            .reg_save_area = null,
        };
        const result = nc.ncplane_vprintf_yx(
            p,
            @intCast(c_int, row),
            @intCast(c_int, col),
            @ptrCast([*]const u8, format),
            &va_list,
        );
        return @intCast(isize, result);
    }
};

pub const NotCurses = struct {
    pub const T = nc.struct_notcurses;
    const Struct = nc.struct_notcurses;
    const Options = nc.notcurses_options;
    const Align = nc.ncalign_e;
    const Blitter = nc.ncblitter_e;
    const Scale = nc.ncscale_e;
    const Cell = nc.nccell;
    pub const Input = nc.ncinput;

    pub const default_options = Options{
        .termtype = null,
        .renderfp = null, // mostly for debugging
        // .loglevel = nc.ncloglevel_e.NCLOGLEVEL_TRACE,
        // .loglevel = nc.ncloglevel_e.NCLOGLEVEL_DEBUG,
        .loglevel = nc.ncloglevel_e.NCLOGLEVEL_SILENT,
        .margin_t = 0,
        .margin_r = 0,
        .margin_b = 0,
        .margin_l = 0,
        .flags = 0,
    };

    // TODO: flush stdin before start of init or/and end of init
    pub fn init(opts: ?Options) !*Struct {
        var options = opts orelse default_options;
        // options.flags |= nc.NCOPTION_NO_ALTERNATE_SCREEN;
        // options.flags |= nc.NCOPTION_SUPPRESS_BANNERS;
        // options.flags |= nc.NCPLOT_OPTION_LABELTICKSD | nc.NCPLOT_OPTION_PRINTSAMPLE;
        const n = nc.notcurses_init(&options, nc.stdout) orelse {
            log.warn("Failed to initialize notcurses", .{});
            return error.NotCursesInitFailed;
        };
        return n;
    }

    // TODO: can error
    pub fn cursorDisable(n: *T) void {
        _ = nc.notcurses_cursor_disable(n);
    }

    // TODO: can error
    pub fn cursorEnable(n: *T) void {
        _ = nc.notcurses_cursor_enable(n, -1, -1);
    }

    pub fn canUtf8(n: *T) bool {
        return nc.notcurses_canutf8(n);
    }

    pub fn render(n: *T) !void {
        if (nc.notcurses_render(n) < 0) {
            log.warn("Notcurses.render failed", .{});
            return error.NotCursesRenderFailed;
        }
    }

    pub fn mouseEnable(n: *T) !void {
        if (nc.notcurses_mouse_enable(n) < 0) {
            return error.CantEnableMouseEvents;
        }
    }

    pub fn planeCursorYX(plane: *Plane.T, rows: *usize, cols: *usize) void {
        var rows_result: c_int = 0;
        var cols_result: c_int = 0;
        nc.ncplane_cursor_yx(plane, &rows_result, &cols_result);
        cols.* = @intCast(usize, cols_result);
        rows.* = @intCast(usize, rows_result);
    }

    pub fn getcBlocking(n: *Struct, input: *Input) usize {
        const result = nc.notcurses_getc_blocking(n, input);
        return @intCast(usize, result);
    }

    pub fn planeRgba(plane: *Plane.T) void {
        const result = nc.ncplane_rgba(plane, Blitter.NCBLIT_DEFAULT, 0, 0, 20, 20);
    }

    pub fn cellInit(cell: *Cell) void {
        nc.cell_init(cell);
    }

    pub fn planeBase(plane: *Plane.T, cell: *Cell) void {
        _ = nc.ncplane_base(plane, cell);
    }

    pub fn planePolyfillYX(plane: *Plane.T, cell: Cell) void {
        const result = nc.ncplane_polyfill_yx(plane, 0, 0, &cell);
        if (result < 0) {
            log.warn("ncplane_putstr failed", .{});
        }
    }

    // pub extern fn ncplane_polyfill_yx(n: ?*struct_ncplane, y: c_int, x: c_int, c: [*c]const nccell) c_int;

    pub fn getc(n: *Struct) u32 {
        return nc.notcurses_getc(n, 0, null, null);
    }

    pub fn planePutstrYX(plane: *Plane.T, str: [:0]const u8) void {
        const result = nc.ncplane_putstr(plane, str);
        if (result < 0) {
            log.warn("ncplane_putstr failed", .{});
        }
    }

    pub fn getcNblock(n: *Struct, input: *Input) u32 {
        const result = nc.notcurses_getc_nblock(n, input);
        return result;
    }

    pub fn stdplane(nc_struct: *Struct) !*Plane.T {
        var plane = nc.notcurses_stdplane(nc_struct) orelse {
            return error.CreatingNotCursesPlaneFailed;
        };
        return plane;
    }

    pub fn stop(nc_struct: *Struct) void {
        const result = nc.notcurses_stop(nc_struct);
        if (result < 0) {
            log.warn("notcurses_stop failed", .{});
        }
    }

    pub fn version() void {
        const v = nc.notcurses_version();

        dd("NotCurses version: ", .{});
        var c: ?u8 = 1;
        var i: usize = 0;
        while (c != @as(u8, 0x00)) : (i += 1) {
            c = v[i];
            dd("{c}", .{c});
        }
        dd("\n", .{});
    }
};

pub const Direct = struct {
    pub const Self = @This();
    // TODO?: make cursor functions into one function with enum parameter?
    pub const T = nc.struct_ncdirect;
    const Struct = nc.struct_ncdirect;
    const Align = nc.ncalign_e;
    const Blitter = nc.ncblitter_e;
    const Scale = nc.ncscale_e;
    pub var stdout: *nc.FILE = undefined;

    pub fn init() !*T {
        Self.stdout = nc.stdout;

        var n = nc.ncdirect_init(null, nc.stdout, nc.NCOPTION_INHIBIT_SETLOCALE) orelse {
            log.warn("Failed to initialize notcurses direct", .{});
            return error.NcDirectInitFailed;
        };

        // var r = std.c.printf("test\n");
        // try std.io.cWriter(@ptrCast(*std.c.FILE, nc.stdout)).print("test this more {}\n", .{34});
        return n;
    }

    // TODO: make last three arguements into struct with default values
    pub fn renderImage(n: *Struct, filename: [:0]const u8, img_align: Align, img_blitter: Blitter, img_scale: Scale) void {
        const r = nc.ncdirect_render_image(n, filename, img_align, img_blitter, img_scale);
        if (r < 0) {
            log.warn("ncdirect_render_image failed", .{});
        }
    }

    pub fn stop(nc_direct: *Struct) void {
        const result = nc.ncdirect_stop(nc_direct);
        if (result < 0) {
            log.warn("ncdirect_stop failed", .{});
        }
    }

    pub fn stylesOn(d: *T, styles: usize) isize {
        return nc.ncdirect_styles_on(d, @intCast(c_uint, styles));
    }

    pub fn stylesOff(d: *T, styles: usize) isize {
        return nc.ncdirect_styles_off(d, @intCast(c_uint, styles));
    }

    pub fn cursorUp(n: *Struct, nr: usize) void {
        if (nc.ncdirect_cursor_up(n, @intCast(c_int, nr)) != 0) {
            log.warn("ncdirect_cursor_up failed", .{});
        }
    }

    pub fn cursorRight(n: *Struct, nr: usize) void {
        if (nc.ncdirect_cursor_right(n, @intCast(c_int, nr)) != 0) {
            log.warn("ncdirect_cursor_right failed", .{});
        }
    }

    pub fn cursorLeft(n: *Struct, nr: usize) void {
        if (nc.ncdirect_cursor_left(n, @intCast(c_int, nr)) != 0) {
            log.warn("ncdirect_cursor_left failed", .{});
        }
    }

    pub fn cursorPop(n: *Struct) void {
        if (nc.ncdirect_cursor_pop(n) != 0) {
            log.warn("ncdirect_cursor_pop failed", .{});
        }
    }

    pub fn cursorPush(n: *Struct) void {
        if (nc.ncdirect_cursor_push(n) != 0) {
            log.warn("ncdirect_cursor_push failed", .{});
        }
    }
    pub fn flush(n: *Struct) void {
        if (nc.ncdirect_flush(n) != 0) {
            log.warn("ncdirect_flush failed", .{});
        }
    }
};

pub const Cell = struct {
    pub const T = nc.nccell;

    pub fn charInitializer(c: u8) T {
        return T{
            .gcluster = std.mem.nativeToLittle(u32, c),
            .gcluster_backstop = 0,
            .width = @intCast(u8, nc.wcwidth(c)),
            .stylemask = 0,
            .channels = 0,
        };
    }

    pub fn setBbRgb(c: *T, channel: u32) void {
        _ = nc.cell_set_bg_rgb(c, channel);
    }

    pub fn setFbRgb(c: *T, channel: u32) void {
        _ = nc.cell_set_fg_rgb(c, channel);
    }
};
