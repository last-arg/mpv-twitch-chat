const std = @import("std");
const warn = std.debug.warn;
const fmt = std.fmt;
const Mpv = @import("mpv.zig").Mpv;
const Comments = @import("comments.zig").Comments;
const t = @import("twitch.zig");
const Twitch = t.Twitch;

// TODO: non-blocking mode messes up openssl functions.
// https://stackoverflow.com/a/31174268
// SSL_pending()
// https://groups.google.com/forum/#!msg/mailing.openssl.users/nJRF_JVnPkc/377tgaE4sRgJ
// pub const io_mode = .evented;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = &gpa.allocator;
    const stdout = std.io.getStdOut().outStream();

    var arg_it = std.process.args();
    _ = arg_it.skip();
    const chat_offset = blk: {
        if (arg_it.nextPosix()) |value| {
            break :blk try fmt.parseFloat(f64, value);
        }
        warn("No CLI arguments.\n", .{});
        break :blk 0.0;
    };

    warn("==> Connect to MPV socket\n", .{});
    var mpv = try Mpv.init(allocator, "/tmp/mpv-twitch-socket");
    defer mpv.deinit();

    // const video_id = try t.urlToVideoId(mpv.video_path);
    const video_id = "762169747";

    const twitch = Twitch.init(allocator, video_id);
    // defer twitch.deinit();
    // warn("{}\n", .{twitch});

    warn("==> Download comments\n", .{});
    var chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;
    const comments_json = try twitch.requestCommentsJson(chat_time);
    defer twitch.allocator.free(comments_json);
    // const comments_json = @embedFile("../test/skadoodle-chat.json");
    var comments = try Comments.init(allocator, comments_json, chat_offset);
    defer comments.deinit();

    while (true) {
        try mpv.requestProperty("playback-time");
        try mpv.readResponses();

        chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;
        while (try comments.nextCommentString(chat_time)) |str| {
            try stdout.writeAll(str);
        }

        const first_offset = comments.offsets[0] - chat_offset;
        const last_offset = comments.offsets[comments.offsets.len - 1] - chat_offset;
        if ((!comments.is_first and mpv.video_time < first_offset) or
            (!comments.is_last and mpv.video_time > last_offset))
        {
            chat_time = if (mpv.video_time < chat_offset) 0.0 else mpv.video_time - chat_offset;
            warn("==> Download new comments\n", .{});
            const new_json = try twitch.requestCommentsJson(chat_time);
            comments.deinit();
            try comments.parse(new_json);

            comments.skipToNextIndex(chat_time);

            continue;
        }

        std.time.sleep(std.time.ns_per_s * 0.5);
    }
}
