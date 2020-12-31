const std = @import("std");
const Allocator = std.mem.Allocator;
const warn = std.debug.warn;
const assert = std.debug.assert;
const fmt = std.fmt;
const StringArrayHashMap = std.StringArrayHashMap;
const ArrayList = std.ArrayList;
const mem = std.mem;
const net = std.net;
const SSL = @import("ssl.zig").SSL;
const bearssl = @import("zig-bearssl");
const hzzp = @import("hzzp");

pub const Twitch = struct {
    const Self = @This();
    allocator: *Allocator,
    video_id: []const u8,
    ssl: SSL,

    pub fn init(allocator: *Allocator, video_id: []const u8, ssl: SSL) Self {
        return Self{
            .allocator = allocator,
            .video_id = video_id,
            .ssl = ssl,
        };
    }

    // TODO: refactor. Move ssl code to ssl file
    pub fn downloadComments(self: Self, video_offset: f64) ![]const u8 {
        assert(video_offset >= 0.0);

        var ssl = self.ssl;
        try ssl.connect();
        defer ssl.connectCleanup();

        const header =
            \\GET /v5/videos/{}/comments?content_offset_seconds={d:.2} HTTP/1.1
            \\Accept: application/vnd.twitchtv.v5+json
            \\Connection: close
            \\Host: api.twitch.tv
            \\Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp
            \\
            \\
        ;

        var buf: [256]u8 = undefined;

        const header_str = try std.fmt.bufPrint(&buf, header, .{ self.video_id, video_offset });

        const write_success = try ssl.write(header_str);

        warn("=================\n", .{});
        var buf_ssl: [1024 * 16]u8 = undefined;

        var first_bytes = try ssl.read(&buf_ssl);

        // Parse header
        var ctx = Context{
            .buf = buf_ssl[0..@intCast(usize, first_bytes)],
            .index = 0,
        };

        // warn("{}\n", .{ctx.buf});

        var cur = ctx.index;

        if (!ctx.seek(' ')) return error.NoVersion;

        const version = ctx.buf[cur .. ctx.index - 1];
        // warn("{}|\n", .{version});

        cur = ctx.index;
        if (!ctx.seek(' ')) return error.NoStatusCode;
        const status_code = ctx.buf[cur .. ctx.index - 1];
        // warn("{}|\n", .{status_code});

        if (!mem.eql(u8, status_code, "200")) return error.StatusCodeNot200;

        cur = ctx.index;
        if (!ctx.seek('\r')) return error.NoStatusMessage;
        const status_msg = ctx.buf[cur .. ctx.index - 1];
        // warn("{}|\n", .{status_msg});

        try ctx.expect('\n');

        const Headers = StringArrayHashMap([]const u8);
        // Parse header fields
        var h = Headers.init(self.allocator);
        defer h.deinit();
        cur = ctx.index;
        while (ctx.buf[cur] != '\r') {
            if (!ctx.seek(':')) {
                return error.NoName;
            }

            const name = ctx.buf[cur .. ctx.index - 1];
            cur = ctx.index;

            if (!ctx.seek('\r')) {
                return error.NoValue;
            }
            try ctx.expect('\n');

            switch (ctx.buf[ctx.index]) {
                '\t', ' ' => {
                    if (!ctx.seek('\r')) {
                        return error.InvalidObsFold;
                    }
                    try ctx.expect('\n');
                },
                else => {},
            }

            const value = mem.trim(u8, ctx.buf[cur .. ctx.index - 2], " ");
            cur = ctx.index;
            try h.put(name, value);
        }

        try ctx.expect('\r');
        try ctx.expect('\n');

        { // Check header fields 'transfer-encoding', 'Content-Type'
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

        // warn("index: {} | count: {}\n", .{ ctx.index, ctx.count });
        if (ctx.buf.len > ctx.index) {
            @panic("TODO?: First ssl.read response also contains body");
        }

        var body = ArrayList(u8).init(self.allocator);
        while (true) {
            const bytes = try ssl.read(&buf_ssl);
            if (bytes == 0) break;
            if (bytes < 0) return error.ReadingChunk;

            const chunk_part = buf_ssl[0..bytes];

            if (mem.eql(u8, chunk_part, "\r\n")) continue;
            if (mem.eql(u8, chunk_part, "0\r\n\r\n") or
                mem.eql(u8, chunk_part, "\r\n0\r\n\r\n")) break;

            if (mem.indexOfScalar(u8, chunk_part, '\r')) |end| {
                var count = try fmt.parseUnsigned(u32, chunk_part[0..end], 16);
                while (true) {
                    const chunk_bytes = try ssl.read(&buf_ssl);

                    if (chunk_bytes == 0) break;
                    if (chunk_bytes < 0) return error.ReadingChunk;

                    const chunk_buf = buf_ssl[0..chunk_bytes];
                    try body.appendSlice(chunk_buf);

                    if (count == @intCast(u32, chunk_bytes)) break;
                    if (count < @intCast(u32, chunk_bytes)) return error.ChunkLengthMismatch;
                    count -= @intCast(u32, chunk_bytes);
                }
            }
        }

        warn("End of download\n", .{});
        return body.toOwnedSlice();
    }
};

const Context = struct {
    const Self = @This();
    buf: []const u8,
    index: usize = 0,

    pub fn seek(self: *Self, char: u8) bool {
        while (true) : (self.index += 1) {
            if (self.index >= self.buf.len) {
                return false;
            } else if (self.buf[self.index] == char) {
                self.index += 1;
                return true;
            }
        }
    }

    pub fn expect(self: *Self, char: u8) !void {
        if (self.buf.len <= self.index) {
            return error.UnexpectedEof;
        } else if (self.buf[self.index] == char) {
            self.index += 1;
        } else {
            return error.InvalidChar;
        }
    }
};

pub fn urlToVideoId(url: []const u8) ![]const u8 {
    // TODO: fix. won't work if there is slash after video id and before '?'
    const start_index = (mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl) + 1;
    const end_index = mem.lastIndexOfScalar(u8, url, '?') orelse url.len;

    return url[start_index..end_index];
}

// test "urlToVideoId" {
//     {
//         const url = "https://www.twitch.tv/videos/855035286";
//         const result = try urlToVideoId(url);
//         std.testing.expect(mem.eql(u8, result, "855035286"));
//     }
//     {
//         const url = "https://www.twitch.tv/videos/855035286?t=2h47m8s";
//         const result = try urlToVideoId(url);
//         std.testing.expect(mem.eql(u8, result, "855035286"));
//     }
//     // TODO: implement test where there is slash after video id and before '?'
// }

pub fn httpsRequest(allocator: *Allocator, hostname: [:0]const u8, port_nr: u16, path: []const u8) ![]const u8 {
    // const system_cert = @embedFile("/etc/ssl/certs/ca-certificates.crt");
    // const cert = system_cert[0 .. system_cert.len - 1]; // Remove last new line
    const cert = @embedFile("../mozilla-bundle.pem");

    var trust_anchor = bearssl.TrustAnchorCollection.init(allocator);
    defer trust_anchor.deinit();
    try trust_anchor.appendFromPEM(cert);

    var x509 = bearssl.x509.Minimal.init(trust_anchor);
    var client = bearssl.Client.init(x509.getEngine());
    client.relocate();
    try client.reset(hostname, false);

    var socket = try net.tcpConnectToHost(allocator, hostname, port_nr);
    defer socket.close();

    var socket_reader = socket.reader();
    var socket_writer = socket.writer();

    var ssl_stream = bearssl.initStream(
        client.getEngine(),
        &socket_reader,
        &socket_writer,
    );
    defer ssl_stream.close() catch {};

    var buf: [std.mem.page_size]u8 = undefined;
    var http_client = hzzp.base.client.create(&buf, ssl_stream.inStream(), ssl_stream.outStream());

    try http_client.writeStatusLine("GET", path);
    try http_client.writeHeaderValue("Accept", "application/vnd.twitchtv.v5+json");
    try http_client.writeHeaderValue("Connection", "close");
    try http_client.writeHeaderValue("Host", "api.twitch.tv");
    try http_client.writeHeaderValue("Client-ID", "yaoofm88l1kvv8i9zx7pyc44he2tcp");
    try http_client.finishHeaders();
    try ssl_stream.flush();

    var output = try ArrayList(u8).initCapacity(allocator, 50000);
    errdefer output.deinit();

    while (try http_client.next()) |event| {
        switch (event) {
            .status => |status| {
                if (status.code != 200) {
                    warn("Invalid status code {d} returned\n", .{status.code});
                    return error.BadStatusCode;
                }
            },
            .header => {},
            .payload => |payload| {
                try output.appendSlice(payload.data);
            },
            .head_done => {},
            .skip => {},
            .end => {},
        }
    }

    return output.toOwnedSlice();
}

test "httpsRequest" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const path = "/v5/videos/855035286/comments?content_offset_seconds=2.00";
    var resp = try httpsRequest(allocator, host, port, path);
    defer allocator.free(resp);
}
