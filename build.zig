const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    // We need to manually prepend the sysroot since we are very naughty and we are using
    // Apple's private framework with no docs whatsoever.
    b.sysroot = null;
    const target_info = std.zig.system.NativeTargetInfo.detect(b.allocator, target) catch unreachable;
    const sdk = std.zig.system.darwin.getDarwinSDK(b.allocator, target_info.target) orelse {
        std.log.err("No SDK installed!", .{});
        return;
    };
    const sysroot = sdk.path;
    const normal_framework_search_dir = std.fmt.allocPrint(b.allocator, "{s}/System/Library/Frameworks", .{sysroot}) catch unreachable;
    const normal_lib_search_dir = std.fmt.allocPrint(b.allocator, "{s}/usr/lib", .{sysroot}) catch unreachable;

    const exe = b.addExecutable("zig-deploy", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addPackagePath("clap", "clap/clap.zig");
    exe.addPackagePath("ZigKit", "ZigKit/src/main.zig");
    exe.linkFramework("CoreFoundation");
    exe.linkFramework("MobileDevice");
    exe.addFrameworkPath(normal_framework_search_dir);
    exe.addFrameworkPath("/Library/Apple/System/Library/PrivateFrameworks");
    exe.addLibraryPath(normal_lib_search_dir);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
