//! Profile store — Ptyxis-style profiles built on top of Ghostty's
//! single-config-file model.
//!
//! Layout:
//!   ~/.config/ghostty/config                  ← the active config Ghostty reads
//!   ~/.config/ghostty/profiles/{name}.config  ← named profile snapshots
//!   ~/.config/ghostty/profiles/.active        ← text: name of active profile
//!
//! Operations are file-level snapshots. Switching = copy profile over
//! the active config + record name in .active + reload-config.

const std = @import("std");
const Allocator = std.mem.Allocator;

const file_load = @import("../../../config/file_load.zig");

const log = std.log.scoped(.gtk_ptyxis_profile_store);

pub const Error = error{
    NoHome,
    ProfileNotFound,
    NameInvalid,
    AlreadyExists,
    NotADirectory,
    OutOfMemory,
} || std.fs.File.OpenError || std.fs.Dir.OpenError ||
    std.posix.RealPathError || std.fs.File.WriteError;

pub const Profile = struct {
    name: []const u8, // owned
    path: []const u8, // owned, absolute
    active: bool,

    pub fn deinit(self: Profile, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.path);
    }
};

/// Validate a user-supplied profile name. Letters, digits, dash, underscore.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

/// Return the path to the active config file (`~/.config/ghostty/config`),
/// owned by the caller.
pub fn activeConfigPath(alloc: Allocator) ![]const u8 {
    return try file_load.defaultXdgPath(alloc);
}

/// Return the directory holding profile snapshots. Caller-owned.
pub fn profilesDir(alloc: Allocator) ![]u8 {
    const cfg = try activeConfigPath(alloc);
    defer alloc.free(cfg);
    const dir = std.fs.path.dirname(cfg) orelse return error.NoHome;
    return try std.fs.path.join(alloc, &.{ dir, "profiles" });
}

pub fn profilePath(alloc: Allocator, name: []const u8) ![]u8 {
    if (!isValidName(name)) return error.NameInvalid;
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/{s}.config", .{ dir, name });
}

fn activeMarkerPath(alloc: Allocator) ![]u8 {
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/.active", .{dir});
}

fn ensureProfilesDir(alloc: Allocator) !void {
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Read the active profile name. Returns null if the marker file is
/// missing or empty (meaning: "no profile mapping — config is freeform").
pub fn activeProfileName(alloc: Allocator) !?[]u8 {
    const path = try activeMarkerPath(alloc);
    defer alloc.free(path);
    const f = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer f.close();
    const raw = try f.readToEndAlloc(alloc, 256);
    defer alloc.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try alloc.dupe(u8, trimmed);
}

fn writeActiveMarker(alloc: Allocator, name: []const u8) !void {
    try ensureProfilesDir(alloc);
    const path = try activeMarkerPath(alloc);
    defer alloc.free(path);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(name);
}

/// List profile snapshots on disk. Caller owns the returned slice and
/// each entry (call deinit on each, then free the slice).
pub fn list(alloc: Allocator) ![]Profile {
    var out: std.ArrayList(Profile) = .empty;
    errdefer {
        for (out.items) |p| p.deinit(alloc);
        out.deinit(alloc);
    }

    const dir_path = try profilesDir(alloc);
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try out.toOwnedSlice(alloc),
        error.NotDir => return error.NotADirectory,
        else => return err,
    };
    defer dir.close();

    const active_name = try activeProfileName(alloc);
    defer if (active_name) |a| alloc.free(a);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".config")) continue;
        const name = entry.name[0 .. entry.name.len - ".config".len];
        if (!isValidName(name)) continue;
        const name_dup = try alloc.dupe(u8, name);
        errdefer alloc.free(name_dup);
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, entry.name });
        errdefer alloc.free(path);
        const active = if (active_name) |a| std.mem.eql(u8, a, name) else false;
        try out.append(alloc, .{ .name = name_dup, .path = path, .active = active });
    }

    std.mem.sort(Profile, out.items, {}, profileLess);
    return try out.toOwnedSlice(alloc);
}

fn profileLess(_: void, a: Profile, b: Profile) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

pub fn copyFile(alloc: Allocator, src: []const u8, dst: []const u8) !void {
    const data = blk: {
        const f = std.fs.openFileAbsolute(src, .{}) catch |err| switch (err) {
            // No active config yet — start from empty.
            error.FileNotFound => break :blk try alloc.alloc(u8, 0),
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(alloc, 16 * 1024 * 1024);
    };
    defer alloc.free(data);

    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{dst});
    defer alloc.free(tmp);
    {
        const f = try std.fs.createFileAbsolute(tmp, .{ .truncate = true });
        defer f.close();
        try f.writeAll(data);
    }
    try std.fs.renameAbsolute(tmp, dst);
}

/// Create a new profile by snapshotting the current active config.
pub fn add(alloc: Allocator, name: []const u8) !void {
    if (!isValidName(name)) return error.NameInvalid;
    try ensureProfilesDir(alloc);

    const dst = try profilePath(alloc, name);
    defer alloc.free(dst);

    std.fs.accessAbsolute(dst, .{}) catch |err| switch (err) {
        error.FileNotFound => {}, // good — doesn't exist yet
        else => return err, // some other access error
    };
    if (std.fs.accessAbsolute(dst, .{})) |_| {
        return error.AlreadyExists;
    } else |_| {}

    const src = try activeConfigPath(alloc);
    defer alloc.free(src);
    try copyFile(alloc, src, dst);
    log.info("created profile {s} -> {s}", .{ name, dst });
}

/// Delete a profile snapshot.
pub fn delete(alloc: Allocator, name: []const u8) !void {
    const path = try profilePath(alloc, name);
    defer alloc.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => return error.ProfileNotFound,
        else => return err,
    };
    // If this was the active profile, clear the marker so the next
    // launch doesn't reference a non-existent profile.
    if (try activeProfileName(alloc)) |active| {
        defer alloc.free(active);
        if (std.mem.eql(u8, active, name)) {
            const m = try activeMarkerPath(alloc);
            defer alloc.free(m);
            std.fs.deleteFileAbsolute(m) catch {};
        }
    }
    log.info("deleted profile {s}", .{name});
}

/// Switch to a profile: copy the snapshot over the active config, mark
/// it as active. Caller should follow up with Application.triggerReload.
pub fn switchTo(alloc: Allocator, name: []const u8) !void {
    const src = try profilePath(alloc, name);
    defer alloc.free(src);
    // Verify the snapshot exists before clobbering the active config.
    _ = std.fs.openFileAbsolute(src, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ProfileNotFound,
        else => return err,
    };
    const dst = try activeConfigPath(alloc);
    defer alloc.free(dst);
    if (std.fs.path.dirname(dst)) |d| {
        std.fs.makeDirAbsolute(d) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    try copyFile(alloc, src, dst);
    try writeActiveMarker(alloc, name);
    log.info("switched to profile {s}", .{name});
}

/// Save the current config as a snapshot of an existing profile
/// (i.e. "save changes" — overwrites the snapshot with the active
/// config file contents).
pub fn updateFromActive(alloc: Allocator, name: []const u8) !void {
    const dst = try profilePath(alloc, name);
    defer alloc.free(dst);
    _ = std.fs.openFileAbsolute(dst, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ProfileNotFound,
        else => return err,
    };
    const src = try activeConfigPath(alloc);
    defer alloc.free(src);
    try copyFile(alloc, src, dst);
    log.info("updated profile {s} from active config", .{name});
}

test "isValidName" {
    try std.testing.expect(isValidName("default"));
    try std.testing.expect(isValidName("Work_2024-Q4"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("../escape"));
    try std.testing.expect(!isValidName("with space"));
    try std.testing.expect(!isValidName("dot.in.name"));
}
