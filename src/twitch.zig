const std = @import("std");
const Allocator = std.mem.Allocator;
const warn = std.debug.warn;
const assert = std.debug.assert;
const fmt = std.fmt;
const StringArrayHashMap = std.StringArrayHashMap;
const ArrayList = std.ArrayList;
const mem = std.mem;
const net = std.net;
const OpenSSL = @import("ssl.zig").OpenSSL;
const bearssl = @import("zig-bearssl");
const hzzp = @import("hzzp");

pub fn urlToVideoId(url: []const u8) ![]const u8 {
    // TODO: fix. won't work if there is slash after video id and before '?'
    const start_index = (mem.lastIndexOfScalar(u8, url, '/') orelse return error.InvalidUrl) + 1;
    const end_index = mem.lastIndexOfScalar(u8, url, '?') orelse url.len;

    return url[start_index..end_index];
}

test "urlToVideoId" {
    {
        const url = "https://www.twitch.tv/videos/855035286";
        const result = try urlToVideoId(url);
        std.testing.expect(mem.eql(u8, result, "855035286"));
    }
    {
        const url = "https://www.twitch.tv/videos/855035286?t=2h47m8s";
        const result = try urlToVideoId(url);
        std.testing.expect(mem.eql(u8, result, "855035286"));
    }
    // TODO: implement test where there is slash after video id and before '?'
}

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
    var resp = try httpsRequest(allocator, "www.twitch.tv", 443, path);
    defer allocator.free(resp);
}

fn verifyLine(line: []const u8) ![]const u8 {
    if (line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return error.InvalidLineEnd;
}

pub fn httpsRequestOpenSSL(allocator: *Allocator, hostname: [:0]const u8, port: u16, path: []const u8) ![]const u8 {
    var ssl = try OpenSSL.init(allocator);
    try ssl.connect(hostname, port);
    defer ssl.connectCleanup();

    var reader = ssl.reader();
    var writer = ssl.writer();

    const header_fmt =
        \\GET {} HTTP/1.1
        \\Accept: application/vnd.twitchtv.v5+json
        \\Connection: close
        \\Host: api.twitch.tv
        \\Client-ID: yaoofm88l1kvv8i9zx7pyc44he2tcp
        \\
        \\
    ;

    var buf: [256]u8 = undefined;
    const header_str = try fmt.bufPrint(&buf, header_fmt, .{path});
    const bytes_written = try writer.write(header_str);

    var buf_ssl: [mem.page_size]u8 = undefined;
    const status_line = blk: {
        const tmp = (try reader.readUntilDelimiterOrEof(&buf_ssl, '\n')) orelse return error.InvalidStatusLine;
        break :blk try verifyLine(tmp);
    };

    // Parse status line
    var status_it = mem.split(status_line, " ");
    const status_version = status_it.next() orelse return error.InvalidStatusLine;
    const status_code = status_it.next() orelse return error.InvalidStatusLine;
    const status_reason = status_it.rest();

    var version_it = mem.split(status_version, "/");
    const http_protocol = version_it.next() orelse return error.InvalidStatusLine;
    if (!mem.eql(u8, http_protocol, "HTTP")) return error.InvalidStatusLine;

    const http_version = version_it.next() orelse return error.InvalidStatusLine;
    if (!mem.eql(u8, http_version, "1.1")) return error.UnsupportedVersion;

    if (version_it.index != null) return error.InvalidStatusLine;

    // Parse header key values
    // line.len > 0
    while (true) {
        const header_line = blk: {
            const tmp = (try reader.readUntilDelimiterOrEof(&buf_ssl, '\n')) orelse return error.InvalidStatusLine;
            break :blk try verifyLine(tmp);
        };

        // warn("#{}#\n", .{header_line.len});
        if (header_line.len == 0) break;

        var index_sep = mem.indexOf(u8, header_line, ":") orelse return error.InvalidHeader;
        const key = header_line[0..index_sep];
        const value = mem.trim(u8, header_line[index_sep + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(key, "transfer-encoding")) {
            if (!std.ascii.eqlIgnoreCase(value, "chunked")) return error.InvalidTransferEncoding;
        }
    }

    // Parse chunked body
    var output = try ArrayList(u8).initCapacity(allocator, 50000);
    errdefer output.deinit();

    while (true) {
        var total_read_bytes: usize = 0;
        const body_line = blk: {
            const tmp = (try reader.readUntilDelimiterOrEof(&buf_ssl, '\n')) orelse return error.InvalidStatusLine;
            break :blk try verifyLine(tmp);
        };
        if (body_line.len == 0) continue; // Skip empty lines
        const chunk_len = std.fmt.parseUnsigned(usize, body_line, 16) catch return error.InvalidChunk;
        if (chunk_len == 0) break; // No more chunks

        // Read chunk body
        while (true) {
            const buf_len = std.math.min(chunk_len - total_read_bytes, buf_ssl.len);
            const chunk_bytes = try reader.read(buf_ssl[0..buf_len]);
            if (chunk_bytes == 0) break;
            try output.appendSlice(buf_ssl[0..chunk_bytes]);
            total_read_bytes += chunk_bytes;
            if (total_read_bytes >= chunk_len) break;
        }
    }

    return output.toOwnedSlice();
}

test "httpsRequestOpenSSL" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const path = "/v5/videos/855035286/comments?content_offset_seconds=2.00";
    var resp = try httpsRequestOpenSSL(allocator, "www.twitch.tv", 443, path);
    defer allocator.free(resp);
    // warn("{}\n", .{resp});
}
