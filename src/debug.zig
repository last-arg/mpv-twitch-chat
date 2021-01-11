const std = @import("std");

pub fn ttyWarn(comptime format: []const u8, args: anytype) void {
    const file = std.fs.cwd().openFile("/dev/pts/12", .{ .write = true }) catch unreachable;
    defer file.close();
    file.writer().print(format, args) catch unreachable;
}
