const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const net = std.net;
const os = std.os;
const c = @import("c.zig");

// Non-blocking openssl
// https://stackoverflow.com/a/31174268
// SSL_pending()
// https://groups.google.com/forum/#!msg/mailing.openssl.users/nJRF_JVnPkc/377tgaE4sRgJ

// openssl examples
// http://h30266.www3.hpe.com/odl/axpos/opsys/vmsos84/BA554_90007/ch04s03.html
// https://nachtimwald.com/2014/10/06/client-side-session-cache-in-openssl/

pub const OpenSSL = struct {
    const Self = @This();

    ssl: ?*c.SSL = null,
    session: ?*c.SSL_SESSION = null,
    ctx: *c.SSL_CTX,
    socket: ?fs.File = null,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator) !Self {
        // define SSL_library_init() OPENSSL_init_ssl(0, NULL)
        // Return: always 1
        _ = c.OPENSSL_init_ssl(0, null);

        // define SSL_load_error_strings()  OPENSSL_init_ssl(OPENSSL_INIT_LOAD_SSL_STRINGS | OPENSSL_INIT_LOAD_CRYPTO_STRINGS, NULL)
        // Return: no value
        _ = c.OPENSSL_init_ssl(c.OPENSSL_INIT_LOAD_SSL_STRINGS | c.OPENSSL_INIT_LOAD_CRYPTO_STRINGS, null);

        // define OpenSSL_add_all_algorithms() OPENSSL_add_all_algorithms_noconf()
        // define OPENSSL_add_all_algorithms_noconf() OPENSSL_init_crypto(OPENSSL_INIT_ADD_ALL_CIPHERS | OPENSSL_INIT_ADD_ALL_DIGESTS, NULL)
        // Return: nothing
        _ = c.OPENSSL_init_crypto(c.OPENSSL_INIT_ADD_ALL_CIPHERS | c.OPENSSL_INIT_ADD_ALL_DIGESTS, null);

        const method = c.TLSv1_2_client_method() orelse return error.TLSClientMethod;

        const ctx = c.SSL_CTX_new(method) orelse return error.SSLContextNew;
        errdefer c.SSL_CTX_free(ctx);

        return Self{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn connect(self: *Self, hostname: []const u8, port: u16) !void {
        const ctx = self.ctx;

        const socket = try net.tcpConnectToHost(self.allocator, hostname, port);
        errdefer socket.close();

        const ssl = c.SSL_new(ctx) orelse return error.SSLNew;
        errdefer c.SSL_free(ssl);

        const set_fd = c.SSL_set_fd(ssl, socket.handle);
        if (set_fd == 0) {
            return error.SetSSLFileDescriptor;
        }

        if (self.session) |sess| {
            _ = c.SSL_set_session(ssl, sess);
        }

        try opensslConnect(ssl);
        errdefer _ = c.SSL_shutdown(ssl_ptr);

        const session = c.SSL_get1_session(ssl);

        if (self.session) |sess| c.SSL_SESSION_free(sess);

        self.socket = socket;
        self.session = session;
        self.ssl = ssl;
    }

    pub fn connectCleanup(self: Self) void {
        if (self.ssl) |ssl| {
            _ = c.SSL_shutdown(ssl);
            c.SSL_free(ssl);
        }
        if (self.socket) |socket| socket.close();
    }

    pub const ReadError = error{NegativeBytes};
    pub const WriteError = error{NegativeBytes};
    pub const Reader = std.io.Reader(*OpenSSL, ReadError, read);
    pub const Writer = std.io.Writer(*OpenSSL, WriteError, write);

    pub fn reader(self: *@This()) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: *@This()) Writer {
        return .{ .context = self };
    }

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        const ssl = self.ssl orelse unreachable;
        const len = @intCast(c_int, buf.len);
        const bytes = c.SSL_read(ssl, @ptrCast(*anyopaque, buf), len);
        if (bytes <= 0) {
            warn("SSL ERROR: {d}\n", .{c.SSL_get_error(ssl, bytes)});
            return error.NegativeBytes;
        }
        return @intCast(usize, bytes);
    }

    pub fn write(self: *Self, data: []const u8) WriteError!usize {
        const ssl = self.ssl orelse unreachable;
        const bytes = c.SSL_write(ssl, @ptrCast(*const anyopaque, data), @intCast(c_int, data.len));
        if (bytes <= 0) {
            warn("SSL ERROR: {d}\n", .{c.SSL_get_error(ssl, bytes)});
            return error.NegativeBytes;
        }
        return @intCast(usize, bytes);
    }

    pub fn deinit(self: Self) void {
        if (self.session) |sess| c.SSL_SESSION_free(sess);
        self.connectCleanup();
        c.SSL_CTX_free(self.ctx);
    }

    fn opensslConnect(ssl: *c.SSL) !void {
        const ssl_fd = c.SSL_connect(ssl);

        if (ssl_fd != 1) {
            warn("SSL ERROR: {d}\n", .{c.SSL_get_error(ssl, ssl_fd)});
            return error.SSLConnect;
        }
    }
};
