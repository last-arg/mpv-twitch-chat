const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const net = std.net;
const Address = std.net.Address;
const StringArrayHashMap = std.StringArrayHashMap;
const os = std.os;
const fmt = std.fmt;
const json = std.json;
const Parser = std.json.Parser;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const c = @import("c.zig");

// TODO: non-blocking mode messes up openssl functions.
// https://stackoverflow.com/a/31174268
// SSL_pending()
// https://groups.google.com/forum/#!msg/mailing.openssl.users/nJRF_JVnPkc/377tgaE4sRgJ
// pub const io_mode = .evented;

// TODO: chat log correction
var g_chat_time_correction: f64 = 0.0;

const Context = struct {
    buf: []const u8,
    count: usize = 0,
    index: usize = 0,
};

const Comments = struct {
    offsets: []const f64,
    comments: []const Comment,
    allocator: *Allocator,
    next_index: usize = 0,
    // TODO?: Make these bools into enum instead?
    is_last: bool = false,
    is_first: bool = false,

    const Self = @This();
    const Comment = struct {
        name: []const u8,
        body: []u8,
    };

    pub fn initTwitchJson(allocator: *Allocator, json_str: []const u8) !Self {
        var p = Parser.init(allocator, false);
        defer p.deinit();

        var tree = try p.parse(json_str);
        defer tree.deinit();

        const root = tree.root;

        if (root.Object.getEntry("comments")) |comments| {
            const num = comments.value.Array.items.len;

            var offsets_array = try ArrayList(f64).initCapacity(allocator, num);
            errdefer offsets_array.deinit();

            var comments_array = try ArrayList(Comment).initCapacity(allocator, num);
            errdefer comments_array.deinit();

            for (comments.value.Array.items) |comment| {
                const commenter = comment.Object.getEntry("commenter").?.value;
                const name = commenter.Object.getEntry("display_name").?.value.String;

                const message = comment.Object.getEntry("message").?.value;
                const message_body = message.Object.getEntry("body").?.value.String;

                // NOTE: can be a float or int
                const offset_seconds = blk: {
                    const offset_value = comment.Object.getEntry("content_offset_seconds").?.value;
                    switch (offset_value) {
                        .Integer => |integer| break :blk @intToFloat(f64, integer),
                        .Float => |float| break :blk float,
                        else => unreachable,
                    }
                };

                var new_comment = Comment{
                    .name = name,
                    // .body = message_body[0..],
                    // TODO?: might be memory leak. might require separate freeing ???
                    .body = try mem.dupe(allocator, u8, message_body),
                    // .body = undefined,
                };
                // mem.copy(u8, new_comment.body, message_body[0..]);
                try comments_array.append(new_comment);

                try offsets_array.append(offset_seconds);
            }

            return Self{
                .offsets = offsets_array.toOwnedSlice(),
                .comments = comments_array.toOwnedSlice(),
                .allocator = allocator,
                .is_last = root.Object.getEntry("_next") == null,
                .is_first = root.Object.getEntry("_prev") == null,
            };
        }

        return error.InvalidJson;
    }

    pub fn printComments(self: Self, start_index: usize, end_index: usize) !void {
        var i = start_index;
        while (i < end_index) : (i += 1) {
            const offset = self.offsets[i] + g_chat_time_correction;
            const comment = self.comments[i];

            const hours = @floatToInt(u32, offset / (60 * 60));
            const minutes = @floatToInt(
                u32,
                (offset - @intToFloat(f64, hours * 60 * 60)) / 60,
            );

            const seconds = @floatToInt(
                u32,
                (offset - @intToFloat(f64, hours * 60 * 60) - @intToFloat(f64, minutes * 60)),
            );

            const stdout = std.io.getStdOut().outStream();

            const esc_char = [_]u8{27};
            const BOLD = esc_char ++ "[1m";
            const RESET = esc_char ++ "[0m";
            var buf: [2048]u8 = undefined; // NOTE: IRC max message length is 512 + extra
            const b = try fmt.bufPrint(buf[0..], "[{d}:{d:0<2}:{d:0<2}] " ++ BOLD ++ "{}" ++ RESET ++ ":\n{}\n", .{ hours, minutes, seconds, comment.name, comment.body });
            try stdout.writeAll(b);
        }
    }

    pub fn deinit(self: Self) void {
        for (self.comments) |comment| {
            self.allocator.free(comment.body);
        }
        self.allocator.free(self.offsets);
        self.allocator.free(self.comments);
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;
    // TODO?: Not sure if need it.
    // Some twitch vods start at ~01:07

    var arg_it = std.process.args();
    _ = arg_it.skip();
    var arg = arg_it.nextPosix();
    if (arg) |value| {
        g_chat_time_correction = fmt.parseFloat(f64, value) catch {
            warn("Failed to parse float value.\n", .{});
            return;
        };
    }

    warn("==> Connect to MPV socket\n", .{});
    var mpv = try Mpv.init(allocator, "/tmp/mpv-twitch-socket");
    defer mpv.deinit();

    // Get twitch video ID.
    // const url = "https://www.twitch.tv/videos/762169747?t=2h47m8s";
    const url = mpv.video_path;
    const start_index = (mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl) + 1; // NOTE: need the pos after '/'.
    const end_index = mem.lastIndexOfScalar(u8, url, '?') orelse url.len;

    const twitch = try Twitch.init(allocator, url[start_index..end_index]);
    // defer twitch.deinit();
    // warn("{}\n", .{twitch});

    warn("==> {}\n", .{mpv.video_time});
    warn("==> Download comments\n", .{});
    var corrected_time = blk: {
        const time = mpv.video_time - g_chat_time_correction;
        if (time < 0) break :blk 0.0;
        break :blk time;
    };
    const comments_json = try twitch.requestCommentsJson(corrected_time);
    defer twitch.allocator.free(comments_json);
    // const comments_json = @embedFile("../test/skadoodle-chat.json");
    var comments = try Comments.initTwitchJson(allocator, comments_json);
    defer comments.deinit();

    while (true) {
        try mpv.requestProperty(.PlaybackTime);
        try mpv.readResponses();

        // warn("pos: {d}\n", .{mpv.video_time});
        corrected_time = blk: {
            const time = mpv.video_time - g_chat_time_correction;
            if (time < 0) break :blk 0.0;
            break :blk time;
        };

        const new_index = blk: {
            for (comments.offsets[comments.next_index..]) |offset, i| {
                // warn("{d} > {d}\n", .{ mpv.video_time, offset });
                if (corrected_time > offset) {
                    continue;
                }
                break :blk i + comments.next_index;
            }

            break :blk comments.offsets.len;
        };

        if (new_index != comments.next_index) {
            try comments.printComments(comments.next_index, new_index);
            comments.next_index = new_index;
        }

        const first_offset = comments.offsets[0];
        const last_offset = comments.offsets[comments.offsets.len - 1];
        if ((!comments.is_first and corrected_time < first_offset) or
            (!comments.is_last and corrected_time > last_offset))
        {
            warn("==> Download new comments\n", .{});
            const old_end = comments.offsets[comments.offsets.len - 1];

            comments.deinit();
            const new_json = try twitch.requestCommentsJson(corrected_time);
            comments = try Comments.initTwitchJson(allocator, new_json);

            const new_start = comments.offsets[0];
            const new_end = comments.offsets[comments.offsets.len - 1];

            if (new_start > old_end and old_end < new_end) {
                for (comments.offsets) |offset, i| {
                    if (new_end < offset) {
                        continue;
                    }
                    comments.next_index = i;
                    break;
                }
            } else {
                for (comments.offsets) |offset, i| {
                    if (corrected_time > offset) {
                        continue;
                    }
                    comments.next_index = i;
                    break;
                }
            }

            continue;
        }

        std.time.sleep(std.time.ns_per_s * 0.5);
    }
}

const Twitch = struct {
    const Self = @This();
    const domain = "www.twitch.tv";
    const port = 443;

    allocator: *Allocator,
    video_id: []const u8,

    pub fn init(allocator: *Allocator, video_id: []const u8) !Self {
        return Self{
            .allocator = allocator,
            .video_id = video_id,
        };
    }

    pub fn requestCommentsJson(self: Self, video_offset: f64) ![]const u8 {
        assert(video_offset >= 0.0);
        const location = try std.fmt.allocPrint(self.allocator, "/v5/videos/{}/comments?content_offset_seconds={d:.2}", .{ self.video_id, video_offset });
        defer self.allocator.free(location);
        const request_line = try std.fmt.allocPrint(self.allocator, "GET {} HTTP/1.1", .{location});
        defer self.allocator.free(request_line);

        // TODO: change accept to twitch+json
        const header_entries =
            \\Accept: */*
            \\Connection: close
            \\Host: api.twitch.tv
            \\Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp
            \\
        ;

        const headers_str = try std.fmt.allocPrint(self.allocator, "{}\r\n{}\r\n", .{ request_line, header_entries });
        defer self.allocator.free(headers_str);
        // warn("{}\n", .{headers_str});

        // define SSL_library_init() OPENSSL_init_ssl(0, NULL)
        // Return: always 1
        const lib_init = c.OPENSSL_init_ssl(0, null);

        // define SSL_load_error_strings()  OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL)
        // Return: no value
        _ = c.OPENSSL_init_ssl(c.OPENSSL_INIT_LOAD_SSL_STRINGS | c.OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

        // define OpenSSL_add_all_algorithms() OPENSSL_add_all_algorithms_noconf()
        // define OPENSSL_add_all_algorithms_noconf() OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS, NULL)
        // Return: nothing
        _ = c.OPENSSL_init_crypto(c.OPENSSL_INIT_ADD_ALL_CIPHERS | c.OPENSSL_INIT_ADD_ALL_DIGESTS, null);

        const method = c.TLSv1_2_client_method() orelse return error.TLSClientMethod;

        const ctx = c.SSL_CTX_new(method) orelse return error.SSLContextNew;
        defer c.SSL_CTX_free(ctx);

        const ssl = c.SSL_new(ctx) orelse return error.SSLNew;
        defer c.SSL_free(ssl);

        const host_socket = try net.tcpConnectToHost(self.allocator, domain, port);
        defer host_socket.close();

        const set_fd = c.SSL_set_fd(ssl, host_socket.handle);
        if (set_fd == 0) {
            return error.SetSSLFileDescriptor;
        }

        try c.sslConnect(ssl);

        const write_success = c.SSL_write(ssl, @ptrCast(*const c_void, headers_str), @intCast(c_int, headers_str.len));
        if (write_success <= 0) {
            return error.SSLWrite;
        }

        // warn("=================\n", .{});
        var buf: [1024 * 100]u8 = undefined;

        var first_bytes = try c.sslRead(ssl, host_socket.handle, &buf);

        // Parse header
        var context = Context{
            .buf = buf[0..@intCast(usize, first_bytes)],
            .count = @intCast(usize, first_bytes),
            .index = 0,
        };

        // warn("{}\n", .{context.buf});

        var cur = context.index;

        if (!seek(&context, ' ')) return error.NoVersion;

        const version = context.buf[cur .. context.index - 1];
        // warn("{}|\n", .{version});

        cur = context.index;
        if (!seek(&context, ' ')) return error.NoStatusCode;
        const status_code = context.buf[cur .. context.index - 1];
        // warn("{}|\n", .{status_code});

        if (!mem.eql(u8, status_code, "200")) return error.StatusCodeNot200;

        cur = context.index;
        if (!seek(&context, '\r')) return error.NoStatusMessage;
        const status_msg = context.buf[cur .. context.index - 1];
        // warn("{}|\n", .{status_msg});

        try expect(&context, '\n');

        const Headers = StringArrayHashMap([]const u8);
        // Parse header fields
        var h = Headers.init(self.allocator);
        defer h.deinit();
        cur = context.index;
        while (context.buf[cur] != '\r') {
            if (!seek(&context, ':')) {
                return error.NoName;
            }

            // TODO?: Need to trim name?
            const name = context.buf[cur .. context.index - 1];
            cur = context.index;

            if (!seek(&context, '\r')) {
                return error.NoValue;
            }
            try expect(&context, '\n');

            switch (context.buf[context.index]) {
                '\t', ' ' => {
                    if (!seek(&context, '\r')) {
                        return error.InvalidObsFold;
                    }
                    try expect(&context, '\n');
                },
                else => {},
            }

            const value = mem.trim(u8, context.buf[cur .. context.index - 2], " ");
            cur = context.index;
            try h.put(name, value);
        }

        try expect(&context, '\r');
        try expect(&context, '\n');

        { // Check header fields 'transfer_encoding', 'Content-Type'
            var is_error = true;
            const search_value_1 = "chunked";
            for (h.items()) |e| {
                if (mem.eql(u8, e.key, "transfer-encoding") and
                    e.value.len >= search_value_1.len and
                    mem.eql(u8, e.value[0..search_value_1.len], search_value_1))
                {
                    is_error = false;
                    break;
                }
            }

            if (is_error) return error.NotChunkedTransfer;

            is_error = true;
            const search_value_2 = "application/json";
            for (h.items()) |e| {
                if (mem.eql(u8, e.key, "Content-Type") and
                    e.value.len >= search_value_2.len and
                    mem.eql(u8, e.value[0..search_value_2.len], search_value_2))
                {
                    is_error = false;
                    break;
                }
            }

            if (is_error) return error.WrongContentType;
        }

        // warn("index: {} | count: {}\n", .{ context.index, context.count });
        if (context.count > context.index) {
            // TODO: first read contains some body also
        }

        var body = ArrayList(u8).init(self.allocator);
        while (true) {
            const bytes = try c.sslRead(ssl, host_socket.handle, &buf);
            const chunk_part = buf[0..bytes];
            // warn("{}\n", .{chunk_part});

            // TODO: not the best solution
            if (mem.lastIndexOf(u8, chunk_part, "0\r\n")) |last_index| {
                const trimmed_hex = mem.trimLeft(u8, chunk_part[0 .. last_index + 1], "\r\n");

                if (trimmed_hex.len == 1 and trimmed_hex[0] == '0') {
                    // warn("End of body\n", .{});
                    break;
                }
            }
            // TODO?: could limit to smaller chunk sizes?
            if (mem.indexOfScalar(u8, chunk_part, '\r')) |index| {
                if (index == 0) {
                    continue;
                }

                const chunk_length = try fmt.parseUnsigned(u32, chunk_part[0..index], 16);
                var chunk_count: u32 = 0;
                while (true) {
                    const chunk_bytes = try c.sslRead(ssl, host_socket.handle, &buf);

                    // TODO: allocate chunk parts
                    const chunk_buf = buf[0..chunk_bytes];
                    try body.appendSlice(chunk_buf);
                    // warn("{}", .{chunk_buf});
                    chunk_count += @intCast(u32, chunk_bytes);
                    if (chunk_count >= chunk_length) {
                        break;
                    }

                    if (bytes == 0) break;
                    if (bytes < 0) return error.ReadingBody;
                }
            }

            if (bytes == 0) break;
            if (bytes < 0) return error.ReadingBody;
        }

        return body.toOwnedSlice();
    }

    // pub fn deinit(self: Self) void {
    //     os.close(self.fd);
    // c.SSL_free(self.ssl);
    // }
};

fn seek(ctx: *Context, char: u8) bool {
    while (true) : (ctx.index += 1) {
        if (ctx.index >= ctx.count) {
            return false;
        } else if (ctx.buf[ctx.index] == char) {
            ctx.index += 1;
            return true;
        }
    }
}

fn expect(ctx: *Context, char: u8) !void {
    if (ctx.count <= ctx.index) {
        return error.UnexpectedEof;
    } else if (ctx.buf[ctx.index] == char) {
        ctx.index += 1;
    } else {
        return error.InvalidChar;
    }
}

const Mpv = struct {
    const Self = @This();

    // TODO?: Combine Data and Event
    pub const DataString = struct {
        data: ?[]const u8,
        request_id: usize,
        @"error": []const u8,
    };

    pub const DataF32 = struct {
        data: ?f32,
        request_id: usize,
        @"error": []const u8,
    };

    pub const Event = struct {
        event: []const u8,
    };

    pub const Command = struct {
        command: [][]const u8,
        request_id: usize,
    };

    fd: os.fd_t,
    allocator: *Allocator,
    video_path: []const u8 = "",
    video_time: f64 = 0.0,

    // TODO?: remove Mpv.Property and request_id field from different structs. In current implementation find right value based on type.
    pub const Property = enum {
        Path,
        PlaybackTime,
    };

    pub fn init(allocator: *Allocator, socket_path: []const u8) !Self {
        const socket_file = try net.connectUnixSocket(socket_path);

        var self = Self{
            .fd = socket_file.handle,
            .allocator = allocator,
        };

        // Set video path
        try self.requestProperty(Property.Path);
        try self.readResponses();
        // Set video playback time
        try self.requestProperty(Property.PlaybackTime);
        try self.readResponses();

        return self;
    }

    pub fn requestProperty(self: *Self, property: Property) !void {
        var get_property: []const u8 = "get_property";

        const cmd = blk: {
            switch (property) {
                .PlaybackTime => {
                    const property_name: []const u8 = "playback-time";
                    break :blk Mpv.Command{
                        .command = &[_][]const u8{ get_property, property_name },
                        .request_id = @enumToInt(Property.PlaybackTime),
                    };
                },
                .Path => {
                    const property_name: []const u8 = "path";
                    break :blk Mpv.Command{
                        .command = &[_][]const u8{ get_property, property_name },
                        .request_id = @enumToInt(Property.Path),
                    };
                },
            }
        };

        var buf: [100]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var request_str = std.ArrayList(u8).init(&fba.allocator);
        try std.json.stringify(cmd, .{}, request_str.writer());
        try request_str.appendSlice("\r\n");

        _ = try os.write(self.fd, request_str.items);
    }

    pub fn readResponses(self: *Self) !void {
        var buf: [512]u8 = undefined;
        const bytes = try os.read(self.fd, buf[0..]);

        const json_objs = mem.trimRight(u8, buf[0..bytes], "\r\n");
        var json_obj = mem.split(json_objs, "\n");
        var it = json_obj.next();

        while (it) |json_str| : (it = json_obj.next()) {
            var stream_data_string = std.json.TokenStream.init(json_str);
            if (std.json.parse(Mpv.DataString, &stream_data_string, .{ .allocator = self.allocator })) |resp| {
                defer std.json.parseFree(Mpv.DataString, resp, .{ .allocator = self.allocator });
                if (!mem.eql(u8, "success", resp.@"error")) {
                    warn("Mpv json field error isn't success\n", .{});
                }
                if (resp.data) |url| {
                    self.allocator.free(self.video_path);
                    self.video_path = try mem.dupe(self.allocator, u8, url);
                } else {
                    warn("Mpv json field data is null\n", .{});
                }
                continue;
            } else |err| {
                if (err != error.UnknownField and err != error.UnexpectedToken) return err;
            }

            var stream_data_f32 = std.json.TokenStream.init(json_str);
            if (std.json.parse(Mpv.DataF32, &stream_data_f32, .{ .allocator = self.allocator })) |resp| {
                defer std.json.parseFree(Mpv.DataF32, resp, .{ .allocator = self.allocator });
                if (!mem.eql(u8, "success", resp.@"error")) {
                    warn("Mpv json field error isn't success\n", .{});
                }
                if (resp.data) |time| {
                    self.video_time = time;
                } else {
                    warn("Mpv json field data is null\n", .{});
                }
                continue;
            } else |err| {
                if (err != error.UnknownField and err != error.UnexpectedToken) return err;
            }

            var stream_event = std.json.TokenStream.init(json_str);
            const resp = try std.json.parse(Mpv.Event, &stream_event, .{ .allocator = self.allocator });
            defer std.json.parseFree(Mpv.Event, resp, .{ .allocator = self.allocator });
            warn("EVENT: {}\n", .{resp.event});
        }
    }

    pub fn deinit(self: *Self) void {
        os.close(self.fd);
        self.allocator.free(self.video_path);
    }
};

test "mpv json ipc" {
    {
        const json_str =
            \\{"data":190.482000,"error":"success","request_id":1}
        ;

        var stream = std.json.TokenStream.init(json_str);
        const resp = try std.json.parse(Mpv.DataF32, &stream, .{ .allocator = std.testing.allocator });
        defer std.json.parseFree(Mpv.DataF32, resp, .{ .allocator = std.testing.allocator });
        std.testing.expect(resp.data.? == 190.482000);
        std.testing.expect(mem.eql(u8, "success", resp.@"error"));
    }

    {
        const json_str =
            \\{"data":"/path/tosomewhere/","error":"success","request_id":0}
        ;

        var stream = std.json.TokenStream.init(json_str);
        const resp = try std.json.parse(Mpv.DataString, &stream, .{ .allocator = std.testing.allocator });
        defer std.json.parseFree(Mpv.DataString, resp, .{ .allocator = std.testing.allocator });
        std.testing.expect(mem.eql(u8, "/path/tosomewhere/", resp.data.?));
        std.testing.expect(mem.eql(u8, "success", resp.@"error"));
    }

    {
        const json_str =
            \\{"data":null,"error":"success","request_id":1}
        ;

        var stream = std.json.TokenStream.init(json_str);
        const resp = try std.json.parse(Mpv.DataF32, &stream, .{ .allocator = std.testing.allocator });
        defer std.json.parseFree(Mpv.DataF32, resp, .{ .allocator = std.testing.allocator });
        std.testing.expect(resp.data == null);
        std.testing.expect(mem.eql(u8, "success", resp.@"error"));
    }

    {
        const json_str =
            \\{ "event": "event_name" }
        ;
        var stream = std.json.TokenStream.init(json_str);
        const resp = try std.json.parse(Mpv.Event, &stream, .{ .allocator = std.testing.allocator });
        defer std.json.parseFree(Mpv.Event, resp, .{ .allocator = std.testing.allocator });
        std.testing.expect(mem.eql(u8, "event_name", resp.event));
    }

    {
        var c1: []const u8 = "get_property";
        var c2: []const u8 = "playback-time";
        const cmd = Mpv.Command{
            .command = &[_][]const u8{ c1, c2 },
            .request_id = 0,
        };

        var buf: [100]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var result_str = std.ArrayList(u8).init(&fba.allocator);
        try std.json.stringify(cmd, .{}, result_str.writer());

        std.testing.expect(mem.eql(u8, result_str.items,
            \\{"command":["get_property","playback-time"],"request_id":0}
        ));
    }
}
