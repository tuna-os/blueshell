//! GObject wrapper around a single container reported by ptyxis-agent.
//! Used as `Gio.ListStore` items for the container picker. Stores the four
//! identifying strings; nothing else is needed for picker display.

const std = @import("std");
const Allocator = std.mem.Allocator;

const gobject = @import("gobject");

const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ptyxis_container);

/// Strings are allocated with the c_allocator because their lifetime is tied
/// to GObject refcounting, which Zig's testing/page allocators can't track.
const alloc = std.heap.c_allocator;

pub const Container = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyPtyxisContainer",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"object-path" = gobject.ext.defineProperty(
            "object-path",
            Self,
            ?[:0]const u8,
            .{ .default = null, .accessor = C.privateStringFieldAccessor("object_path") },
        );
        pub const id = gobject.ext.defineProperty(
            "id",
            Self,
            ?[:0]const u8,
            .{ .default = null, .accessor = C.privateStringFieldAccessor("id") },
        );
        pub const provider = gobject.ext.defineProperty(
            "provider",
            Self,
            ?[:0]const u8,
            .{ .default = null, .accessor = C.privateStringFieldAccessor("provider") },
        );
        pub const @"display-name" = gobject.ext.defineProperty(
            "display-name",
            Self,
            ?[:0]const u8,
            .{ .default = null, .accessor = C.privateStringFieldAccessor("display_name") },
        );
        pub const @"icon-name" = gobject.ext.defineProperty(
            "icon-name",
            Self,
            ?[:0]const u8,
            .{ .default = null, .accessor = C.privateStringFieldAccessor("icon_name") },
        );
    };

    const Private = struct {
        object_path: ?[:0]const u8 = null,
        id: ?[:0]const u8 = null,
        provider: ?[:0]const u8 = null,
        display_name: ?[:0]const u8 = null,
        icon_name: ?[:0]const u8 = null,

        pub var offset: c_int = 0;
    };

    /// Create a new Container wrapping copies of the given strings. The
    /// originals can be freed by the caller after this call returns.
    pub fn new(
        object_path: []const u8,
        id: []const u8,
        provider: []const u8,
        display_name: []const u8,
        icon_name: []const u8,
    ) Allocator.Error!*Self {
        const self = gobject.ext.newInstance(Self, .{});
        errdefer self.unref();

        const priv = self.private();
        priv.object_path = try alloc.dupeZ(u8, object_path);
        priv.id = try alloc.dupeZ(u8, id);
        priv.provider = try alloc.dupeZ(u8, provider);
        priv.display_name = try alloc.dupeZ(u8, display_name);
        priv.icon_name = try alloc.dupeZ(u8, icon_name);

        return self;
    }

    pub fn objectPath(self: *Self) ?[:0]const u8 {
        return self.private().object_path;
    }
    pub fn getId(self: *Self) ?[:0]const u8 {
        return self.private().id;
    }
    pub fn getProvider(self: *Self) ?[:0]const u8 {
        return self.private().provider;
    }
    pub fn getDisplayName(self: *Self) ?[:0]const u8 {
        return self.private().display_name;
    }
    pub fn getIconName(self: *Self) ?[:0]const u8 {
        return self.private().icon_name;
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.object_path) |s| alloc.free(s);
        if (priv.id) |s| alloc.free(s);
        if (priv.provider) |s| alloc.free(s);
        if (priv.display_name) |s| alloc.free(s);
        if (priv.icon_name) |s| alloc.free(s);
        priv.* = .{};

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
            gobject.ext.registerProperties(class, &.{
                properties.@"object-path",
                properties.id,
                properties.provider,
                properties.@"display-name",
                properties.@"icon-name",
            });
        }
    };
};
