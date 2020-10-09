const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const net = std.net;
const StringArrayHashMap = std.StringArrayHashMap;
const os = std.os;
const fmt = std.fmt;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const c = @import("c.zig");
const Mpv = @import("mpv.zig").Mpv;
const Comments = @import("comments.zig").Comments;

// TODO: non-blocking mode messes up openssl functions.
// https://stackoverflow.com/a/31174268
// SSL_pending()
// https://groups.google.com/forum/#!msg/mailing.openssl.users/nJRF_JVnPkc/377tgaE4sRgJ
// pub const io_mode = .evented;

const Context = struct {
    buf: []const u8,
    count: usize = 0,
    index: usize = 0,
};

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;

    var arg_it = std.process.args();
    _ = arg_it.skip();
    const chat_offset_correction = blk: {
        if (arg_it.nextPosix()) |value| {
            break :blk try fmt.parseFloat(f64, value);
        }
        warn("Failed to parse float value.\n", .{});
        break :blk 0.0;
    };

    warn("==> Connect to MPV socket\n", .{});
    var mpv = try Mpv.init(allocator, "/tmp/mpv-twitch-socket");
    defer mpv.deinit();

    // Get twitch video ID.
    const url = "https://www.twitch.tv/videos/762169747?t=2h47m8s";
    // const url = mpv.video_path;
    const start_index = (mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl) + 1; // NOTE: need the pos after '/'.
    const end_index = mem.lastIndexOfScalar(u8, url, '?') orelse url.len;

    const twitch = try Twitch.init(allocator, url[start_index..end_index]);
    // defer twitch.deinit();
    // warn("{}\n", .{twitch});

    warn("==> Download comments\n", .{});
    var corrected_time = blk: {
        const time = mpv.video_time - chat_offset_correction;
        if (time < 0) break :blk 0.0;
        break :blk time;
    };
    const comments_json = try twitch.requestCommentsJson(corrected_time);
    defer twitch.allocator.free(comments_json);
    // const comments_json = @embedFile("../test/skadoodle-chat.json");
    var comments = try Comments.init(allocator, comments_json, chat_offset_correction);
    defer comments.deinit();
    const stdout = std.io.getStdOut().outStream();

    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        // warn("pos: {d}\n", .{mpv.video_time});
        corrected_time = blk: {
            const time = mpv.video_time - chat_offset_correction;
            if (time < 0) break :blk 0.0;
            break :blk time;
        };

        while (try comments.generateComment(corrected_time)) |str| {
            try stdout.writeAll(str);
        }

        const first_offset = comments.offsets[0];
        const last_offset = comments.offsets[comments.offsets.len - 1];
        if ((!comments.is_first and corrected_time < first_offset) or
            (!comments.is_last and corrected_time > last_offset))
        {
            warn("==> Download new comments\n", .{});
            const new_json = try twitch.requestCommentsJson(corrected_time);
            comments.deinit();
            try comments.parse(new_json);

            comments.skipToNextIndex(corrected_time);

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
