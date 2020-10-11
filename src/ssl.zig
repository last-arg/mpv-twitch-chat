const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const net = std.net;
const c = @import("c.zig");

// NOTE: SSL session - http://h30266.www3.hpe.com/odl/axpos/opsys/vmsos84/BA554_90007/ch04s03.html
// https://nachtimwald.com/2014/10/06/client-side-session-cache-in-openssl/

// TODO: move openssl read and write function from c.zig
// TODO: Remove c.zig import from twitch.zig

pub const SSL = struct {
    const Self = @This();
    const domain = "www.twitch.tv";
    const port = 443;

    ssl: *c.SSL,
    session: ?*c.SSL_SESSION,
    ctx: *c.SSL_CTX,
    socket: fs.File,
    allocator: *Allocator,

    pub fn init(allocator: *Allocator) !SSL {

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
        errdefer c.SSL_CTX_free(ctx);

        const socket = try net.tcpConnectToHost(allocator, domain, port);
        errdefer socket.close();

        var ssl = c.SSL_new(ctx) orelse return error.SSLNew;
        errdefer c.SSL_free(ssl);

        const set_fd = c.SSL_set_fd(ssl, socket.handle);
        if (set_fd == 0) {
            return error.SetSSLFileDescriptor;
        }

        try c.sslConnect(ssl);

        const session = c.SSL_get1_session(ssl) orelse {
            return error.SSLGetSession;
        };

        _ = c.SSL_set_session(ssl, session);

        _ = c.SSL_shutdown(ssl);

        var result = SSL{
            .ssl = ssl,
            .ctx = ctx,
            .socket = socket,
            .allocator = allocator,
            .session = null,
        };
        return result;
    }

    pub fn connect(self: *Self) !void {
        _ = c.SSL_shutdown(self.ssl);
        c.SSL_free(self.ssl);
        self.socket.close();

        const ctx = self.ctx;

        const socket = try net.tcpConnectToHost(self.allocator, domain, port);
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

        try c.sslConnect(ssl);
        errdefer _ = c.SSL_shutdown(ssl_ptr);

        const session = c.SSL_get1_session(ssl);

        if (self.session) |sess| c.SSL_SESSION_free(sess);

        self.socket = socket;
        self.session = session;
        self.ssl = ssl;
    }

    pub fn deinit(self: Self) void {
        _ = c.SSL_shutdown(self.ssl);
        if (self.session) |sess| c.SSL_SESSION_free(sess);
        c.SSL_free(self.ssl);
        self.socket.close();
        c.SSL_CTX_free(self.ctx);
    }
};
