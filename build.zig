const std = @import("std");
const Builder = std.build.Builder;
// const pkgs = @import("deps.zig").pkgs; // gyro
const deps = @import("deps.zig"); // zigmod

pub fn build(b: *Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("mpv-vod-chat", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.linkLibC();
    exe.linkSystemLibrary("notcurses");
    deps.addAllTo(exe);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var test_file = blk: {
        if (b.args) |args| {
            break :blk args[0];
        }
        break :blk "src/main.zig";
    };
    var file_test = b.addTest(test_file);
    file_test.setBuildMode(mode);
    file_test.linkLibC();
    deps.addAllTo(file_test);

    const test_step = b.step("test", "Run file tests");
    test_step.dependOn(&file_test.step);
}
