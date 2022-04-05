const clap = @import("clap");
const md = @import("md.zig");

const std = @import("std");
const io = std.io;

pub fn main() !void {
    const stderr = io.getStdErr().writer();

    const params = comptime [_]clap.Param(clap.Help){
        clap.parseParam("-h, --help                   Display this help and exit.") catch unreachable,
        clap.parseParam("-n, --name <STR>             Name of the device to connect to.") catch unreachable,
        clap.parseParam("<PATH>") catch unreachable,
    };

    const parsers = comptime .{
        .STR = clap.parsers.string,
        .PATH = clap.parsers.string,
    };

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help) {
        return clap.help(stderr, clap.Help, &params, .{});
    }

    if (res.args.name) |name| {
        md.state.name = name;
    }

    md.state.bundle_path = res.positionals[0];

    try md.deviceNotificationSubscribe();
    md.runLoop();
}
