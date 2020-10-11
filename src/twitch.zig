const std = @import("std");
const Allocator = std.mem.Allocator;
const warn = std.debug.warn;
const assert = std.debug.assert;
const c = @import("c.zig");
const fmt = std.fmt;
const StringArrayHashMap = std.StringArrayHashMap;
const ArrayList = std.ArrayList;
const mem = std.mem;
const SSL = @import("ssl.zig").SSL;

pub const Twitch = struct {
    const Self = @This();
    allocator: *Allocator,
    video_id: []const u8,
    ssl: SSL,

    pub fn init(allocator: *Allocator, video_id: []const u8, ssl: SSL) Self {
        // TODO: create ssl connection
        return Self{
            .allocator = allocator,
            .video_id = video_id,
            .ssl = ssl,
        };
    }

    pub fn requestCommentsJson(self: Self, video_offset: f64) ![]const u8 {
        assert(video_offset >= 0.0);

        // TODO: change accept to twitch+json
        // TODO?: Connection: open ???
        const header =
            \\GET /v5/videos/{}/comments?content_offset_seconds={d:.2} HTTP/1.1
            \\Accept: */*
            \\Connection: close
            \\Host: api.twitch.tv
            \\Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp
            \\
            \\
        ;

        var buf: [256]u8 = undefined;
        const header_str = try std.fmt.bufPrint(&buf, header, .{ self.video_id, video_offset });

        var ssl = self.ssl;
        try ssl.connect();
        defer ssl.connectionCleanup();
        var ssl_ptr = ssl.ssl.?;
        var host_socket = ssl.socket.?;

        const write_success = c.SSL_write(ssl_ptr, @ptrCast(*const c_void, header_str), @intCast(c_int, header_str.len));
        if (write_success <= 0) {
            return error.SSLWrite;
        }

        // warn("=================\n", .{});
        var buf_ssl: [1024 * 100]u8 = undefined;

        var first_bytes = try c.sslRead(ssl_ptr, host_socket.handle, &buf_ssl);
        // warn("{}\n", .{buf_ssl[0..first_bytes]});

        // Parse header
        var context = Context{
            .buf = buf_ssl[0..@intCast(usize, first_bytes)],
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
            const bytes = try c.sslRead(ssl_ptr, host_socket.handle, &buf);
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
                    const chunk_bytes = try c.sslRead(ssl_ptr, host_socket.handle, &buf);

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

const Context = struct {
    buf: []const u8,
    count: usize = 0,
    index: usize = 0,
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

pub fn urlToVideoId(url: []const u8) ![]const u8 {
    const start_index = (mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl) + 1;
    const end_index = mem.lastIndexOfScalar(u8, url, '?') orelse url.len;

    return url[start_index..end_index];
}

test "urlToVideoId" {
    {
        const url = "https://www.twitch.tv/videos/762169747";
        const result = try urlToVideoId(url);
        std.testing.expect(mem.eql(u8, result, "762169747"));
    }
    {
        const url = "https://www.twitch.tv/videos/762169747?t=2h47m8s";
        const result = try urlToVideoId(url);
        std.testing.expect(mem.eql(u8, result, "762169747"));
    }
}

test "download" {
    const video_id = "762169747";
    const allocator = std.testing.allocator;
    const ssl = try SSL.init(allocator);
    defer ssl.deinit();
    const twitch = Twitch.init(allocator, video_id, ssl);
    const r1 = try twitch.requestCommentsJson(1.0);
    allocator.free(r1);
    const r2 = try twitch.requestCommentsJson(1.0);
    allocator.free(r2);
}
