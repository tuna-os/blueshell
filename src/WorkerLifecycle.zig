//! Owner-thread lifecycle for a single surface worker. The worker's state and
//! stop handle must remain alive until shutdown returns. This is not a pool:
//! the workers have different event loops and message protocols.
const WorkerLifecycle = @This();
const std = @import("std");

const log = std.log.scoped(.worker_lifecycle);

/// Only the surface's owning thread may access this state. "running" means
/// spawned and not yet joined, not necessarily that the worker is still alive.
state: union(enum) {
    initialized,
    running: std.Thread,
    stopped,
} = .initialized,

/// A failed spawn leaves the lifecycle initialized and safe to shut down.
pub fn start(self: *WorkerLifecycle, function: anytype, args: anytype) !std.Thread {
    std.debug.assert(self.state == .initialized);
    const thread = try std.Thread.spawn(.{}, function, args);
    self.state = .{ .running = thread };
    return thread;
}

/// Request stop and join before freeing any worker state. Must not be called
/// with a lock held that the worker needs. A failed notification may stall
/// the join, but freeing the worker while it is running would be unsafe.
pub fn shutdown(self: *WorkerLifecycle, stop: anytype, name: []const u8) void {
    switch (self.state) {
        .initialized => {},
        .stopped => return,
        .running => |thread| {
            stop.notify() catch |err| log.err(
                "error notifying {s} thread to stop, may stall err={}",
                .{ name, err },
            );
            thread.join();
        },
    }
    self.state = .stopped;
}

const TestStop = struct {
    requested: std.atomic.Value(bool) = .init(false),
    calls: usize = 0,

    fn notify(self: *TestStop) error{}!void {
        self.calls += 1;
        self.requested.store(true, .release);
    }
};

fn testWorker(stop: *TestStop) void {
    while (!stop.requested.load(.acquire)) std.atomic.spinLoopHint();
}

test "worker lifecycle joins once and handles unstarted shutdown" {
    var unstarted: WorkerLifecycle = .{};
    var stop: TestStop = .{};
    unstarted.shutdown(&stop, "unstarted");
    try std.testing.expect(unstarted.state == .stopped);
    try std.testing.expectEqual(0, stop.calls);

    var worker: WorkerLifecycle = .{};
    _ = try worker.start(testWorker, .{&stop});
    try std.testing.expect(worker.state == .running);
    worker.shutdown(&stop, "test");
    try std.testing.expect(worker.state == .stopped);
    worker.shutdown(&stop, "test");
    try std.testing.expectEqual(1, stop.calls);
}

test "partial startup rollback joins the started worker" {
    const Test = struct {
        fn run(first: *WorkerLifecycle, second: *WorkerLifecycle, stop: *TestStop) !void {
            errdefer {
                first.shutdown(stop, "first");
                second.shutdown(stop, "second");
            }
            _ = try first.start(testWorker, .{stop});
            // Model a failure before the second worker is started.
            return error.LaterInitializationFailed;
        }
    };
    var first: WorkerLifecycle = .{};
    var second: WorkerLifecycle = .{};
    var stop: TestStop = .{};
    try std.testing.expectError(error.LaterInitializationFailed, Test.run(&first, &second, &stop));
    try std.testing.expect(first.state == .stopped);
    try std.testing.expect(second.state == .stopped);
    try std.testing.expectEqual(1, stop.calls);
}
