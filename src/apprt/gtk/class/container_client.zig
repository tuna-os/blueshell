//! Client for the bundled ptyxis-agent. Mirrors the C pattern at
//! `src/ptyxis-client.c` (pre-pivot fork): spawn the agent over a UNIX
//! socketpair with `--socket-fd=3`, then speak peer-to-peer GDBus over it
//! as the *server* side (ANONYMOUS auth). The agent exports
//! `org.gnome.Ptyxis.Agent` at `/org/gnome/Ptyxis/Agent` and one
//! `org.gnome.Ptyxis.Container` object per discovered container.
//!
//! M3 scope: spawn + connect + ListContainers + per-container property
//! read. GObject wrappers and the picker UI are separate modules.

const std = @import("std");
const posix = std.posix;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const build_config = @import("../../../build_config.zig");
const Container = @import("container_object.zig").Container;

const log = std.log.scoped(.ptyxis_agent_client);

comptime {
    _ = Client.spawn;
    _ = Client.listContainers;
    _ = Client.deinit;
}

const AGENT_OBJECT_PATH: [:0]const u8 = "/org/gnome/Ptyxis/Agent";
const AGENT_IFACE: [:0]const u8 = "org.gnome.Ptyxis.Agent";
const CONTAINER_IFACE: [:0]const u8 = "org.gnome.Ptyxis.Container";

pub const Error = error{
    SocketpairFailed,
    SocketWrapFailed,
    SpawnFailed,
    DBusFailed,
    ListContainersFailed,
    OutOfMemory,
};

pub const ContainerInfo = struct {
    object_path: [:0]u8,
    id: [:0]u8,
    provider: [:0]u8,
    display_name: [:0]u8,

    pub fn deinit(self: *ContainerInfo, alloc: std.mem.Allocator) void {
        alloc.free(self.object_path);
        alloc.free(self.id);
        alloc.free(self.provider);
        alloc.free(self.display_name);
    }
};

pub const Client = struct {
    alloc: std.mem.Allocator,
    subprocess: *gio.Subprocess,
    bus: *gio.DBusConnection,

    pub fn deinit(self: *Client) void {
        gio.Subprocess.forceExit(self.subprocess);
        _ = gobject.Object.unref(self.subprocess.as(gobject.Object));
        _ = gobject.Object.unref(self.bus.as(gobject.Object));
    }

    /// Spawn the agent and establish a peer-to-peer D-Bus connection.
    /// `agent_path` is the absolute path to the `ptyxis-agent` executable.
    pub fn spawn(alloc: std.mem.Allocator, agent_path: [:0]const u8) Error!Client {
        // socketpair(AF_UNIX, SOCK_STREAM | CLOEXEC, 0)
        var pair: [2]std.c.fd_t = undefined;
        if (std.c.socketpair(
            posix.AF.UNIX,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            0,
            &pair,
        ) != 0) {
            log.warn("socketpair failed", .{});
            return Error.SocketpairFailed;
        }

        // Wrap pair[0] (parent side) as a GSocket. GSocket takes ownership of the fd.
        var gerr: ?*glib.Error = null;
        const socket = gio.Socket.newFromFd(pair[0], &gerr) orelse {
            log.warn("g_socket_new_from_fd: {s}", .{gerrMsg(gerr)});
            if (gerr) |e| glib.Error.free(e);
            posix.close(pair[0]);
            posix.close(pair[1]);
            return Error.SocketWrapFailed;
        };
        defer _ = gobject.Object.unref(socket.as(gobject.Object));

        // Launcher takes ownership of pair[1] (child side) and maps it to fd 3.
        const launcher = gio.SubprocessLauncher.new(.{});
        defer _ = gobject.Object.unref(launcher.as(gobject.Object));
        gio.SubprocessLauncher.takeFd(launcher, pair[1], 3);

        // argv: [agent_path, "--socket-fd=3", null]
        const argv: [3:null]?[*:0]const u8 = .{
            agent_path.ptr,
            "--socket-fd=3",
            null,
        };
        const subprocess = gio.SubprocessLauncher.spawnv(
            launcher,
            @ptrCast(&argv),
            &gerr,
        ) orelse {
            log.warn("spawn ptyxis-agent: {s}", .{gerrMsg(gerr)});
            if (gerr) |e| glib.Error.free(e);
            return Error.SpawnFailed;
        };
        errdefer {
            gio.Subprocess.forceExit(subprocess);
            _ = gobject.Object.unref(subprocess.as(gobject.Object));
        }

        // Convert socket → GIOStream. The factory creates a GSocketConnection
        // that owns a ref on the socket.
        const stream = gio.Socket.connectionFactoryCreateConnection(socket);
        defer _ = gobject.Object.unref(stream.as(gobject.Object));

        const guid = gio.dbusGenerateGuid();
        defer glib.free(guid);

        const flags: gio.DBusConnectionFlags = .{
            .authentication_server = true,
            .authentication_allow_anonymous = true,
        };
        const bus = gio.DBusConnection.newSync(
            stream.as(gio.IOStream),
            guid,
            flags,
            null,
            null,
            &gerr,
        ) orelse {
            log.warn("g_dbus_connection_new_sync: {s}", .{gerrMsg(gerr)});
            if (gerr) |e| glib.Error.free(e);
            return Error.DBusFailed;
        };

        log.info("ptyxis-agent connected (pid={s})", .{
            gio.Subprocess.getIdentifier(subprocess) orelse "?",
        });

        return .{
            .alloc = alloc,
            .subprocess = subprocess,
            .bus = bus,
        };
    }

    /// List containers as a Gio.ListStore of Container GObjects.
    /// Caller owns one ref on the returned store.
    pub fn listAsModel(self: *Client) Error!*gio.ListStore {
        const store = gio.ListStore.new(Container.getGObjectType());
        errdefer _ = gobject.Object.unref(store.as(gobject.Object));

        const infos = try self.listContainers();
        defer {
            for (infos) |*c| {
                var m = c.*;
                m.deinit(self.alloc);
            }
            self.alloc.free(infos);
        }

        for (infos) |info| {
            const obj = try Container.new(
                info.object_path,
                info.id,
                info.provider,
                info.display_name,
            );
            defer obj.unref();
            gio.ListStore.append(store, obj.as(gobject.Object));
        }

        return store;
    }

    /// List containers known to the agent. Caller owns the returned slice.
    pub fn listContainers(self: *Client) Error![]ContainerInfo {
        var gerr: ?*glib.Error = null;
        const reply_type = glib.VariantType.new("(ao)");
        defer glib.VariantType.free(reply_type);

        const reply = gio.DBusConnection.callSync(
            self.bus,
            null, // no bus name (peer-to-peer)
            AGENT_OBJECT_PATH,
            AGENT_IFACE,
            "ListContainers",
            null,
            reply_type,
            .{},
            5000,
            null,
            &gerr,
        ) orelse {
            log.warn("ListContainers: {s}", .{gerrMsg(gerr)});
            if (gerr) |e| glib.Error.free(e);
            return Error.ListContainersFailed;
        };
        defer glib.Variant.unref(reply);

        const paths_v = glib.Variant.getChildValue(reply, 0);
        defer glib.Variant.unref(paths_v);

        var n: usize = 0;
        const paths = glib.Variant.getObjv(paths_v, &n);
        defer glib.free(@ptrCast(@constCast(paths)));

        var list: std.ArrayList(ContainerInfo) = .empty;
        errdefer {
            for (list.items) |*c| c.deinit(self.alloc);
            list.deinit(self.alloc);
        }

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const path: [*:0]const u8 = paths[i] orelse continue;
            const info = self.readContainerProps(std.mem.span(path)) catch |err| {
                log.warn("failed to read props for {s}: {s}", .{ path, @errorName(err) });
                continue;
            };
            try list.append(self.alloc, info);
        }

        return list.toOwnedSlice(self.alloc);
    }

    fn readContainerProps(self: *Client, object_path: [:0]const u8) !ContainerInfo {
        var gerr: ?*glib.Error = null;
        const params = glib.Variant.new("(s)", CONTAINER_IFACE.ptr);
        const reply_type = glib.VariantType.new("(a{sv})");
        defer glib.VariantType.free(reply_type);

        const reply = gio.DBusConnection.callSync(
            self.bus,
            null,
            object_path,
            "org.freedesktop.DBus.Properties",
            "GetAll",
            params,
            reply_type,
            .{},
            5000,
            null,
            &gerr,
        ) orelse {
            if (gerr) |e| glib.Error.free(e);
            return error.PropsFailed;
        };
        defer glib.Variant.unref(reply);

        const dict = glib.Variant.getChildValue(reply, 0);
        defer glib.Variant.unref(dict);

        const id = try self.dupDictStr(dict, "Id");
        errdefer self.alloc.free(id);
        const provider = try self.dupDictStr(dict, "Provider");
        errdefer self.alloc.free(provider);
        const display_name = try self.dupDictStr(dict, "DisplayName");
        errdefer self.alloc.free(display_name);

        const path_dup = try self.alloc.dupeZ(u8, object_path);

        return .{
            .object_path = path_dup,
            .id = id,
            .provider = provider,
            .display_name = display_name,
        };
    }

    fn dupDictStr(self: *Client, dict: *glib.Variant, key: [:0]const u8) ![:0]u8 {
        // Iterate the a{sv} looking for `key`.
        var iter: glib.VariantIter = undefined;
        _ = glib.VariantIter.init(&iter, dict);

        const entry_type = glib.VariantType.new("{sv}");
        defer glib.VariantType.free(entry_type);

        while (glib.VariantIter.nextValue(&iter)) |entry| {
            defer glib.Variant.unref(entry);
            const k_v = glib.Variant.getChildValue(entry, 0);
            defer glib.Variant.unref(k_v);
            const v_v = glib.Variant.getChildValue(entry, 1);
            defer glib.Variant.unref(v_v);

            var k_len: usize = 0;
            const k_ptr = glib.Variant.getString(k_v, &k_len);
            if (std.mem.eql(u8, k_ptr[0..k_len], key)) {
                // v is a variant wrapping the actual value.
                const inner = glib.Variant.getVariant(v_v);
                defer glib.Variant.unref(inner);
                var v_len: usize = 0;
                const v_ptr = glib.Variant.getString(inner, &v_len);
                return try self.alloc.dupeZ(u8, v_ptr[0..v_len]);
            }
        }
        return try self.alloc.dupeZ(u8, "");
    }
};

fn gerrMsg(err: ?*glib.Error) [*:0]const u8 {
    if (err) |e| return e.f_message orelse "(no message)";
    return "(null error)";
}
