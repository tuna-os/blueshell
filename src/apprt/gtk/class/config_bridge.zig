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
pub fn setKey(alloc: Allocator, key: []const u8, value: []const u8, maybe_path: ?[]const u8) !void {
    const path = if (maybe_path) |p| try alloc.dupe(u8, p) else try resolveConfigPath(alloc);
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
pub fn setKeyList(alloc: Allocator, key: []const u8, values: []const []const u8, maybe_path: ?[]const u8) !void {
    const path = if (maybe_path) |p| try alloc.dupe(u8, p) else try resolveConfigPath(alloc);
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

/// Set or remove a keybinding like `keybind = bind_key=action`.
/// If `action` is null, it removes any existing `keybind = bind_key=...` line.
/// Otherwise, it replaces/adds `keybind = bind_key=action`.
pub fn setKeybind(alloc: Allocator, bind_key: []const u8, maybe_action: ?[]const u8, maybe_path: ?[]const u8) !void {
    const path = if (maybe_path) |p| try alloc.dupe(u8, p) else try resolveConfigPath(alloc);
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
        if (lineAssignsKeybind(line, bind_key)) continue;
        if (!first) try out.append(alloc, '\n');
        try out.appendSlice(alloc, line);
        first = false;
    }

    if (maybe_action) |action| {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
            try out.append(alloc, '\n');
        }
        try out.writer(alloc).print("keybind = {s}={s}\n", .{ bind_key, action });
    }

    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);
    {
        const f = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }
    try std.fs.renameAbsolute(tmp_path, path);

    log.info("config keybind write: {s} -> {s}", .{ bind_key, path });
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

fn lineAssignsKeybind(line: []const u8, bind_key: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    if (i >= line.len) return false;
    if (line[i] == '#') return false;
    if (!std.mem.startsWith(u8, line[i..], "keybind")) return false;
    var j = i + "keybind".len;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
    if (j >= line.len or line[j] != '=') return false;
    j += 1;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) : (j += 1) {}
    if (j >= line.len) return false;
    if (!std.mem.startsWith(u8, line[j..], bind_key)) return false;
    var k = j + bind_key.len;
    while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
    return k < line.len and line[k] == '=';
}

test "lineAssignsKey - simple" {
    try std.testing.expect(lineAssignsKey("background-opacity = 0.8", "background-opacity"));
    try std.testing.expect(lineAssignsKey("  background-opacity=0.8", "background-opacity"));
    try std.testing.expect(!lineAssignsKey("# background-opacity = 0.8", "background-opacity"));
    try std.testing.expect(!lineAssignsKey("background-opacity-foo = 1", "background-opacity"));
    try std.testing.expect(!lineAssignsKey("font-family = X", "background-opacity"));
}

// ---------------------------------------------------------------------
// Hermetic file round-trip tests. All use the explicit-path parameter,
// so nothing touches the user's real config.

const TestFile = struct {
    tmp: std.testing.TmpDir,
    path: []u8,

    fn init(alloc: Allocator) !TestFile {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try tmp.dir.realpathAlloc(alloc, ".");
        defer alloc.free(base);
        const path = try std.fmt.allocPrint(alloc, "{s}/config", .{base});
        return .{ .tmp = tmp, .path = path };
    }

    fn deinit(self: *TestFile, alloc: Allocator) void {
        alloc.free(self.path);
        self.tmp.cleanup();
    }

    fn write(self: *TestFile, contents: []const u8) !void {
        const f = try std.fs.createFileAbsolute(self.path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(contents);
    }

    fn read(self: *TestFile, alloc: Allocator) ![]u8 {
        const f = try std.fs.openFileAbsolute(self.path, .{});
        defer f.close();
        return try f.readToEndAlloc(alloc, 1 << 20);
    }
};

test "config_bridge: setKey creates file and appends" {
    const alloc = std.testing.allocator;
    var tf = try TestFile.init(alloc);
    defer tf.deinit(alloc);

    try setKey(alloc, "background-opacity", "0.85", tf.path);
    const out = try tf.read(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("background-opacity = 0.85\n", out);
}

test "config_bridge: setKey replaces last occurrence, preserves comments" {
    const alloc = std.testing.allocator;
    var tf = try TestFile.init(alloc);
    defer tf.deinit(alloc);

    try tf.write(
        \\# my config
        \\background-opacity = 0.5
        \\font-family = X
        \\background-opacity = 0.6
        \\
    );
    try setKey(alloc, "background-opacity", "0.9", tf.path);
    const out = try tf.read(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\# my config
        \\background-opacity = 0.5
        \\font-family = X
        \\background-opacity = 0.9
        \\
    , out);
}

test "config_bridge: setKey appends to file without trailing newline" {
    const alloc = std.testing.allocator;
    var tf = try TestFile.init(alloc);
    defer tf.deinit(alloc);

    try tf.write("font-family = X"); // no trailing \n
    try setKey(alloc, "cursor-style", "bar", tf.path);
    const out = try tf.read(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("font-family = X\ncursor-style = bar\n", out);
}

test "config_bridge: setKey replaces final line lacking trailing newline" {
    const alloc = std.testing.allocator;
    var tf = try TestFile.init(alloc);
    defer tf.deinit(alloc);

    try tf.write("a = 1\ncursor-style = block"); // no trailing \n
    try setKey(alloc, "cursor-style", "bar", tf.path);
    const out = try tf.read(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a = 1\ncursor-style = bar\n", out);
}

test "config_bridge: setKeyList removes all then appends" {
    const alloc = std.testing.allocator;
    var tf = try TestFile.init(alloc);
    defer tf.deinit(alloc);

    try tf.write(
        \\palette = 0=#000000
        \\font-family = X
        \\palette = 1=#111111
        \\
    );
    try setKeyList(alloc, "palette", &.{ "0=#aaaaaa", "1=#bbbbbb" }, tf.path);
    const out = try tf.read(alloc);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(
        \\font-family = X
        \\palette = 0=#aaaaaa
        \\palette = 1=#bbbbbb
        \\
    , out);
}

test "config_bridge: setKeybind adds, replaces, and removes" {
    const alloc = std.testing.allocator;
    var tf = try TestFile.init(alloc);
    defer tf.deinit(alloc);

    try setKeybind(alloc, "ctrl+t", "new_tab", tf.path);
    {
        const out = try tf.read(alloc);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("keybind = ctrl+t=new_tab\n", out);
    }

    // Replacing the same trigger leaves a single line.
    try setKeybind(alloc, "ctrl+t", "new_window", tf.path);
    {
        const out = try tf.read(alloc);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("keybind = ctrl+t=new_window\n", out);
    }

    // Removing (null action) deletes the line, keeps other bindings.
    try setKeybind(alloc, "ctrl+d", "inspector:toggle", tf.path);
    try setKeybind(alloc, "ctrl+t", null, tf.path);
    {
        const out = try tf.read(alloc);
        defer alloc.free(out);
        try std.testing.expectEqualStrings("keybind = ctrl+d=inspector:toggle\n", out);
    }
}

test "config_bridge: emitted file parses with Ghostty's real config loader" {
    const alloc = std.testing.allocator;
    var tf = try TestFile.init(alloc);
    defer tf.deinit(alloc);

    // Write the same keys the preferences UI writes.
    try setKey(alloc, "background-opacity", "0.85", tf.path);
    try setKey(alloc, "cursor-style", "block_hollow", tf.path);
    try setKey(alloc, "bell-features", "audio,no-attention,title", tf.path);
    try setKey(alloc, "scroll-to-bottom", "no-keystroke,output", tf.path);
    try setKeybind(alloc, "ctrl+t", "new_tab", tf.path);
    try setKeyList(alloc, "palette", &.{ "0=#1e1e1e", "1=#ff5555" }, tf.path);

    const Config = @import("../../../config.zig").Config;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    try cfg.loadFile(alloc, tf.path);
    try cfg.finalize();

    try std.testing.expectApproxEqAbs(@as(f64, 0.85), cfg.@"background-opacity", 0.001);
    try std.testing.expectEqual(.block_hollow, cfg.@"cursor-style");
    try std.testing.expect(cfg.@"bell-features".audio);
    try std.testing.expect(!cfg.@"bell-features".attention);
    try std.testing.expect(cfg.@"bell-features".title);
    try std.testing.expect(!cfg.@"scroll-to-bottom".keystroke);
    try std.testing.expect(cfg.@"scroll-to-bottom".output);
    // The config must parse with zero diagnostics — a diagnostic means
    // the UI wrote a line Ghostty rejects.
    try std.testing.expect(cfg._diagnostics.empty());
}

test "lineAssignsKeybind" {
    try std.testing.expect(lineAssignsKeybind("keybind = backspace=text:\\x7f", "backspace"));
    try std.testing.expect(lineAssignsKeybind("  keybind=backspace = text:\\x7f", "backspace"));
    try std.testing.expect(!lineAssignsKeybind("# keybind = backspace=text:\\x7f", "backspace"));
    try std.testing.expect(!lineAssignsKeybind("keybind = delete=text:\\x7f", "backspace"));
}
