const std = @import("std");
const mem = std.mem;
const os = std.os;
const Allocator = std.mem.Allocator;
const net = std.net;
const log = std.log.default;
const warn = std.debug.warn;

pub const Mpv = struct {
    fd: os.fd_t,
    allocator: *Allocator,
    video_path: []const u8 = "",
    video_time: f64 = 0.0,

    const Self = @This();

    pub const Data = struct {
        data: ?union(enum) {
            String: []const u8,
            Float: f32,
        },
        request_id: usize, // Not used
        @"error": []const u8,
    };

    pub const Event = struct {
        event: []const u8,
    };

    pub const Command = struct {
        command: [][]const u8,
    };

    pub fn init(allocator: *Allocator, socket_path: []const u8) !Self {
        const socket_file = try net.connectUnixSocket(socket_path);
        errdefer os.close(socket_file.handle);

        var self = Self{
            .fd = socket_file.handle,
            .allocator = allocator,
        };

        // Set video path
        try self.requestProperty("path");
        try self.readResponses();
        // Set video playback time
        try self.requestProperty("playback-time");
        try self.readResponses();

        return self;
    }

    pub fn requestProperty(self: *Self, property: []const u8) !void {
        var get_property: []const u8 = "get_property";

        const cmd = Mpv.Command{
            .command = &[_][]const u8{ get_property, property },
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

        while (json_obj.next()) |json_str| {
            var stream = std.json.TokenStream.init(json_str);

            if (std.json.parse(Mpv.Data, &stream, .{ .allocator = self.allocator })) |resp| {
                defer std.json.parseFree(Mpv.Data, resp, .{ .allocator = self.allocator });

                if (!mem.eql(u8, "success", resp.@"error")) {
                    std.log.warn("WARN: Mpv json field error isn't success", .{});
                    continue;
                }

                if (resp.data) |data| {
                    switch (data) {
                        .String => |url| {
                            self.allocator.free(self.video_path);
                            self.video_path = try mem.dupe(self.allocator, u8, url);
                        },
                        .Float => |time| {
                            self.video_time = time;
                        },
                    }
                } else {
                    std.log.warn("WARN: Mpv json field data is null", .{});
                }
                continue;
            } else |err| {
                // warn("MPV Data Error: {}\n", .{err});
            }

            var stream_event = std.json.TokenStream.init(json_str);
            const resp = std.json.parse(Mpv.Event, &stream_event, .{
                .allocator = self.allocator,
            }) catch |err| {
                log.err("Failed to parse json string: '{s}'", .{json_str});
                continue;
            };
            defer std.json.parseFree(Mpv.Event, resp, .{ .allocator = self.allocator });
            std.log.info("EVENT: {s}", .{resp.event});
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
        const resp = try std.json.parse(Mpv.Data, &stream, .{ .allocator = std.testing.allocator });
        defer std.json.parseFree(Mpv.Data, resp, .{ .allocator = std.testing.allocator });
        std.testing.expect(resp.data.?.Float == 190.482000);
        std.testing.expect(mem.eql(u8, "success", resp.@"error"));
    }

    {
        const json_str =
            \\{"data":"/path/tosomewhere/","error":"success","request_id":0}
        ;

        var stream = std.json.TokenStream.init(json_str);
        const resp = try std.json.parse(Mpv.Data, &stream, .{ .allocator = std.testing.allocator });
        defer std.json.parseFree(Mpv.Data, resp, .{ .allocator = std.testing.allocator });
        std.testing.expect(mem.eql(u8, "/path/tosomewhere/", resp.data.?.String));
        std.testing.expect(mem.eql(u8, "success", resp.@"error"));
    }

    {
        const json_str =
            \\{"data":null,"error":"success","request_id":0}
        ;

        var stream = std.json.TokenStream.init(json_str);
        const resp = try std.json.parse(Mpv.Data, &stream, .{ .allocator = std.testing.allocator });
        defer std.json.parseFree(Mpv.Data, resp, .{ .allocator = std.testing.allocator });
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
        };

        var buf: [100]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        var result_str = std.ArrayList(u8).init(&fba.allocator);
        try std.json.stringify(cmd, .{}, result_str.writer());

        std.testing.expect(mem.eql(u8, result_str.items,
            \\{"command":["get_property","playback-time"]}
        ));
    }
}
