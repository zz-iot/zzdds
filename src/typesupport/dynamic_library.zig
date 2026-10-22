//! OS loading only. Generation ownership and descriptor validation live in library.zig.
//! Paths are absolute and NUL-free; candidate artifacts must remain immutable.
const std = @import("std");
const builtin = @import("builtin");
const enabled = @import("build_options").typesupport_dynamic;

pub const available = enabled and switch (builtin.os.tag) {
    .linux, .macos, .windows => true,
    else => false,
};
pub const Library = if (!enabled) Disabled else switch (builtin.os.tag) {
    .linux, .macos => Posix,
    .windows => Windows,
    else => Disabled,
};

fn checkPath(path: []const u8) !void {
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidLibraryPath;
    if (!std.fs.path.isAbsolute(path)) return error.AbsoluteLibraryPathRequired;
    // A rooted Windows path (\foo) still depends on the current drive.
    if (builtin.os.tag == .windows and std.fs.path.diskDesignatorWindows(path).len == 0)
        return error.AbsoluteLibraryPathRequired;
}
const Disabled = struct {
    pub fn open(_: std.mem.Allocator, _: []const u8) !Disabled {
        return error.DynamicLoadingUnavailable;
    }
    pub fn lookup(_: *Disabled, comptime T: type, _: [:0]const u8) ?T {
        return null;
    }
    pub fn close(_: *Disabled) void {}
};
const Posix = struct {
    handle: std.DynLib,
    pub fn open(_: std.mem.Allocator, path: []const u8) !Posix {
        try checkPath(path);
        return .{ .handle = try std.DynLib.open(path) };
    }
    pub fn lookup(self: *Posix, comptime T: type, name: [:0]const u8) ?T {
        return self.handle.lookup(T, name);
    }
    pub fn close(self: *Posix) void {
        self.handle.close();
        self.* = undefined;
    }
};
const Windows = struct {
    const win = std.os.windows;
    extern "kernel32" fn LoadLibraryExW(path: [*:0]const u16, file: ?win.HANDLE, flags: u32) callconv(.winapi) ?win.HMODULE;
    extern "kernel32" fn GetProcAddress(module: win.HMODULE, name: [*:0]const u8) callconv(.winapi) ?win.FARPROC;
    extern "kernel32" fn FreeLibrary(module: win.HMODULE) callconv(.winapi) win.BOOL;
    handle: win.HMODULE,
    pub fn open(alloc: std.mem.Allocator, path: []const u8) !Windows {
        try checkPath(path);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
        defer alloc.free(wide);
        // Dependencies resolve beside this DLL or in System32. Do not search
        // the working directory, PATH, or mutate process-global DLL search state.
        const search_dll_load_dir = 0x00000100;
        const search_system32 = 0x00000800;
        const handle = LoadLibraryExW(wide, null, search_dll_load_dir | search_system32) orelse return switch (win.GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND, .MOD_NOT_FOUND => error.LibraryOrDependencyNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            .BAD_EXE_FORMAT => error.InvalidLibraryFormat,
            else => error.LibraryOpenFailed,
        };
        return .{ .handle = handle };
    }
    pub fn lookup(self: *Windows, comptime T: type, name: [:0]const u8) ?T {
        return @ptrCast(GetProcAddress(self.handle, name) orelse return null);
    }
    pub fn close(self: *Windows) void {
        // Every successfully opened module owns exactly one OS reference.
        const result = FreeLibrary(self.handle);
        std.debug.assert(result.toBool());
        self.* = undefined;
    }
};
