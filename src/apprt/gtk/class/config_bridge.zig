//! Minimal config-file bridge for the preferences UI.
//!
//! Ghostty's config has no roundtripping serializer (parsed but not
//! emitted), so we manipulate the user's ~/.config/ghostty/config as
//! plain text: replace the last assignment of `key = value` if present,
//! otherwise append a new line. Comments and surrounding lines are
//! preserved.
//!
//! Caveats:
//! - Doesn't understand `+=` (list-append) syntax — treats it as a
//!   regular assignment and overwrites.
//! - If a key appears multiple times, only the last occurrence is
//!   replaced (matching Ghostty's load semantics: later wins).
//! - Doesn't trigger a config reload — caller should request that
//!   separately via the app's reload-config action.

const std = @import("std");
const Allocator = std.mem.Allocator;

const file_load = @import("../../../config/file_load.zig");

const log = std.log.scoped(.gtk_ptyxis_config_bridge);

/// Resolve the user's writable config path. Prefers $XDG_CONFIG_HOME-style
/// path; falls back to ~/.config/ghostty/config.ghostty.
pub fn resolveConfigPath(alloc: Allocator) ![]const u8 {
    return try file_load.defaultXdgPath(alloc);
}

/// Set the value of `key` in the user's config file. Creates the file
/// (and its parent directory) if missing. Replaces the last existing
/// occurrence of `key = ...`, otherwise appends a new line.
pub fn setKey(alloc: Allocator, key: []const u8, value: []const u8) !void {
    const path = try resolveConfigPath(alloc);
    defer alloc.free(path);

    // Ensure parent directory exists.
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Read existing contents (if any).
    var existing: []u8 = &.{};
    defer if (existing.len != 0) alloc.free(existing);
    existing = blk: {
        const f = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk &.{},
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 16 * 1024 * 1024);
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const new_line_writer = struct {
        fn write(buf: *std.ArrayList(u8), a: Allocator, k: []const u8, v: []const u8) !void {
            try buf.writer(a).print("{s} = {s}\n", .{ k, v });
        }
    };

    // Find the last line that assigns `key`. Two-pass: scan to find idx,
    // then write replacing that line.
    var last_match_start: ?usize = null;
    var last_match_end: usize = 0;

    var iter = std.mem.splitScalar(u8, existing, '\n');
    var pos: usize = 0;
    while (iter.next()) |line| {
        defer pos += line.len + 1; // +1 for the \n that split consumed
        if (lineAssignsKey(line, key)) {
            last_match_start = pos;
            last_match_end = pos + line.len;
        }
    }

    if (last_match_start) |s| {
        try out.appendSlice(alloc, existing[0..s]);
        try new_line_writer.write(&out, alloc, key, value);
        // Skip the matched line; preserve everything after (the \n at
        // last_match_end is preserved if present).
        if (last_match_end + 1 < existing.len) {
            try out.appendSlice(alloc, existing[last_match_end + 1 ..]);
        } else if (last_match_end < existing.len) {
            // Final line with no trailing newline.
            try out.appendSlice(alloc, existing[last_match_end..last_match_end]);
        }
    } else {
        try out.appendSlice(alloc, existing);
        if (existing.len > 0 and existing[existing.len - 1] != '\n') {
            try out.append(alloc, '\n');
        }
        try new_line_writer.write(&out, alloc, key, value);
    }

    // Atomic-ish write: write to .tmp then rename.
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);

    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }
    try std.fs.renameAbsolute(tmp_path, path);

    log.info("config write: {s} = {s} -> {s}", .{ key, value, path });
}

/// Like `setKey`, but for list-append keys (e.g. `palette`, `keybind`,
/// `font-family`). Removes every existing assignment to `key` from the
/// file, then appends one new line per element of `values`.
pub fn setKeyList(alloc: Allocator, key: []const u8, values: []const []const u8) !void {
    const path = try resolveConfigPath(alloc);
    defer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    var existing: []u8 = &.{};
    defer if (existing.len != 0) alloc.free(existing);
    existing = blk: {
        const f = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk &.{},
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 16 * 1024 * 1024);
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var iter = std.mem.splitScalar(u8, existing, '\n');
    var first = true;
    while (iter.next()) |line| {
        if (lineAssignsKey(line, key)) continue;
        if (!first) try out.append(alloc, '\n');
        try out.appendSlice(alloc, line);
        first = false;
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(alloc, '\n');
    }
    for (values) |v| {
        try out.writer(alloc).print("{s} = {s}\n", .{ key, v });
    }

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }
    try std.fs.renameAbsolute(tmp_path, path);

    log.info("config list write: {s} ({d} entries) -> {s}", .{ key, values.len, path });
}

/// Returns true if `line` is a non-comment assignment of `key`.
fn lineAssignsKey(line: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return false;
    if (line[i] == '#') return false;
    if (!std.mem.startsWith(u8, line[i..], key)) return false;
    var j = i + key.len;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
    return j < line.len and line[j] == '=';
}

test "lineAssignsKey - simple" {
    try std.testing.expect(lineAssignsKey("background-opacity = 0.8", "background-opacity"));
    try std.testing.expect(lineAssignsKey("  background-opacity=0.8", "background-opacity"));
    try std.testing.expect(!lineAssignsKey("# background-opacity = 0.8", "background-opacity"));
    try std.testing.expect(!lineAssignsKey("background-opacity-foo = 1", "background-opacity"));
    try std.testing.expect(!lineAssignsKey("font-family = X", "background-opacity"));
}
