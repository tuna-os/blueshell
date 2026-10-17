const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const Pty = @import("../pty.zig").Pty;
const ProcessInfo = @import("../pty.zig").ProcessInfo;
const windows = @import("../os/main.zig").windows;

const log = std.log.scoped(.io_adopt);

/// The kinds of backends.
pub const Kind = enum { exec, adopt };

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,

    /// Adopt uses a PTY master created by an external process.
    adopt: Adopt.Config,
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    adopt: Adopt,

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .adopt => |*adopt| adopt.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .adopt => |*adopt| adopt.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
            .adopt => |*adopt| try adopt.threadEnter(io, td),
        }
    }

    pub fn threadExit(self: *Backend, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(td),
            .adopt => |*adopt| adopt.threadExit(td),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .adopt => try termio.Exec.focusGainedPty(td, focused),
        }
    }

    pub fn resize(
        self: *Backend,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.resize(grid_size, screen_size),
            .adopt => |*adopt| try adopt.resize(grid_size, screen_size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .adopt => try termio.Exec.queueWritePty(alloc, td, data, linefeed),
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .adopt => unreachable,
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .adopt => |*adopt| adopt.getProcessInfo(info),
        };
    }
};

/// Termio backend for an externally-created PTY master.
pub const Adopt = struct {
    master_fd: Pty.Fd,
    pty: if (builtin.os.tag == .windows) void else Pty,

    pub const Config = struct {
        master_fd: Pty.Fd,
    };

    pub fn init(config: Adopt.Config) Adopt {
        return .{
            .master_fd = config.master_fd,
            .pty = if (comptime builtin.os.tag == .windows) {} else .{
                .master = config.master_fd,
                .slave = -1,
            },
        };
    }

    pub fn deinit(self: *Adopt) void {
        if (comptime builtin.os.tag == .windows) {
            _ = windows.exp.kernel32.CloseHandle(self.master_fd);
        } else {
            self.pty.deinit();
        }
        self.* = undefined;
    }

    pub fn initTerminal(self: *Adopt, t: *terminal.Terminal) void {
        self.resize(
            .{ .columns = t.cols, .rows = t.rows },
            .{ .width = t.width_px, .height = t.height_px },
        ) catch |err| {
            log.warn("failed to set size on adopted pty err={}", .{err});
        };
    }

    pub fn threadEnter(
        self: *Adopt,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        try termio.Exec.threadEnterPty(
            .{ .read = self.master_fd, .write = self.master_fd },
            null,
            io,
            td,
            .adopt,
        );
    }

    pub fn threadExit(_: *Adopt, td: *termio.Termio.ThreadData) void {
        termio.Exec.threadExitPty(td);
    }

    pub fn resize(
        self: *Adopt,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        if (comptime builtin.os.tag == .windows) {
            return error.OperationNotSupported;
        } else {
            try self.pty.setSize(.{
                .ws_row = std.math.cast(u16, grid_size.rows) orelse std.math.maxInt(u16),
                .ws_col = std.math.cast(u16, grid_size.columns) orelse std.math.maxInt(u16),
                .ws_xpixel = std.math.cast(u16, screen_size.width) orelse std.math.maxInt(u16),
                .ws_ypixel = std.math.cast(u16, screen_size.height) orelse std.math.maxInt(u16),
            });
        }
    }

    pub fn getProcessInfo(
        self: *Adopt,
        comptime info: ProcessInfo,
    ) ?ProcessInfo.Type(info) {
        if (comptime builtin.os.tag == .windows) return null;
        return self.pty.getProcessInfo(info);
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    adopt: termio.Exec.ThreadData,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .adopt => |*adopt| adopt.deinit(alloc),
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};
