const std = @import("std");
const warn = std.debug.warn;
const root = @import("root");
const io = std.io;
const os = std.os;
const Mode = io.Mode;

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/err.h");
});

pub usingnamespace @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/err.h");
});

pub const mode: Mode = if (@hasDecl(root, "io_mode"))
    root.io_mode
else if (@hasDecl(root, "event_loop"))
    Mode.evented
else
    Mode.blocking;

pub fn sslRead(ssl: *SSL, sockfd: os.fd_t, buf: []u8) !usize {
    const len = @intCast(c_int, buf.len);
    const bytes = SSL_read(ssl, @ptrCast(*c_void, buf), len);
    if (bytes <= 0) {
        warn("SSL ERROR: {d}\n", .{SSL_get_error(ssl, bytes)});
        return error.SSLRead;
    }
    return @intCast(usize, bytes);
}

pub fn sslConnect(ssl: *SSL) !void {
    const ssl_fd = SSL_connect(ssl);

    if (ssl_fd != 1) {
        warn("SSL ERROR: {d}\n", .{SSL_get_error(ssl, ssl_fd)});
        return error.SSLConnect;
    }
}
