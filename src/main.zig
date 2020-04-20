const std = @import("std");
const warn = std.debug.warn;

pub fn main() anyerror!void {
    std.debug.warn("All your codebase are belong to us.\n", .{});
}
