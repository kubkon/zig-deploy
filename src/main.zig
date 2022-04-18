const std = @import("std");
const clap = @import("clap");
const io = std.io;
const log = std.log;
const mem = std.mem;

const Allocator = mem.Allocator;
const ZigKit = @import("ZigKit");
const CoreFoundation = ZigKit.CoreFoundation;
const MobileDevice = ZigKit.private.MobileDevice;

const AMDevice = MobileDevice.AMDevice;
const CFBoolean = CoreFoundation.CFBoolean;
const CFDictionary = CoreFoundation.CFDictionary;
const CFString = CoreFoundation.CFString;
const CFUrl = CoreFoundation.CFUrl;

// TODO we can actually read this from the bundle's Info.plist
const BUNDLE_ID: []const u8 = "com.jakubkonka.madewithzig";

var state: State = .{};

const State = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}) = .{},
    notify: *MobileDevice.AMDeviceNotification = undefined,
    device: ?*MobileDevice.AMDevice = null,
    name: ?[]const u8 = null,
    bundle_path: ?[]const u8 = null,
};

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
        state.name = name;
    }

    state.bundle_path = res.positionals[0];

    try deviceNotificationSubscribe();
    CFRunLoopRun();
}

fn deviceNotificationSubscribe() !void {
    const keys = &[_]*CFString{CFString.createWithBytes("NotificationOptionSearchForPairedDevices")};
    const values = &[_]*CFBoolean{CFBoolean.@"true"()};
    const opts = try CFDictionary.create(CFString, CFBoolean, keys, values);
    defer opts.release();
    state.notify = try MobileDevice.subscribe(deviceCallback, opts);
}

extern "c" fn CFRunLoopRun() void;

fn transferCallback(dict: *CFDictionary, arg: c_int) callconv(.C) c_int {
    _ = arg;
    const gpa = state.gpa.allocator();

    if (dict.getValue(CFString, void, CFString.createWithBytes("Error"))) |_| {
        log.err("error while transferring...", .{});
        return 0;
    }

    if (dict.getValue(CFString, CFString, CFString.createWithBytes("Status"))) |cf_status| {
        const status = cf_status.cstr(gpa) catch unreachable;
        defer gpa.free(status);

        log.debug("transfer status: {s}", .{status});
    }

    return 0;
}

fn installCallback(dict: *CFDictionary, arg: c_int) callconv(.C) c_int {
    _ = arg;
    const gpa = state.gpa.allocator();

    if (dict.getValue(CFString, void, CFString.createWithBytes("Error"))) |_| {
        log.err("error while installing...", .{});
        return 0;
    }

    if (dict.getValue(CFString, CFString, CFString.createWithBytes("Status"))) |cf_status| {
        const status = cf_status.cstr(gpa) catch unreachable;
        defer gpa.free(status);

        log.debug("install status: {s}", .{status});
    }

    return 0;
}

const Identity = struct {
    name: []const u8,
    conn_type: MobileDevice.IntefaceType,
};
fn identifyDevice(gpa: Allocator, device: *AMDevice) !Identity {
    try device.connect();
    defer device.disconnect() catch {};

    const identity: Identity = .{
        .name = try device.getName(gpa),
        .conn_type = device.getInterfaceType(),
    };

    log.debug("found device: {s} @ {}", .{ identity.name, identity.conn_type });

    return identity;
}

fn deviceCallback(info: *MobileDevice.AMDeviceNotificationCallbackInfo, arg: ?*anyopaque) callconv(.C) void {
    _ = arg;
    const gpa = state.gpa.allocator();

    switch (@intToEnum(MobileDevice.ADNCI_MSG, info.msg)) {
        .CONNECTED => {
            const ident = identifyDevice(gpa, info.device) catch unreachable;
            defer gpa.free(ident.name);

            if (state.device) |_| return;

            if (state.name) |name| {
                if (mem.eql(u8, ident.name, name) and ident.conn_type == .usb) {
                    state.device = info.device;
                } else return;
            } else {
                if (ident.conn_type == .usb) {
                    state.device = info.device;
                    state.name = gpa.dupe(u8, ident.name) catch unreachable;
                } else return;
            }

            log.debug("connected to {s}!", .{ident.name});
            log.debug("installing {s} @ {s}", .{ BUNDLE_ID, state.bundle_path });
            state.device.?.installBundle(state.bundle_path.?, transferCallback, installCallback) catch unreachable;

            const app_url = state.device.?.copyDeviceAppUrl(gpa, BUNDLE_ID) catch unreachable;
            if (app_url) |path| {
                defer gpa.free(path);
                log.debug("installed URL {s}", .{path});
            } else {
                log.debug("app with bundle id '{s}' not found", .{BUNDLE_ID});
            }
        },
        .DISCONNECTED => {
            log.debug("disconnected", .{});
        },
        else => {
            log.debug("callback unknown msg={d}", .{info.msg});
        },
    }
}
