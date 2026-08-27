//! Agent awareness (RFC #22): the pure, GTK-free half of the herdr-style
//! agent integration. This module owns the state machine and the pattern
//! tables; the GTK glue (a periodic tick per surface that inspects the
//! pty's foreground process and samples the viewport) lives in
//! `surface.zig` and feeds `next()` with observations.
//!
//! States, following herdr's classification:
//!
//!   - `none`    — no agent involved (or state cleared after `done` was seen)
//!   - `idle`    — agent in the foreground, output quiescent, no prompt-like
//!                 text: it's sitting at its input box waiting for a task
//!   - `working` — agent in the foreground and output is flowing
//!   - `blocked` — output quiescent AND the viewport tail looks like a
//!                 question (y/n, "Do you want…", approval prompts)
//!   - `done`    — a detected agent left the foreground; sticky until the
//!                 user looks at the tab (the GTK side clears it on focus)
//!
//! Detection and classification are heuristics by design (this is the
//! herdr approach): they only run for processes the user listed in
//! `agent-detect`, which defaults to empty (feature off).

const std = @import("std");

pub const State = enum {
    none,
    idle,
    working,
    blocked,
    done,
};

/// One observation tick's worth of inputs to the state machine.
pub const Input = struct {
    /// A configured agent process is in the foreground of the pty.
    agent_present: bool,

    /// An agent was present at some point since the last reset. Owned by
    /// the caller (cleared when `done` is acknowledged / state resets).
    agent_seen: bool,

    /// The viewport changed since the previous tick.
    screen_changed: bool,

    /// Consecutive ticks without a viewport change.
    quiet_ticks: u32,

    /// The tail of the viewport text (last few hundred bytes is enough);
    /// scanned case-insensitively for blocked patterns.
    tail: []const u8,
};

/// Number of quiet ticks before we classify quiescence (idle/blocked)
/// instead of keeping the previous state. At the surface's 2s tick this
/// is ~4 seconds of no output.
pub const quiet_threshold: u32 = 2;

/// Prompt-like patterns that mark a quiescent agent as `blocked`, matched
/// case-insensitively against the viewport tail. Sourced from the dialogs
/// of common agent CLIs (Claude Code, Codex, aider, …); herdr uses the
/// same approach. Hardcoded for now — a config override is an RFC open
/// question and can layer on later.
pub const blocked_patterns = [_][]const u8{
    "do you want",
    "would you like",
    "waiting for",
    "y/n",
    "yes/no",
    "approv", // approve / approval
    "permission",
    "confirm",
    "press enter",
    "proceed?",
    "allow this",
};

/// Advance the state machine by one tick.
pub fn next(prev: State, in: Input) State {
    if (!in.agent_present) {
        // The agent left the foreground: if we ever saw one, the run is
        // done and stays done until the caller resets (on focus).
        return if (in.agent_seen) .done else .none;
    }

    // Agent in the foreground.
    if (in.screen_changed) return .working;
    if (in.quiet_ticks >= quiet_threshold) {
        if (containsBlockedPattern(in.tail)) return .blocked;
        return .idle;
    }

    // Not enough quiet to reclassify; a fresh detection starts as working.
    return switch (prev) {
        .none, .done => .working,
        else => prev,
    };
}

/// Whether `tail` contains any blocked pattern, ASCII-case-insensitively.
pub fn containsBlockedPattern(tail: []const u8) bool {
    for (blocked_patterns) |pat| {
        if (indexOfIgnoreCase(tail, pat) != null) return true;
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return i;
    }
    return null;
}

/// Match the pty's foreground process against the configured agent list.
/// `comm` is the process group leader's comm (no trailing newline);
/// `cmdline` is its full command line with NULs already replaced by
/// spaces. A name matches if it equals comm, or appears as a path
/// component / word inside the command line (so `claude` matches both a
/// `claude` binary and `node /usr/lib/claude-code/cli.js`).
pub fn matchAgent(
    names: []const [:0]const u8,
    comm: []const u8,
    cmdline: []const u8,
) ?[]const u8 {
    for (names) |name| {
        if (name.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(comm, name)) return name;
        if (indexOfIgnoreCase(cmdline, name)) |_| return name;
    }
    return null;
}

test "agent_monitor: none until an agent shows up" {
    const testing = std.testing;
    try testing.expectEqual(State.none, next(.none, .{
        .agent_present = false,
        .agent_seen = false,
        .screen_changed = true,
        .quiet_ticks = 0,
        .tail = "just a shell prompt $",
    }));
}

test "agent_monitor: output flowing means working" {
    const testing = std.testing;
    try testing.expectEqual(State.working, next(.none, .{
        .agent_present = true,
        .agent_seen = true,
        .screen_changed = true,
        .quiet_ticks = 0,
        .tail = "",
    }));
    // Stays working while quiet is below the threshold.
    try testing.expectEqual(State.working, next(.working, .{
        .agent_present = true,
        .agent_seen = true,
        .screen_changed = false,
        .quiet_ticks = 1,
        .tail = "",
    }));
}

test "agent_monitor: quiescent with a question is blocked" {
    const testing = std.testing;
    try testing.expectEqual(State.blocked, next(.working, .{
        .agent_present = true,
        .agent_seen = true,
        .screen_changed = false,
        .quiet_ticks = quiet_threshold,
        .tail = "Do you want to make this edit? \xe2\x9d\xaf 1. Yes",
    }));
    // Case-insensitive.
    try testing.expectEqual(State.blocked, next(.working, .{
        .agent_present = true,
        .agent_seen = true,
        .screen_changed = false,
        .quiet_ticks = quiet_threshold,
        .tail = "PROCEED? [Y/N]",
    }));
}

test "agent_monitor: quiescent without a question is idle" {
    const testing = std.testing;
    try testing.expectEqual(State.idle, next(.working, .{
        .agent_present = true,
        .agent_seen = true,
        .screen_changed = false,
        .quiet_ticks = quiet_threshold,
        .tail = "ready for your next task",
    }));
}

test "agent_monitor: agent exit is done and sticky" {
    const testing = std.testing;
    try testing.expectEqual(State.done, next(.working, .{
        .agent_present = false,
        .agent_seen = true,
        .screen_changed = false,
        .quiet_ticks = 0,
        .tail = "",
    }));
    // Still done on later ticks until the caller resets agent_seen.
    try testing.expectEqual(State.done, next(.done, .{
        .agent_present = false,
        .agent_seen = true,
        .screen_changed = false,
        .quiet_ticks = 5,
        .tail = "",
    }));
    // A new agent run leaves done immediately.
    try testing.expectEqual(State.working, next(.done, .{
        .agent_present = true,
        .agent_seen = true,
        .screen_changed = false,
        .quiet_ticks = 0,
        .tail = "",
    }));
}

test "agent_monitor: matchAgent comm and cmdline" {
    const testing = std.testing;
    const names = [_][:0]const u8{ "claude", "codex" };

    try testing.expectEqualStrings("claude", matchAgent(
        &names,
        "claude",
        "claude",
    ).?);
    try testing.expectEqualStrings("claude", matchAgent(
        &names,
        "node",
        "node /usr/lib/claude-code/cli.js chat",
    ).?);
    try testing.expectEqualStrings("codex", matchAgent(
        &names,
        "CODEX",
        "",
    ).?);
    try testing.expect(matchAgent(&names, "bash", "bash -l") == null);
    try testing.expect(matchAgent(&.{}, "claude", "claude") == null);
}
