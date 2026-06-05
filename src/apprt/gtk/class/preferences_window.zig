//! Ptyxis-style preferences window. Wraps Adw.PreferencesWindow with a
//! template loaded from gresource. The UI binds to a config bridge that
//! reads/writes ~/.config/ghostty/config — not GSettings.

const std = @import("std");

const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const config_bridge = @import("config_bridge.zig");

const log = std.log.scoped(.gtk_ptyxis_preferences);

pub const PreferencesWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.PreferencesWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyPtyxisPreferencesWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        opacity_scale: *gtk.Scale,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Wire opacity slider → ~/.config/ghostty/config writeback.
        const priv = self.private();
        const adj = gtk.Range.getAdjustment(priv.opacity_scale.as(gtk.Range));
        _ = gobject.signalConnectData(
            adj.as(gobject.Object),
            "value-changed",
            @ptrCast(&opacityValueChanged),
            self,
            null,
            .{},
        );
    }

    fn opacityValueChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        _ = self;
        const v = adj.getValue();
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3}", .{v}) catch return;
        const alloc = std.heap.c_allocator;
        config_bridge.setKey(alloc, "background-opacity", slice) catch |err| {
            log.warn("opacity write failed: {s}", .{@errorName(err)});
        };
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "preferences-window",
                }),
            );
            class.bindTemplateChildPrivate("opacity_scale", .{});
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
