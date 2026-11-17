//! Agent awareness (RFC #22): the GTK half of the herdr-style agent
//! integration. One `AgentWatch` per surface runs a periodic tick that
//! inspects the pty's foreground process, samples the viewport for
//! activity, feeds `agent_monitor.next()` and applies the side effects
//! (tab badge, desktop notification, background tint).
//!
//! This is fork-owned code. It lives outside `surface.zig` so that the
//! upstream file only carries the call sites, a timer trampoline and one
//! `Private` field (see UPSTREAM_SYNC.md, "Additions over modifications").
//! The pure state machine and pattern tables are in `agent_monitor.zig`.

const std = @import("std");
const builtin = @import("builtin");
const glib = @import("glib");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const CoreSurface = @import("../../../Surface.zig");
const global = @import("../../../global.zig");
const i18n = @import("../../../os/i18n.zig");
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const agent_monitor = @import("agent_monitor.zig");

const log = std.log.scoped(.gtk_ghostty_surface);

/// Milliseconds between agent monitor ticks. Two seconds mirrors herdr's
/// sampling rate; agent_monitor.quiet_threshold is expressed in these
/// ticks.
pub const tick_ms = 2 * std.time.ms_per_s;

/// Per-surface agent monitor state. A surface embeds one of these in its
/// private data. The timer runs only while `agent-detect` is non-empty.
pub const AgentWatch = struct {
    timer: ?c_uint = null,
    state: agent_monitor.State = .none,
    seen: bool = false,
    screen_hash: u64 = 0,
    quiet_ticks: u32 = 0,
    name: [32]u8 = undefined,
    name_len: u8 = 0,

    /// Start ticking when the feature is enabled and no timer runs yet.
    /// The disabled case is handled inside `tick`, which notices the
    /// empty list, resets state, and asks to be removed. `callback` is
    /// the surface's trampoline that forwards to `tick`.
    pub fn start(
        self: *AgentWatch,
        surface: *Surface,
        config: *const configpkg.Config,
        callback: glib.SourceFunc,
    ) void {
        if (config.@"agent-detect".list.items.len == 0) return;
        if (self.timer != null) return;
        self.timer = glib.timeoutAdd(tick_ms, callback, surface);
    }

    /// Remove the timer, if any. Called when the surface is disposed.
    pub fn stop(self: *AgentWatch) void {
        if (self.timer) |timer| {
            if (glib.Source.remove(timer) == 0) {
                log.warn("unable to remove agent timer", .{});
            }
            self.timer = null;
        }
    }

    /// Looking at a finished agent acknowledges it.
    pub fn acknowledge(
        self: *AgentWatch,
        surface: *Surface,
        config: ?*const configpkg.Config,
    ) void {
        if (self.state != .done) return;
        self.seen = false;
        self.setState(surface, config, .none);
    }

    /// One agent monitor tick: inspect the pty's foreground process,
    /// sample the viewport for activity, advance the state machine, and
    /// apply any side effects (badge, notification, tint). Returns a
    /// glib source result: `SOURCE_REMOVE` once the feature is off.
    pub fn tick(
        self: *AgentWatch,
        surface: *Surface,
        config: *const configpkg.Config,
    ) c_int {
        const names = config.@"agent-detect".list.items;
        if (names.len == 0) {
            // Feature was turned off: reset and stop ticking.
            self.timer = null;
            self.seen = false;
            self.screen_hash = 0;
            self.quiet_ticks = 0;
            self.setState(surface, config, .none);
            return @intFromBool(glib.SOURCE_REMOVE);
        }

        const core_surface = surface.core() orelse
            return @intFromBool(glib.SOURCE_CONTINUE);

        // Detect a configured agent in the pty's foreground.
        var name_buf: [32]u8 = undefined;
        const detected = detectForegroundAgent(core_surface, names, &name_buf);
        if (detected) |name| {
            self.seen = true;
            const n = @min(name.len, self.name.len);
            @memcpy(self.name[0..n], name[0..n]);
            self.name_len = @intCast(n);
        }

        // No agent now and none seen: nothing to track; keep the sampling
        // state clean so the next detection starts fresh.
        if (detected == null and !self.seen) {
            self.screen_hash = 0;
            self.quiet_ticks = 0;
            self.setState(surface, config, .none);
            return @intFromBool(glib.SOURCE_CONTINUE);
        }

        // Sample the viewport for output activity and prompt-like text.
        const alloc = Application.default().allocator();
        const dump: []const u8 = dump: {
            core_surface.renderer_state.mutex.lockUncancelable(global.io());
            defer core_surface.renderer_state.mutex.unlock(global.io());
            const screen = core_surface.renderer_state.terminal.screens.active;
            break :dump screen.dumpStringAlloc(
                alloc,
                .{ .viewport = .{} },
            ) catch "";
        };
        defer if (dump.len > 0) alloc.free(dump);

        const hash = std.hash.Wyhash.hash(0, dump);
        const changed = self.screen_hash != 0 and
            hash != self.screen_hash;
        self.screen_hash = hash;
        if (changed) {
            self.quiet_ticks = 0;
        } else {
            self.quiet_ticks +|= 1;
        }

        const next_state = agent_monitor.next(self.state, .{
            .agent_present = detected != null,
            .agent_seen = self.seen,
            .screen_changed = changed,
            .quiet_ticks = self.quiet_ticks,
            .tail = dump[dump.len -| 2048..],
        });
        self.setState(surface, config, next_state);

        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    /// Transition the agent state and apply side effects: tab badge,
    /// desktop notification, and background tint.
    fn setState(
        self: *AgentWatch,
        surface: *Surface,
        config_: ?*const configpkg.Config,
        state: agent_monitor.State,
    ) void {
        const prev = self.state;
        if (prev == state) return;
        self.state = state;
        log.debug("agent state {s} -> {s}", .{ @tagName(prev), @tagName(state) });

        // Badge on our containing tab (bubbles to the Tab widget).
        _ = surface.as(gtk.Widget).activateActionVariant(
            "tab.agent-state",
            glib.Variant.newString(@tagName(state)),
        );

        const config = config_ orelse return;

        // Background tint while blocked (agent-colors).
        if (config.@"agent-colors") {
            if (state == .blocked) {
                applyTint(surface, config);
            } else if (prev == .blocked) {
                resetTint(surface);
            }
        }

        // Desktop notifications (agent-notify): working -> blocked and
        // (working|blocked) -> done, only when the surface isn't focused —
        // a focused tab is already being watched.
        if (config.@"agent-notify" and !surface.getFocused()) notify: {
            const alloc = Application.default().allocator();
            const name: []const u8 = if (self.name_len > 0)
                self.name[0..self.name_len]
            else
                "agent";

            const blocked = prev == .working and state == .blocked;
            const done = (prev == .working or prev == .blocked) and
                state == .done;
            if (!blocked and !done) break :notify;

            const title_ = if (blocked)
                i18n._("Agent Waiting for Input")
            else
                i18n._("Agent Finished");

            const body = if (blocked)
                std.fmt.allocPrintSentinel(
                    alloc,
                    "{s} appears to be waiting for your input.",
                    .{name},
                    0,
                ) catch break :notify
            else
                std.fmt.allocPrintSentinel(
                    alloc,
                    "{s} finished.",
                    .{name},
                    0,
                ) catch break :notify;
            defer alloc.free(body);

            surface.sendDesktopNotification(std.mem.span(title_), body);
        }
    }
};

/// Read /proc/<pid>/<name> into buf. Linux only.
fn readProcFile(pid: std.posix.pid_t, comptime name: []const u8, buf: []u8) ?[]u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(
        &path_buf,
        "/proc/{d}/" ++ name,
        .{pid},
    ) catch return null;
    const file = std.Io.Dir.openFileAbsolute(global.io(), path, .{}) catch return null;
    defer file.close(global.io());
    const n = file.readStreaming(global.io(), &.{buf}) catch return null;
    return buf[0..n];
}

/// Return the configured agent name matching the pty's foreground
/// process, or null. The returned slice points into `buf`.
fn detectForegroundAgent(
    core_surface: *CoreSurface,
    names: []const [:0]const u8,
    buf: []u8,
) ?[]const u8 {
    // Foreground process inspection relies on /proc.
    if (comptime builtin.os.tag != .linux) return null;

    const master: std.posix.fd_t = switch (core_surface.io.backend) {
        .exec => |*v| master: {
            const pty = v.subprocess.pty orelse return null;
            break :master pty.master;
        },
        .adopt => |*v| v.master_fd,
    };
    // std.posix.tcgetpgrp doesn't compile against libc on this Zig
    // (std.c lacks the declaration), so issue the ioctl directly.
    var pgrp: std.posix.pid_t = 0;
    const rc = std.os.linux.ioctl(
        master,
        std.os.linux.T.IOCGPGRP,
        @intFromPtr(&pgrp),
    );
    if (rc != 0) return null;
    if (pgrp <= 0) return null;

    var comm_buf: [64]u8 = undefined;
    const comm = std.mem.trimEnd(
        u8,
        readProcFile(pgrp, "comm", &comm_buf) orelse "",
        "\n",
    );

    var cmd_buf: [512]u8 = undefined;
    const cmdline: []u8 = readProcFile(pgrp, "cmdline", &cmd_buf) orelse
        cmd_buf[0..0];
    // cmdline is NUL-separated argv; flatten for substring matching.
    for (cmdline) |*c| {
        if (c.* == 0) c.* = ' ';
    }

    const name = agent_monitor.matchAgent(names, comm, cmdline) orelse
        return null;
    const n = @min(name.len, buf.len);
    @memcpy(buf[0..n], name[0..n]);
    return buf[0..n];
}

/// Inject an OSC 11 tint of the configured background toward amber,
/// marking a blocked agent tab. Same injection mechanism as the
/// per-surface palettes (osc_palette.zig): the bytes go through the
/// terminal parser; the child process never sees them.
fn applyTint(surface: *Surface, config: *const configpkg.Config) void {
    const core_surface = surface.core() orelse return;
    const alloc = std.heap.c_allocator;

    // Blend 75% background + 25% amber (Adwaita yellow-4).
    const bg = config.background;
    const r: u8 = @intCast((@as(u32, bg.r) * 3 + 0xe5) / 4);
    const g: u8 = @intCast((@as(u32, bg.g) * 3 + 0xa5) / 4);
    const b: u8 = @intCast((@as(u32, bg.b) * 3 + 0x0a) / 4);

    const bytes = std.fmt.allocPrint(
        alloc,
        "\x1b]11;#{x:0>2}{x:0>2}{x:0>2}\x07",
        .{ r, g, b },
    ) catch return;
    core_surface.io.queueMessage(.{ .inject_output = .{
        .alloc = alloc,
        .data = bytes,
    } }, .unlocked);
}

/// Reset the OSC 11 background override applied by applyTint.
fn resetTint(surface: *Surface) void {
    const core_surface = surface.core() orelse return;
    const alloc = std.heap.c_allocator;
    const bytes = alloc.dupe(u8, "\x1b]111\x07") catch return;
    core_surface.io.queueMessage(.{ .inject_output = .{
        .alloc = alloc,
        .data = bytes,
    } }, .unlocked);
}
