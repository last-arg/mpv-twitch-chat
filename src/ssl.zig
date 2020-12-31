const std = @import("std");
const warn = std.debug.warn;
const assert = std.debug.assert;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const net = std.net;
const os = std.os;
const bearssl = @import("zig-bearssl");
const hzzp = @import("hzzp");
const c = @import("c.zig");

pub const SSL = BearSSL;

const host = "www.twitch.tv";
const port = 443;

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
        warn("init OpenSSL\n", .{});

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

        return Self{
            .ctx = ctx,
            .allocator = allocator,
        };
    }

    pub fn connect(self: *Self) !void {
        const ctx = self.ctx;

        const socket = try net.tcpConnectToHost(self.allocator, host, port);
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

    pub fn read(self: Self, buf: []u8) !usize {
        const ssl = self.ssl orelse return error.SSLIsNull;
        const len = @intCast(c_int, buf.len);
        const bytes = c.SSL_read(ssl, @ptrCast(*c_void, buf), len);
        if (bytes <= 0) {
            warn("SSL ERROR: {d}\n", .{c.SSL_get_error(ssl, bytes)});
            return error.SSLRead;
        }
        return @intCast(usize, bytes);
    }

    pub fn write(self: Self, header_str: []u8) !usize {
        const ssl = self.ssl orelse return error.SSLIsNull;
        const bytes = c.SSL_write(ssl, @ptrCast(*const c_void, header_str), @intCast(c_int, header_str.len));
        if (bytes <= 0) {
            warn("SSL ERROR: {d}\n", .{c.SSL_get_error(ssl, bytes)});
            return error.SSLRead;
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

// Basic client example: https://bearssl.org/gitweb/?p=BearSSL;a=blob;f=samples/client_basic.c;h=31a88be4c128309091bde3e2065ebf416688ce02;hb=HEAD
pub const BearSSL = struct {
    const Self = @This();

    trust_anchor: bearssl.TrustAnchorCollection,
    socket_file: ?*fs.File = null,
    client: *bearssl.Client,
    stream: *Stream,

    pub const Stream = bearssl.Stream(*std.fs.File.Reader, *std.fs.File.Writer);

    pub fn init(allocator: *Allocator) !Self {
        var buf: [1024 * 16]u8 = undefined;
        warn("init BearSSL\n", .{});

        const cert = @embedFile("../cert.pem");

        var trust_anchor = bearssl.TrustAnchorCollection.init(allocator);
        errdefer trust_anchor.deinit();
        try trust_anchor.appendFromPEM(cert);

        var x509 = bearssl.x509.Minimal.init(trust_anchor);

        var client = bearssl.Client.init(x509.getEngine());
        client.relocate();
        try client.reset(host, false);

        var socket = try net.tcpConnectToHost(allocator, host, port);
        errdefer socket.close();

        var stream = bearssl.initStream(
            client.getEngine(),
            &socket.reader(),
            &socket.writer(),
        );
        errdefer stream.close catch {};

        var http_client = hzzp.base.client.create(&buf, stream.inStream(), stream.outStream());

        return BearSSL{
            .trust_anchor = trust_anchor,
            .socket_file = &socket,
            .client = &client,
            .stream = &stream,
        };
    }

    pub fn connect(ssl: *Self) !void {
        //
    }

    pub fn connectCleanup(ssl: Self) void {
        //
    }

    pub fn read(ssl: Self, buf: []u8) !usize {
        // warn("read\n", .{});
        // assert(ssl.socket_file != null);
        return 0;
    }

    // pub fn read(self: Self, buf: []u8) !usize {
    //     const ssl = self.ssl orelse return error.SSLIsNull;
    //     const len = @intCast(c_int, buf.len);
    //     const bytes = c.SSL_read(ssl, @ptrCast(*c_void, buf), len);
    //     if (bytes <= 0) {
    //         warn("SSL ERROR: {d}\n", .{c.SSL_get_error(ssl, bytes)});
    //         return error.SSLRead;
    //     }
    //     return @intCast(usize, bytes);
    // }

    pub fn write(ssl: Self, header_str: []u8) !usize {
        assert(ssl.socket_file != null);
        // ssl.client.relocate();
        // warn("test this\n", .{});
        // var bytes: usize = try ssl.stream.inStream().context.writeAll(header_str);
        // warn("bytes: {}\n", .{bytes});
        // while () {
        // }
        // try ssl.stream.flush();
        return 0;
    }

    // pub fn write(self: Self, header_str: []u8) !usize {
    //     const ssl = self.ssl orelse return error.SSLIsNull;
    //     const bytes = c.SSL_write(ssl, @ptrCast(*const c_void, header_str), @intCast(c_int, header_str.len));
    //     if (bytes <= 0) {
    //         warn("SSL ERROR: {d}\n", .{c.SSL_get_error(ssl, bytes)});
    //         return error.SSLRead;
    //     }
    //     return @intCast(usize, bytes);
    // }

    pub fn deinit(ssl: *Self) void {
        ssl.trust_anchor.deinit();
        if (ssl.socket_file) |f| f.close();
        ssl.stream.close() catch |err| {
            warn("ERROR: SSL stream was not terminated correctly\n", .{});
            warn("ERROR MSG: {s}\n", .{err});
        };
    }
};
