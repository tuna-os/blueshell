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
//!
//! Every operation has an `*In` variant taking explicit absolute paths
//! (active config file + profiles dir); the default-named wrappers
//! resolve the XDG paths above and delegate. Tests use the `*In`
//! variants against a temp directory so they never touch the real
//! config (see profile_store tests at the bottom).

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
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    return try profilePathIn(alloc, dir, name);
}

pub fn profilePathIn(alloc: Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (!isValidName(name)) return error.NameInvalid;
    return try std.fmt.allocPrint(alloc, "{s}/{s}.config", .{ dir, name });
}

fn activeMarkerPathIn(alloc: Allocator, dir: []const u8) ![]u8 {
    return try std.fmt.allocPrint(alloc, "{s}/.active", .{dir});
}

fn ensureDir(dir: []const u8) !void {
    std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

/// Read the active profile name. Returns null if the marker file is
/// missing or empty (meaning: "no profile mapping — config is freeform").
pub fn activeProfileName(alloc: Allocator) !?[]u8 {
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    return try activeProfileNameIn(alloc, dir);
}

pub fn activeProfileNameIn(alloc: Allocator, dir: []const u8) !?[]u8 {
    const path = try activeMarkerPathIn(alloc, dir);
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

fn writeActiveMarkerIn(alloc: Allocator, dir: []const u8, name: []const u8) !void {
    try ensureDir(dir);
    const path = try activeMarkerPathIn(alloc, dir);
    defer alloc.free(path);
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(name);
}

/// List profile snapshots on disk. Caller owns the returned slice and
/// each entry (call deinit on each, then free the slice).
pub fn list(alloc: Allocator) ![]Profile {
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    return try listIn(alloc, dir);
}

pub fn listIn(alloc: Allocator, dir_path: []const u8) ![]Profile {
    var out: std.ArrayList(Profile) = .empty;
    errdefer {
        for (out.items) |p| p.deinit(alloc);
        out.deinit(alloc);
    }

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return try out.toOwnedSlice(alloc),
        error.NotDir => return error.NotADirectory,
        else => return err,
    };
    defer dir.close();

    const active_name = try activeProfileNameIn(alloc, dir_path);
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
    const cfg = try activeConfigPath(alloc);
    defer alloc.free(cfg);
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    try addIn(alloc, cfg, dir, name);
}

pub fn addIn(alloc: Allocator, config_path: []const u8, dir: []const u8, name: []const u8) !void {
    if (!isValidName(name)) return error.NameInvalid;
    try ensureDir(dir);

    const dst = try profilePathIn(alloc, dir, name);
    defer alloc.free(dst);

    if (std.fs.accessAbsolute(dst, .{})) |_| {
        return error.AlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {}, // good — doesn't exist yet
        else => return err,
    }

    try copyFile(alloc, config_path, dst);
    log.info("created profile {s} -> {s}", .{ name, dst });
}

/// Delete a profile snapshot.
pub fn delete(alloc: Allocator, name: []const u8) !void {
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    try deleteIn(alloc, dir, name);
}

pub fn deleteIn(alloc: Allocator, dir: []const u8, name: []const u8) !void {
    const path = try profilePathIn(alloc, dir, name);
    defer alloc.free(path);
    std.fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => return error.ProfileNotFound,
        else => return err,
    };
    // If this was the active profile, clear the marker so the next
    // launch doesn't reference a non-existent profile.
    if (try activeProfileNameIn(alloc, dir)) |active| {
        defer alloc.free(active);
        if (std.mem.eql(u8, active, name)) {
            const m = try activeMarkerPathIn(alloc, dir);
            defer alloc.free(m);
            std.fs.deleteFileAbsolute(m) catch {};
        }
    }
    log.info("deleted profile {s}", .{name});
}

/// Switch to a profile: copy the snapshot over the active config, mark
/// it as active. Caller should follow up with Application.triggerReload.
pub fn switchTo(alloc: Allocator, name: []const u8) !void {
    const cfg = try activeConfigPath(alloc);
    defer alloc.free(cfg);
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    try switchToIn(alloc, cfg, dir, name);
}

pub fn switchToIn(alloc: Allocator, config_path: []const u8, dir: []const u8, name: []const u8) !void {
    const src = try profilePathIn(alloc, dir, name);
    defer alloc.free(src);
    // Verify the snapshot exists before clobbering the active config.
    const check = std.fs.openFileAbsolute(src, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ProfileNotFound,
        else => return err,
    };
    check.close();
    if (std.fs.path.dirname(config_path)) |d| try ensureDir(d);
    try copyFile(alloc, src, config_path);
    try writeActiveMarkerIn(alloc, dir, name);
    log.info("switched to profile {s}", .{name});
}

/// Save the current config as a snapshot of an existing profile
/// (i.e. "save changes" — overwrites the snapshot with the active
/// config file contents).
pub fn updateFromActive(alloc: Allocator, name: []const u8) !void {
    const cfg = try activeConfigPath(alloc);
    defer alloc.free(cfg);
    const dir = try profilesDir(alloc);
    defer alloc.free(dir);
    try updateFromActiveIn(alloc, cfg, dir, name);
}

pub fn updateFromActiveIn(alloc: Allocator, config_path: []const u8, dir: []const u8, name: []const u8) !void {
    const dst = try profilePathIn(alloc, dir, name);
    defer alloc.free(dst);
    const check = std.fs.openFileAbsolute(dst, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.ProfileNotFound,
        else => return err,
    };
    check.close();
    try copyFile(alloc, config_path, dst);
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

// ---------------------------------------------------------------------
// Hermetic filesystem tests against a temp directory.

const TestEnv = struct {
    tmp: std.testing.TmpDir,
    base: []u8, // absolute path of tmp dir
    config_path: []u8, // <base>/config
    profiles_dir: []u8, // <base>/profiles

    fn init(alloc: Allocator) !TestEnv {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try tmp.dir.realpathAlloc(alloc, ".");
        errdefer alloc.free(base);
        const config_path = try std.fmt.allocPrint(alloc, "{s}/config", .{base});
        errdefer alloc.free(config_path);
        const profiles_dir = try std.fmt.allocPrint(alloc, "{s}/profiles", .{base});
        return .{ .tmp = tmp, .base = base, .config_path = config_path, .profiles_dir = profiles_dir };
    }

    fn deinit(self: *TestEnv, alloc: Allocator) void {
        alloc.free(self.profiles_dir);
        alloc.free(self.config_path);
        alloc.free(self.base);
        self.tmp.cleanup();
    }

    fn writeConfig(self: *TestEnv, contents: []const u8) !void {
        const f = try std.fs.createFileAbsolute(self.config_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(contents);
    }

    fn readConfig(self: *TestEnv, alloc: Allocator) ![]u8 {
        const f = try std.fs.openFileAbsolute(self.config_path, .{});
        defer f.close();
        return try f.readToEndAlloc(alloc, 1 << 20);
    }
};

test "profile_store: add/list/switch/delete round-trip" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    // Snapshot the current config as "work".
    try env.writeConfig("background-opacity = 0.9\n");
    try addIn(alloc, env.config_path, env.profiles_dir, "work");

    // Duplicate add is rejected.
    try std.testing.expectError(
        error.AlreadyExists,
        addIn(alloc, env.config_path, env.profiles_dir, "work"),
    );

    // Change the active config, snapshot as "play".
    try env.writeConfig("background-opacity = 0.5\n");
    try addIn(alloc, env.config_path, env.profiles_dir, "play");

    // Both listed, sorted, neither active yet.
    {
        const profiles = try listIn(alloc, env.profiles_dir);
        defer {
            for (profiles) |p| p.deinit(alloc);
            alloc.free(profiles);
        }
        try std.testing.expectEqual(@as(usize, 2), profiles.len);
        try std.testing.expectEqualStrings("play", profiles[0].name);
        try std.testing.expectEqualStrings("work", profiles[1].name);
        try std.testing.expect(!profiles[0].active and !profiles[1].active);
    }

    // Switch to "work": config contents replaced, marker set.
    try switchToIn(alloc, env.config_path, env.profiles_dir, "work");
    {
        const cfg = try env.readConfig(alloc);
        defer alloc.free(cfg);
        try std.testing.expectEqualStrings("background-opacity = 0.9\n", cfg);
        const active = (try activeProfileNameIn(alloc, env.profiles_dir)).?;
        defer alloc.free(active);
        try std.testing.expectEqualStrings("work", active);
    }

    // list marks the active profile.
    {
        const profiles = try listIn(alloc, env.profiles_dir);
        defer {
            for (profiles) |p| p.deinit(alloc);
            alloc.free(profiles);
        }
        try std.testing.expect(!profiles[0].active); // play
        try std.testing.expect(profiles[1].active); // work
    }

    // Switching to a missing profile fails without touching the config.
    try std.testing.expectError(
        error.ProfileNotFound,
        switchToIn(alloc, env.config_path, env.profiles_dir, "missing"),
    );

    // updateFromActive: edit config, save back into "work".
    try env.writeConfig("background-opacity = 0.7\n");
    try updateFromActiveIn(alloc, env.config_path, env.profiles_dir, "work");
    {
        const p = try profilePathIn(alloc, env.profiles_dir, "work");
        defer alloc.free(p);
        const f = try std.fs.openFileAbsolute(p, .{});
        defer f.close();
        const data = try f.readToEndAlloc(alloc, 1 << 20);
        defer alloc.free(data);
        try std.testing.expectEqualStrings("background-opacity = 0.7\n", data);
    }

    // Deleting the active profile clears the marker.
    try deleteIn(alloc, env.profiles_dir, "work");
    try std.testing.expect(try activeProfileNameIn(alloc, env.profiles_dir) == null);
    try std.testing.expectError(
        error.ProfileNotFound,
        deleteIn(alloc, env.profiles_dir, "work"),
    );
}

test "profile_store: add with no active config starts empty" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    // No config file exists — snapshot is empty rather than an error.
    try addIn(alloc, env.config_path, env.profiles_dir, "fresh");
    const p = try profilePathIn(alloc, env.profiles_dir, "fresh");
    defer alloc.free(p);
    const f = try std.fs.openFileAbsolute(p, .{});
    defer f.close();
    const data = try f.readToEndAlloc(alloc, 1 << 20);
    defer alloc.free(data);
    try std.testing.expectEqual(@as(usize, 0), data.len);
}

test "profile_store: invalid names rejected at every entry point" {
    const alloc = std.testing.allocator;
    var env = try TestEnv.init(alloc);
    defer env.deinit(alloc);

    try std.testing.expectError(error.NameInvalid, addIn(alloc, env.config_path, env.profiles_dir, "../evil"));
    try std.testing.expectError(error.NameInvalid, deleteIn(alloc, env.profiles_dir, "a/b"));
    try std.testing.expectError(error.NameInvalid, switchToIn(alloc, env.config_path, env.profiles_dir, ""));
    try std.testing.expectError(error.NameInvalid, profilePathIn(alloc, env.profiles_dir, "x y"));
}
