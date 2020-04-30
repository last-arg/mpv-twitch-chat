// Build
// zig build-exe src/main.zig $NIX_CFLAGS_COMPILE $NIX_LDFLAGS -lc -lssl -lcrypto --release-small
const std = @import("std");
const warn = std.debug.warn;
const net = std.net;
const Address = std.net.Address;
const http = std.http;
const Headers = std.http.Headers;
const os = std.os;
const fmt = std.fmt;
const json = std.json;
const Parser = std.json.Parser;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const ascii = std.ascii;
const c = @import("c.zig");

// TODO: Function 'makeTwitchCommentsRequest' will throw 'error: SSLConnection'
// pub const io_mode = .evented;

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

        if (root.Object.get("comments")) |comments| {
            const num = comments.value.Array.items.len;

            var offsets_array = try ArrayList(f64).initCapacity(allocator, num);
            errdefer offsets_array.deinit();

            var comments_array = try ArrayList(Comment).initCapacity(allocator, num);
            errdefer comments_array.deinit();

            for (comments.value.Array.items) |comment| {
                const commenter = comment.Object.get("commenter").?.value;
                const name = commenter.Object.get("display_name").?.value.String;

                const message = comment.Object.get("message").?.value;
                const message_body = message.Object.get("body").?.value.String;

                // NOTE: can be a float or int
                const offset_seconds = blk: {
                    const offset_value = comment.Object.get("content_offset_seconds").?.value;
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
                .is_last = root.Object.get("_next") == null,
                .is_first = root.Object.get("_prev") == null,
            };
        }

        return error.InvalidJson;
    }

    pub fn printComments(self: Self, start_index: usize, end_index: usize) !void {
        var i = start_index;
        // TODO: Decide if end_index is exclusive or inclusive.
        while (i < end_index) : (i += 1) {
            const offset = self.offsets[i];
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
            var buf: [1024]u8 = undefined; // NOTE: IRC max message length is 512 + extra
            const b = try fmt.bufPrint(buf[0..], "[{d}:{d:0<2}:{d:0<2}] " ++ BOLD ++ "{}" ++ RESET ++ ": {}\n", .{ hours, minutes, seconds, comment.name, comment.body });
            try stdout.writeAll(b);
        }
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.offsets);
        self.allocator.free(self.comments);
    }
};

pub fn main() anyerror!void {
    const allocator = std.heap.page_allocator;

    warn("==> Connect to MPV socket\n", .{});
    var mpv = try Mpv.init(allocator, "/tmp/mpv-twitch-socket");
    defer mpv.deinit();

    // Get twitch video ID.
    // const url = "https://www.twitch.tv/videos/604738742?t=8h47m8s";
    const url = mpv.video_path;
    const start_index = (mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl) + 1; // NOTE: need the pos after '/'.
    const end_index = mem.lastIndexOfScalar(u8, url, '?') orelse url.len;

    const twitch = try Twitch.init(allocator, url[start_index..end_index]);
    // defer twitch.deinit();
    // warn("{}\n", .{twitch});

    // warn("==> {}\n", .{url[start_index..end_index]});
    warn("==> Download comments\n", .{});
    const comments_json = try twitch.requestCommentsJson(mpv.video_time);
    defer twitch.allocator.free(comments_json);
    // const comments_json = @embedFile("../test/skadoodle-chat.json");
    var comments = try Comments.initTwitchJson(allocator, comments_json);
    defer comments.deinit();

    while (true) {
        try mpv.requestProperty(.PlaybackTime);
        try mpv.readResponses();

        // warn("pos: {d}\n", .{mpv.video_time});

        const new_index = blk: {
            for (comments.offsets[comments.next_index..]) |offset, i| {
                // warn("{d} > {d}\n", .{ mpv.video_time, offset });
                if (mpv.video_time > offset) {
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
        if ((!comments.is_first and mpv.video_time < first_offset) or
            (!comments.is_last and mpv.video_time > last_offset))
        {
            warn("==> Download new comments\n", .{});
            const old_end = comments.offsets[comments.offsets.len - 1];

            comments.deinit();
            const new_json = try twitch.requestCommentsJson(mpv.video_time);
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
                    if (mpv.video_time > offset) {
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
        const fd = (try net.tcpConnectToHost(allocator, domain, port)).handle;
        return Self{
            .allocator = allocator,
            .video_id = video_id,
        };
    }

    pub fn requestCommentsJson(self: Self, video_offset: f64) ![]const u8 {
        const location = try std.fmt.allocPrint(self.allocator, "/v5/videos/{}/comments?content_offset_seconds={d:.2}", .{ self.video_id, video_offset });
        defer self.allocator.free(location);
        const request_line = try std.fmt.allocPrint(self.allocator, "GET {} HTTP/1.1", .{location});
        defer self.allocator.free(request_line);

        var headers = http.Headers.init(self.allocator);
        defer headers.deinit();

        // TODO: change accept to twitch+json
        try headers.append("Accept", "*/*", null);
        try headers.append("Connection", "close", null);
        try headers.append("Host", "api.twitch.tv", null);
        try headers.append("Client-ID", "yaoofm88l1kvv8i9zx7pyc44he2tcp", null);

        const headers_str = try std.fmt.allocPrint(self.allocator, "{}\n{}\n", .{ request_line, headers });
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

        const fd = (try net.tcpConnectToHost(self.allocator, domain, port)).handle;
        defer os.close(fd);

        const set_fd = c.SSL_set_fd(ssl, fd);
        if (set_fd == 0) {
            return error.SetSSLFileDescriptor;
        }

        const ssl_fd = c.SSL_connect(ssl);

        if (ssl_fd != 1) {
            return error.SSLConnection;
        }

        const write_success = c.SSL_write(ssl, @ptrCast(*const c_void, headers_str), @intCast(c_int, headers_str.len));
        if (write_success <= 0) {
            return error.SSLWrite;
        }

        // warn("=================\n", .{});
        var buf: [1024 * 100]u8 = undefined;

        const first_bytes = c.SSL_read(ssl, @ptrCast(*c_void, &buf), buf.len);
        if (first_bytes <= 0) return error.NoHeader;

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
            try h.append(name, value, null);
        }

        try expect(&context, '\r');
        try expect(&context, '\n');

        { // Check header fields 'transfer_encoding', 'Content-Type'
            var is_error = true;
            const search_value_1 = "chunked";
            for (h.toSlice()) |e| {
                if (mem.eql(u8, e.name, "transfer-encoding") and
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
            for (h.toSlice()) |e| {
                if (mem.eql(u8, e.name, "Content-Type") and
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
            const bytes = c.SSL_read(ssl, @ptrCast(*c_void, &buf), buf.len);
            const chunk_part = buf[0..@intCast(usize, bytes)];
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
                    const chunk_bytes = c.SSL_read(ssl, @ptrCast(*c_void, &buf), buf.len);

                    // TODO: allocate chunk parts
                    const chunk_buf = buf[0..@intCast(usize, chunk_bytes)];
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

    fd: os.fd_t,
    allocator: *Allocator,
    video_path: []const u8 = "",
    video_time: f64 = 0.0,

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
        const cmd = blk: {
            switch (property) {
                .PlaybackTime => {
                    const property_id = comptime try propertyIntToString(Property.PlaybackTime);
                    break :blk "{ \"command\": [\"get_property\", \"playback-time\"], request_id:" ++ property_id ++ " }\r\n";
                },
                .Path => {
                    const property_id = comptime try propertyIntToString(Property.Path);
                    break :blk "{ \"command\": [\"get_property\", \"path\"], request_id:" ++ property_id ++ " }\r\n";
                },
            }
        };

        _ = try os.write(self.fd, cmd);
    }

    pub fn readResponses(self: *Self) !void {
        var buf: [512]u8 = undefined;
        const bytes = try os.read(self.fd, buf[0..]);

        var p = Parser.init(self.allocator, false);
        defer p.deinit();

        const json_objs = mem.trimRight(u8, buf[0..bytes], "\r\n");
        var json_obj = mem.split(json_objs, "\n");
        var it = json_obj.next();
        while (it) |obj| : (it = json_obj.next()) {
            p.reset();

            // TODO: maybe can reuse memory
            var tree = try p.parse(obj);
            defer tree.deinit();

            const root = tree.root;

            if (root.Object.get("request_id")) |property_id| {
                if (!mem.eql(u8, root.Object.get("error").?.value.String, "success")) continue;
                const data = root.Object.get("data").?.value;
                switch (@intToEnum(Property, @intCast(u1, property_id.value.Integer))) {
                    .PlaybackTime => {
                        self.video_time = data.Float;
                    },
                    .Path => {
                        self.allocator.free(self.video_path);
                        self.video_path = try mem.dupe(self.allocator, u8, data.String);
                    },
                }
            } else if (root.Object.get("event")) |event| {
                const e = event.value.String;
                warn("EVENT: {}\n", .{e});
            }
        }
    }

    fn propertyIntToString(comptime property: Property) ![]const u8 {
        const request_id_str = comptime blk: {
            // NOTE: Mpv.Property enum int value should not be 100 or bigger.
            var buf: [2]u8 = undefined;
            break :blk try intToString(@enumToInt(property), &buf);
        };
        return request_id_str;
    }

    fn intToString(int: u32, buf: []u8) ![]const u8 {
        return try std.fmt.bufPrint(buf, "{}", .{int});
    }

    pub fn deinit(self: *Self) void {
        os.close(self.fd);
        self.allocator.free(self.video_path);
    }
};
