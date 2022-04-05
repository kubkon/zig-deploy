const std = @import("std");
const assert = std.debug.assert;
const log = std.log;
const mem = std.mem;

const Allocator = mem.Allocator;

// TODO we can actually read this from the bundle's Info.plist
const BUNDLE_ID: []const u8 = "com.jakubkonka.madewithzig";

pub var state: State = .{};

pub const State = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}) = .{},
    notify: *AmDeviceNotification = undefined,
    device: ?*AmDevice = null,
    name: ?[]const u8 = null,
    bundle_path: ?[]const u8 = null,
};

extern "c" fn CFRelease(*anyopaque) void;

const ADNCI_MSG_CONNECTED = 1;
const ADNCI_MSG_DISCONNECTED = 2;
const ADNCI_MSG_UNKNOWN = 3;

const AmDeviceNotificationCallbackInfo = extern struct {
    device: *AmDevice,
    msg: u32,
};

const AmDevice = extern struct {
    unknown_0: [16]u8,
    device_id: u32,
    product_id: u32,
    serial: [4]u8,
    unknown_1: u32,
    unknown_2: [4]u8,
    lockdown_conn: u32,
    unknown_3: [8]u8,

    fn deinit(self: *AmDevice) void {
        AMDeviceRelease(self);
    }

    fn connect(self: *AmDevice) !void {
        switch (AMDeviceConnect(self)) {
            0 => {},
            else => |e| {
                log.err("couldn't connect to device with error: {d}", .{e});
                log.err("  device: {}", .{self.*});
                return error.ConnectFailed;
            },
        }
    }

    fn disconnect(self: *AmDevice) !void {
        switch (AMDeviceDisconnect(self)) {
            0 => {},
            else => |e| {
                log.err("couldn't disconnect from device with error: {d}", .{e});
                log.err("  device: {}", .{self.*});
                return error.DisconnectFailed;
            },
        }
    }

    fn isPaired(self: *AmDevice) bool {
        return AMDeviceIsPaired(self) == 1;
    }

    fn getName(self: *AmDevice, allocator: Allocator) ![]const u8 {
        const key = stringFromBytes("DeviceName");
        defer key.deinit();
        const cfstr = AMDeviceCopyValue(self, null, key);
        defer cfstr.deinit();
        return cfstr.cstr(allocator);
    }

    fn getInterfaceType(self: *AmDevice) IntefaceType {
        return @intToEnum(IntefaceType, AMDeviceGetInterfaceType(self));
    }

    fn secureTransferPath(self: *AmDevice, url: Url, opts: DictRef) !void {
        switch (AMDeviceSecureTransferPath(0, self, url, opts, transferCallback, 0)) {
            0 => {},
            else => |e| {
                log.err("secure transfer path failed with error: {d}", .{e});
                return error.SecureTransferPathFailed;
            },
        }
    }

    fn secureInstallApplication(self: *AmDevice, url: Url, opts: DictRef) !void {
        switch (AMDeviceSecureInstallApplication(0, self, url, opts, installCallback, 0)) {
            0 => {},
            else => |e| {
                log.err("secure install application failed with error: {d}", .{e});
                return error.SecureInstallApplicationFailed;
            },
        }
    }

    fn validatePairing(self: *AmDevice) !void {
        switch (AMDeviceValidatePairing(self)) {
            0 => {},
            else => |e| {
                log.err("failed to validate pairing with the device with error: {d}", .{e});
                return error.ValidatePairingFailed;
            },
        }
    }

    fn startSession(self: *AmDevice) !void {
        switch (AMDeviceStartSession(self)) {
            0 => {},
            else => |e| {
                log.err("failed to start session with the device with error: {d}", .{e});
                return error.StartSessionFailed;
            },
        }
    }

    fn stopSession(self: *AmDevice) !void {
        switch (AMDeviceStopSession(self)) {
            0 => {},
            else => |e| {
                log.err("failed to stop session with the device with error: {d}", .{e});
                return error.StopSessionFailed;
            },
        }
    }

    fn installBundle(self: *AmDevice, allocator: Allocator, bundle_id: []const u8, bundle_path: []const u8) !void {
        log.debug("will install bundle...", .{});

        const path = stringFromBytes(bundle_path);
        defer path.deinit();
        const rel_url = CFURLCreateWithFileSystemPath(null, path, .posix, false);
        defer rel_url.deinit();
        const url = CFURLCopyAbsoluteURL(rel_url);
        defer url.deinit();

        const keys = &[_]String{stringFromBytes("PackageType")};
        const values = &[_]String{stringFromBytes("Developer")};
        const opts = CFDictionaryCreate(
            null,
            @ptrCast([*]*const anyopaque, keys),
            @ptrCast([*]*const anyopaque, values),
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        );
        defer opts.deinit();

        try self.secureTransferPath(url, opts);

        try self.connect();
        defer self.disconnect() catch {};

        assert(self.isPaired());
        try self.validatePairing();

        try self.startSession();
        defer self.stopSession() catch {};

        try self.secureInstallApplication(url, opts);

        const bid = stringFromBytes(bundle_id);
        defer bid.deinit();

        const app_url = try self.copyDeviceAppUrl(bid);
        if (app_url) |u| {
            const raw_str = CFURLCopyFileSystemPath(u, .posix);
            const installed_path = try raw_str.cstr(allocator);
            defer allocator.free(installed_path);
            log.warn("installed_path = {s}", .{installed_path});
        }
    }

    fn copyDeviceAppUrl(self: *AmDevice, bundle_id: String) !?Url {
        var out: DictRef = undefined;
        defer out.deinit();

        const value_obj = CFArrayCreate(null, @ptrCast([*]*const anyopaque, &[_]String{
            stringFromBytes("CFBundleIdentifier"),
            stringFromBytes("Path"),
        }), 2, &kCFTypeArrayCallBacks);
        defer value_obj.deinit();

        const values = &[_]ArrayRef{value_obj};
        const keys = &[_]String{stringFromBytes("ReturnAttributes")};
        const opts = CFDictionaryCreate(
            null,
            @ptrCast([*]*const anyopaque, keys),
            @ptrCast([*]*const anyopaque, values),
            1,
            &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks,
        );
        defer opts.deinit();

        switch (AMDeviceLookupApplications(self, opts, &out)) {
            0 => {},
            else => |e| {
                log.err("failed to lookup applications on device with error: {d}", .{e});
                return error.LookupApplicationsFailed;
            },
        }

        const raw_app_info = out.getValue(bundle_id) orelse return null;
        const app_dict = @ptrCast(DictRef, raw_app_info);
        const raw_path = app_dict.getValue(stringFromBytes("Path")).?;
        const path = @ptrCast(String, raw_path);
        const url = CFURLCreateWithFileSystemPath(null, path, .posix, true);
        return url;
    }

    extern "c" fn AMDeviceRelease(device: *AmDevice) void;
    extern "c" fn AMDeviceConnect(device: *AmDevice) c_int;
    extern "c" fn AMDeviceDisconnect(device: *AmDevice) c_int;
    extern "c" fn AMDeviceIsPaired(device: *AmDevice) c_int;
    extern "c" fn AMDeviceValidatePairing(device: *AmDevice) c_int;
    extern "c" fn AMDeviceStartSession(device: *AmDevice) c_int;
    extern "c" fn AMDeviceStopSession(device: *AmDevice) c_int;
    extern "c" fn AMDeviceCopyValue(device: *AmDevice, ?*anyopaque, key: String) String;
    extern "c" fn AMDeviceGetInterfaceType(device: *AmDevice) c_int;
    extern "c" fn AMDeviceSecureTransferPath(
        c_int,
        device: *AmDevice,
        url: Url,
        opts: DictRef,
        cb: GenericCallback,
        cbarg: c_int,
    ) c_int;
    extern "c" fn AMDeviceSecureInstallApplication(c_int, device: *AmDevice, url: Url, opts: DictRef, cb: GenericCallback, cbarg: c_int) c_int;
    extern "c" fn AMDeviceLookupApplications(device: *AmDevice, opts: DictRef, out: *DictRef) c_int;

    extern "c" fn CFURLCreateWithFileSystemPath(?*anyopaque, path: String, path_style: PathStyle, is_dir: bool) Url;
    extern "c" fn CFURLCopyAbsoluteURL(Url) Url;
    extern "c" fn CFURLCopyFileSystemPath(Url, PathStyle) String;
};

const GenericCallback = fn (DictRef, c_int) callconv(.C) c_int;

fn transferCallback(dict: DictRef, arg: c_int) callconv(.C) c_int {
    _ = arg;
    const gpa = state.gpa.allocator();

    if (dict.getValue(stringFromBytes("Error"))) |_| {
        log.err("error while transferring...", .{});
        return 0;
    }

    if (dict.getValue(stringFromBytes("Status"))) |cf_status| {
        const status = @ptrCast(String, cf_status).cstr(gpa) catch unreachable;
        defer gpa.free(status);

        log.debug("transfer status: {s}", .{status});
    }

    return 0;
}

fn installCallback(dict: DictRef, arg: c_int) callconv(.C) c_int {
    _ = arg;
    const gpa = state.gpa.allocator();

    if (dict.getValue(stringFromBytes("Error"))) |_| {
        log.err("error while installing...", .{});
        return 0;
    }

    if (dict.getValue(stringFromBytes("Status"))) |cf_status| {
        const status = @ptrCast(String, cf_status).cstr(gpa) catch unreachable;
        defer gpa.free(status);

        log.debug("install status: {s}", .{status});
    }

    return 0;
}

pub const Url = *opaque {
    fn deinit(self: Url) void {
        CFRelease(self);
    }
};

const PathStyle = enum(usize) {
    posix = 0,
    hfs,
    windows,
};

const IntefaceType = enum(isize) {
    usb = 1,
    wifi,
    companion,
    _,
};

const Identity = struct {
    name: []const u8,
    conn_type: IntefaceType,
};
fn identifyDevice(gpa: Allocator, device: *AmDevice) !Identity {
    try device.connect();
    defer device.disconnect() catch {};

    const identity: Identity = .{
        .name = try device.getName(gpa),
        .conn_type = device.getInterfaceType(),
    };

    log.debug("found device: {s} @ {}", .{ identity.name, identity.conn_type });

    return identity;
}

fn deviceCallback(info: *AmDeviceNotificationCallbackInfo, arg: ?*anyopaque) callconv(.C) void {
    _ = arg;
    const gpa = state.gpa.allocator();

    switch (info.msg) {
        ADNCI_MSG_CONNECTED => {
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
            state.device.?.installBundle(gpa, BUNDLE_ID, state.bundle_path.?) catch unreachable;
        },
        ADNCI_MSG_DISCONNECTED => {
            log.debug("disconnected", .{});
        },
        else => {
            log.debug("callback unknown msg={d}", .{info.msg});
        },
    }
}

const AmDeviceNotification = extern struct {
    unknown_0: u32,
    unknown_1: u32,
    unknown_2: u32,
    callback: AmDeviceNotificationCallback,
    unknown_3: u32,
};

const AmDeviceNotificationCallback = fn (*AmDeviceNotificationCallbackInfo, ?*anyopaque) callconv(.C) void;

extern "c" fn AMDeviceNotificationSubscribeWithOptions(
    callback: AmDeviceNotificationCallback,
    u32,
    u32,
    ?*anyopaque,
    notification: **AmDeviceNotification,
    options: ?DictRef,
) c_int;

pub fn deviceNotificationSubscribe() !void {
    const keys = &[_]String{stringFromBytes("NotificationOptionSearchForPairedDevices")};
    const values = &[_]Boolean{kCFBooleanTrue};
    const opts = CFDictionaryCreate(
        null,
        @ptrCast([*]*const anyopaque, keys),
        @ptrCast([*]*const anyopaque, values),
        1,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    );
    defer opts.deinit();

    if (AMDeviceNotificationSubscribeWithOptions(deviceCallback, 0, 0, null, &state.notify, opts) != 0) {
        return error.Failed;
    }
}

fn stringFromBytes(bytes: []const u8) String {
    return CFStringCreateWithBytes(null, bytes.ptr, bytes.len, UTF8_ENCODING, false);
}

extern "c" fn CFStringCreateWithBytes(
    allocator: ?*anyopaque,
    bytes: [*]const u8,
    len: usize,
    encooding: u32,
    is_extern: bool,
) String;

const String = *opaque {
    fn deinit(self: String) void {
        CFRelease(self);
    }

    /// Caller owns return memory.
    fn cstr(self: String, allocator: Allocator) error{OutOfMemory}![]u8 {
        if (CFStringGetCStringPtr(self, UTF8_ENCODING)) |ptr| {
            const c_str = mem.sliceTo(@ptrCast([*:0]const u8, ptr), 0);
            return allocator.dupe(u8, c_str);
        }

        const buf_size = 1024;
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try buf.resize(buf_size);

        while (!CFStringGetCString(self, buf.items.ptr, buf.items.len, UTF8_ENCODING)) {
            try buf.resize(buf.items.len + buf_size);
        }

        const len = mem.sliceTo(@ptrCast([*:0]const u8, buf.items.ptr), 0).len;
        try buf.resize(len);

        return buf.toOwnedSlice();
    }

    extern "c" fn CFStringGetLength(str: String) usize;
    extern "c" fn CFStringGetCStringPtr(str: String, encoding: u32) ?*const u8;
    extern "c" fn CFStringGetCString(str: String, buffer: [*]u8, size: usize, encoding: u32) bool;
};

const UTF8_ENCODING: u32 = 0x8000100;

const DictKeyCallBacks = opaque {};
const DictValueCallBacks = opaque {};

extern "c" var kCFTypeDictionaryKeyCallBacks: DictKeyCallBacks;
extern "c" var kCFTypeDictionaryValueCallBacks: DictValueCallBacks;

extern "c" fn CFDictionaryCreate(
    allocator: ?*anyopaque,
    keys: [*]*const anyopaque,
    values: [*]*const anyopaque,
    num_values: usize,
    key_cb: *const DictKeyCallBacks,
    value_cb: *const DictValueCallBacks,
) DictRef;

const DictRef = *opaque {
    fn deinit(self: DictRef) void {
        CFRelease(self);
    }

    fn getValue(self: DictRef, key: *anyopaque) ?*anyopaque {
        return CFDictionaryGetValue(self, key);
    }
};

extern "c" fn CFDictionaryGetValue(d: DictRef, key: *anyopaque) ?*anyopaque;

const Boolean = *opaque {};

extern "c" var kCFBooleanTrue: Boolean;

pub fn runLoop() void {
    CFRunLoopRun();
}

extern "c" fn CFRunLoopRun() void;

const ArrayRef = *opaque {
    fn deinit(self: ArrayRef) void {
        CFRelease(self);
    }
};

const ArrayCallBacks = opaque {};

extern "c" var kCFTypeArrayCallBacks: ArrayCallBacks;

extern "c" fn CFArrayCreate(
    allocator: ?*anyopaque,
    values: [*]*const anyopaque,
    len: usize,
    cbs: *const ArrayCallBacks,
) ArrayRef;
