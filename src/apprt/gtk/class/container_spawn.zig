const std = @import("std");
const compat_fd = @import("../../../lib/compat/fd.zig");

/// Transaction representing an in-flight container spawn handoff.
///
/// Encapsulates the allocated PTY master descriptor, metadata (title and icon),
/// and a unique handoff token. Ownership of the master_fd is transferred exactly
/// once to the matching Surface. If tab/surface creation fails, or the transaction
/// is cancelled or dropped during application disposal, deinit() ensures the
/// master PTY descriptor is closed and metadata strings freed without leaking.
pub const PendingContainerSpawn = struct {
    token: u64,
    master_fd: c_int,
    title: ?[:0]const u8 = null,
    icon: ?[:0]const u8 = null,

    pub fn init(
        token: u64,
        master_fd: c_int,
        title: ?[:0]const u8,
        icon: ?[:0]const u8,
    ) PendingContainerSpawn {
        return .{
            .token = token,
            .master_fd = master_fd,
            .title = title,
            .icon = icon,
        };
    }

    /// Releases any resources held by this pending spawn.
    /// Closes the master_fd if it has not yet been taken, and frees title and icon.
    pub fn deinit(self: *PendingContainerSpawn, alloc: std.mem.Allocator) void {
        if (self.master_fd >= 0) {
            compat_fd.close(self.master_fd);
            self.master_fd = -1;
        }
        if (self.title) |t| {
            alloc.free(t);
            self.title = null;
        }
        if (self.icon) |i| {
            alloc.free(i);
            self.icon = null;
        }
        self.* = undefined;
    }

    /// Transfer ownership of the master_fd. The descriptor is returned and
    /// set to -1 in the transaction so that subsequent deinit() calls will not close it.
    pub fn takeMasterFd(self: *PendingContainerSpawn) ?c_int {
        if (self.master_fd < 0) return null;
        const fd = self.master_fd;
        self.master_fd = -1;
        return fd;
    }
};

test "PendingContainerSpawn: takeMasterFd transfers ownership once" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const dummy_fd: c_int = 42;
    const title_copy = try alloc.dupeZ(u8, "fedora-toolbox");
    const icon_copy = try alloc.dupeZ(u8, "container-toolbox-symbolic");

    var spawn = PendingContainerSpawn.init(1001, dummy_fd, title_copy, icon_copy);
    try testing.expectEqual(@as(u64, 1001), spawn.token);
    try testing.expectEqual(@as(?c_int, 42), spawn.takeMasterFd());
    try testing.expectEqual(@as(?c_int, null), spawn.takeMasterFd());
    try testing.expectEqual(@as(c_int, -1), spawn.master_fd);

    // deinit should free strings and not crash or close master_fd because master_fd < 0
    spawn.deinit(alloc);
}

test "PendingContainerSpawn: deinit cleans up untaken fd" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create a real pipe to test that deinit closes the untaken fd
    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];
    defer compat_fd.close(read_fd);

    const title_copy = try alloc.dupeZ(u8, "ubuntu-lts");
    var spawn = PendingContainerSpawn.init(2002, write_fd, title_copy, null);
    try testing.expectEqual(@as(c_int, write_fd), spawn.master_fd);

    // deinit should close write_fd
    spawn.deinit(alloc);

    // Reading from read_fd should now return 0 (EOF) since write_fd was closed
    var buf: [1]u8 = undefined;
    const bytes_read = try std.posix.read(read_fd, &buf);
    try testing.expectEqual(@as(usize, 0), bytes_read);
}

test "PendingContainerSpawn: mock application store token matching and rejection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const MockAppStore = struct {
        pending_container_spawn: ?PendingContainerSpawn = null,
        next_container_spawn_token: u64 = 1,

        pub fn allocContainerSpawnToken(self: *@This()) u64 {
            const token = self.next_container_spawn_token;
            self.next_container_spawn_token +%= 1;
            if (self.next_container_spawn_token == 0) self.next_container_spawn_token = 1;
            return token;
        }

        pub fn setPendingContainerSpawn(self: *@This(), spawn: PendingContainerSpawn) void {
            if (self.pending_container_spawn) |*existing| {
                existing.deinit(alloc);
            }
            self.pending_container_spawn = spawn;
        }

        pub fn takePendingContainerMasterFd(self: *@This(), token: u64) ?c_int {
            if (self.pending_container_spawn) |*spawn| {
                if (spawn.token == token) {
                    return spawn.takeMasterFd();
                }
            }
            return null;
        }

        pub const Meta = struct {
            title: ?[:0]const u8,
            icon: ?[:0]const u8,
        };

        pub fn takePendingContainerMetadata(self: *@This(), token: u64) ?Meta {
            if (self.pending_container_spawn) |*spawn| {
                if (spawn.token == token) {
                    const meta = Meta{
                        .title = spawn.title,
                        .icon = spawn.icon,
                    };
                    spawn.title = null;
                    spawn.icon = null;
                    spawn.deinit(alloc);
                    self.pending_container_spawn = null;
                    return meta;
                }
            }
            return null;
        }

        pub fn abortPendingContainerSpawn(self: *@This(), token: u64) void {
            if (self.pending_container_spawn) |*spawn| {
                if (spawn.token == token) {
                    spawn.deinit(alloc);
                    self.pending_container_spawn = null;
                }
            }
        }

        pub fn deinit(self: *@This()) void {
            if (self.pending_container_spawn) |*spawn| {
                spawn.deinit(alloc);
                self.pending_container_spawn = null;
            }
        }
    };

    var store = MockAppStore{};
    defer store.deinit();

    const token1 = store.allocContainerSpawnToken();
    try testing.expectEqual(@as(u64, 1), token1);

    // Stash spawn for token1
    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];
    defer compat_fd.close(read_fd);

    store.setPendingContainerSpawn(.{
        .token = token1,
        .master_fd = write_fd,
        .title = try alloc.dupeZ(u8, "alpine-dev"),
        .icon = try alloc.dupeZ(u8, "container-generic-symbolic"),
    });

    // Mismatched token (unrelated surface or token2) MUST return null and not consume
    const wrong_token: u64 = 999;
    try testing.expectEqual(@as(?c_int, null), store.takePendingContainerMasterFd(wrong_token));
    try testing.expect(store.takePendingContainerMetadata(wrong_token) == null);

    // Matching token successfully consumes master fd
    const fd = store.takePendingContainerMasterFd(token1);
    try testing.expectEqual(@as(?c_int, write_fd), fd);
    // Second take on matching token returns null (already taken)
    try testing.expectEqual(@as(?c_int, null), store.takePendingContainerMasterFd(token1));

    // Metadata consumption succeeds and clears transaction
    const meta = store.takePendingContainerMetadata(token1);
    try testing.expect(meta != null);
    if (meta) |m| {
        defer if (m.title) |t| alloc.free(t);
        defer if (m.icon) |i| alloc.free(i);
        try testing.expectEqualStrings("alpine-dev", m.title.?);
        try testing.expectEqualStrings("container-generic-symbolic", m.icon.?);
    }
    try testing.expect(store.pending_container_spawn == null);

    // Close the consumed write_fd manually to verify clean test state
    compat_fd.close(write_fd);
}

test "PendingContainerSpawn: pre-handoff abort cleans up pipe" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const pipe_fds = try std.posix.pipe();
    const read_fd = pipe_fds[0];
    const write_fd = pipe_fds[1];
    defer compat_fd.close(read_fd);

    var spawn = PendingContainerSpawn.init(42, write_fd, try alloc.dupeZ(u8, "test-abort"), null);
    // Simulating pre-handoff error path: spawn.deinit() is called
    spawn.deinit(alloc);

    // write_fd should be closed, reading read_fd returns EOF
    var buf: [1]u8 = undefined;
    const bytes_read = try std.posix.read(read_fd, &buf);
    try testing.expectEqual(@as(usize, 0), bytes_read);
}

