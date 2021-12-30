const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const mem = std.mem;
const log = std.log.default;
const expect = std.testing.expect;
const zfetch = @import("zfetch");

pub fn urlToVideoId(url: []const u8) ![]const u8 {
    var end_index = mem.lastIndexOfScalar(u8, url, '?') orelse url.len;
    const trimmed_right = mem.trimRight(u8, url[0..end_index], "/");
    const start_index = (mem.lastIndexOfScalar(u8, trimmed_right, '/') orelse return error.InvalidUrl) + 1;

    return trimmed_right[start_index..];
}

test "urlToVideoId" {
    const urls: []const []const u8 = &.{
        "https://www.twitch.tv/videos/855035286",
        "https://www.twitch.tv/videos/855035286?t=2h47m8s",
        "https://www.twitch.tv/videos/855035286//?t=2h47m8s",
    };
    for (urls) |url| {
        const result = try urlToVideoId(url);
        try expect(mem.eql(u8, result, "855035286"));
    }
}

pub fn requestComments(allocator: Allocator, video_id: []const u8, offset: f64) ![]const u8 {
    // Example: https://github.com/truemedian/zfetch/blob/master/examples/get.zig
    var buf: [4096]u8 = undefined;
    try zfetch.init();
    defer zfetch.deinit();

    var headers = zfetch.Headers.init(allocator);
    defer headers.deinit();
    try headers.appendValue("Accept", "application/vnd.twitchtv.v5+json");
    try headers.appendValue("Connection", "close");
    try headers.appendValue("Host", "api.twitch.tv");
    try headers.appendValue("Client-ID", "yaoofm88l1kvv8i9zx7pyc44he2tcp");

    const path_fmt = "https://api.twitch.tv/v5/videos/{s}/comments?content_offset_seconds={d:.3}";
    const url = try std.fmt.bufPrint(&buf, path_fmt, .{ video_id, offset });
    var req = try zfetch.Request.init(allocator, url, null);
    defer req.deinit();

    try req.do(.GET, headers, null);

    if (req.status.code != 200) {
        log.warn("Invalid status code {d} returned\n", .{req.status.code});
        return error.BadStatusCode;
    }

    var output = try ArrayList(u8).initCapacity(allocator, 50000);
    errdefer output.deinit();

    const reader = req.reader();

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
