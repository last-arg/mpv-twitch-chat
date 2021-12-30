const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const log = std.log.default;
const expect = std.testing.expect;
const zfetch = @import("zfetch");

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
        try expect(mem.eql(u8, result, "855035286"));
    }
    {
        const url = "https://www.twitch.tv/videos/855035286?t=2h47m8s";
        const result = try urlToVideoId(url);
        try expect(mem.eql(u8, result, "855035286"));
    }
    // TODO: implement test where there is slash after video id and before '?'
}

pub fn requestComments(allocator: Allocator, video_id: []const u8, offset: f32) ![]const u8 {
    // Example: https://github.com/truemedian/zfetch/blob/master/examples/get.zig
    try zfetch.init();
    defer zfetch.deinit();

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();
    try headers.appendValue("Accept", "application/vnd.twitchtv.v5+json");
    try headers.appendValue("Connection", "close");
    try headers.appendValue("Host", "api.twitch.tv");
    try headers.appendValue("Client-ID", "yaoofm88l1kvv8i9zx7pyc44he2tcp");

    const path = "https://api.twitch.tv/v5/videos/{s}/comments?content_offset_seconds={d:.3}";
    var url = try ArrayList(u8).initCapacity(allocator, path.len + 20);
    defer url.deinit();
    try url.writer().print(path, .{ video_id, offset });

    var req = try zfetch.Request.init(allocator, url.items[0..], null);
    defer req.deinit();

    try req.do(.GET, headers, null);

    if (req.status.code != 200) {
        log.warn("Invalid status code {d} returned\n", .{req.status.code});
        return error.BadStatusCode;
    }

    var output = try ArrayList(u8).initCapacity(allocator, 50000);
    errdefer output.deinit();

    const reader = req.reader();

    var buf: [4096]u8 = undefined;
    while (true) {
        const read = try reader.read(&buf);
        if (read == 0) break;
        try output.appendSlice(buf[0..read]);
    }

    return output.toOwnedSlice();
}

test "httpsRequest" {
    const allocator = std.testing.allocator;
    const video_id = "1244017949";
    const offset = 2.00;
    const r = try requestComments(allocator, video_id, offset);
    defer allocator.free(r);
    try expect(r.len > 0);
}
