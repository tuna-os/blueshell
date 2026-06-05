const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");
const gio = @import("gio");
const glib = @import("glib");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const config_bridge = @import("config_bridge.zig");
const profile_store = @import("profile_store.zig");
const Application = @import("application.zig").Application;
const configpkg = @import("../../../config.zig");
const CoreConfig = configpkg.Config;
const input = @import("../../../input.zig");

const log = std.log.scoped(.gtk_ptyxis_profile_editor);

pub const ProfileEditor = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.PreferencesWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyPtyxisProfileEditor",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"profile-name" = struct {
            pub const name = "profile-name";
            pub const get = impl.get;
            pub const set = impl.set;
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("profile_name"),
                },
            );
        };
    };

    const Private = struct {
        profile_name: ?[:0]const u8 = null,
        profile_path: ?[]const u8 = null,

        // Template bindings
        command_entry: *adw.EntryRow,
        login_shell_row: *adw.SwitchRow,
        exit_action_row: *adw.ComboRow,
        title_prefix_row: *adw.EntryRow,
        use_system_font_switch: *gtk.Switch,
        font_button: *gtk.FontDialogButton,
        opacity_scale: *gtk.Scale,
        bold_is_bright_row: *adw.SwitchRow,
        backspace_row: *adw.ComboRow,
        delete_row: *adw.ComboRow,
        limit_scrollback_row: *adw.SwitchRow,
        scrollback_limit_row: *adw.SpinRow,

        pub var offset: c_int = 0;
    };

    pub fn new(profile_name: [:0]const u8) !*Self {
        const self = gobject.ext.newInstance(Self, .{ .@"profile-name" = profile_name });
        try self.loadProfileValues();
        self.wireSignals();
        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn loadProfileValues(self: *Self) !void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;
        const name = priv.profile_name orelse return error.ProfileNameNotSet;
        priv.profile_path = try profile_store.profilePath(alloc, name);

        var cfg = try CoreConfig.default(alloc);
        defer cfg.deinit();
        _ = cfg.loadOptionalFile(alloc, priv.profile_path.?);

        // Command Entry.
        const cmd = if (cfg.command) |c| switch (c) {
            .shell => |s| s,
            .direct => |arr| if (arr.len > 0) arr[0] else "",
        } else "";
        const cmd_z = try std.fmt.allocPrintZ(alloc, "{s}", .{cmd});
        defer alloc.free(cmd_z);
        priv.command_entry.as(gtk.Editable).setText(cmd_z);

        // Login Shell.
        priv.login_shell_row.setActive(if (cfg.@"login-shell") 1 else 0);

        // Exit Action.
        const ea_idx: c_uint = switch (cfg.@"exit-action") {
            .none => 0,
            .restart => 1,
            .close => 2,
        };
        priv.exit_action_row.setSelected(ea_idx);

        // Title Prefix (Custom Title).
        const title = cfg.title orelse "";
        const title_z = try std.fmt.allocPrintZ(alloc, "{s}", .{title});
        defer alloc.free(title_z);
        priv.title_prefix_row.as(gtk.Editable).setText(title_z);

        // Use System Font: ON when font-family is empty.
        const fam_empty = cfg.@"font-family".list.items.len == 0;
        priv.use_system_font_switch.setActive(if (fam_empty) 1 else 0);

        // Font Button.
        const family_slice = if (cfg.@"font-family".list.items.len > 0) cfg.@"font-family".list.items[0] else "Monospace";
        const font_size = cfg.@"font-size";
        const font_str = try std.fmt.allocPrintZ(alloc, "{s} {d}", .{ family_slice, font_size });
        defer alloc.free(font_str);

        const PangoLibc = struct {
            extern "c" fn pango_font_description_from_string(str: [*:0]const u8) *anyopaque;
            extern "c" fn pango_font_description_free(d: *anyopaque) void;
        };
        const desc = PangoLibc.pango_font_description_from_string(font_str);
        defer PangoLibc.pango_font_description_free(desc);
        priv.font_button.setFontDesc(@ptrCast(desc));

        // Transparency.
        const opacity_adj = gtk.Range.getAdjustment(priv.opacity_scale.as(gtk.Range));
        opacity_adj.setValue(cfg.@"background-opacity");

        // Bold is Bright.
        const bib = if (cfg.@"bold-color") |bc| switch (bc) {
            .bright => true,
            else => false,
        } else false;
        priv.bold_is_bright_row.setActive(if (bib) 1 else 0);

        // Keybindings (Backspace/Delete).
        const backspace_trigger = input.Trigger{ .key = .{ .physical = .backspace } };
        const delete_trigger = input.Trigger{ .key = .{ .physical = .delete } };

        const bs_val = cfg.keybind.set.bindings.get(backspace_trigger);
        const del_val = cfg.keybind.set.bindings.get(delete_trigger);

        const bs_idx: c_uint = if (bs_val) |v| switch (v) {
            .leaf => |l| switch (l.action) {
                .text => |t| if (std.mem.eql(u8, t, "\x7f"))
                    1
                else if (std.mem.eql(u8, t, "\x08"))
                    2
                else if (std.mem.eql(u8, t, "\x1b[3~"))
                    3
                else
                    0,
                else => 0,
            },
            else => 0,
        } else 0;
        priv.backspace_row.setSelected(bs_idx);

        const del_idx: c_uint = if (del_val) |v| switch (v) {
            .leaf => |l| switch (l.action) {
                .text => |t| if (std.mem.eql(u8, t, "\x7f"))
                    1
                else if (std.mem.eql(u8, t, "\x08"))
                    2
                else if (std.mem.eql(u8, t, "\x1b[3~"))
                    3
                else
                    0,
                else => 0,
            },
            else => 0,
        } else 0;
        priv.delete_row.setSelected(del_idx);

        // Scrollback.
        const sb = cfg.@"scrollback-limit";
        priv.limit_scrollback_row.setActive(if (sb > 0) 1 else 0);
        const sb_adj = adw.SpinRow.getAdjustment(priv.scrollback_limit_row);
        if (sb > 0) {
            sb_adj.setValue(@floatFromInt(@min(sb, std.math.maxInt(u32))));
        }
    }

    fn syncActiveProfile(self: *Self) void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;
        const name = priv.profile_name orelse return;
        const active_name = profile_store.activeProfileName(alloc) catch null;
        defer if (active_name) |n| alloc.free(n);

        if (active_name) |an| {
            if (std.mem.eql(u8, an, name)) {
                const dst = config_bridge.resolveConfigPath(alloc) catch return;
                defer alloc.free(dst);
                profile_store.copyFile(alloc, priv.profile_path.?, dst) catch |err| {
                    log.warn("syncActiveProfile failed: {s}", .{@errorName(err)});
                    return;
                };
                Application.default().triggerReload();
            }
        }
    }

    fn commandChanged(editable: *gtk.Editable, self: *Self) callconv(.c) void {
        const priv = self.private();
        const text = std.mem.span(editable.getText());
        config_bridge.setKey(std.heap.c_allocator, "command", text, priv.profile_path) catch |err| {
            log.warn("command write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn loginShellChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        const val = if (row.getActive() != 0) "true" else "false";
        config_bridge.setKey(std.heap.c_allocator, "login-shell", val, priv.profile_path) catch |err| {
            log.warn("login-shell write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn exitActionChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        const idx = row.getSelected();
        const val: []const u8 = switch (idx) {
            0 => "none",
            1 => "restart",
            2 => "close",
            else => return,
        };
        config_bridge.setKey(std.heap.c_allocator, "exit-action", val, priv.profile_path) catch |err| {
            log.warn("exit-action write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn titlePrefixChanged(editable: *gtk.Editable, self: *Self) callconv(.c) void {
        const priv = self.private();
        const text = std.mem.span(editable.getText());
        config_bridge.setKey(std.heap.c_allocator, "title", text, priv.profile_path) catch |err| {
            log.warn("title write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn useSystemFontChanged(sw: *gtk.Switch, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (sw.getActive() != 0) {
            config_bridge.setKey(std.heap.c_allocator, "font-family", "", priv.profile_path) catch |err| {
                log.warn("font-family clear failed: {s}", .{@errorName(err)});
            };
            self.syncActiveProfile();
        }
    }

    fn fontDescChanged(btn: *gtk.FontDialogButton, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        const desc = btn.getFontDesc() orelse return;
        const FdLibc = struct {
            extern "c" fn pango_font_description_to_string(d: *anyopaque) [*:0]u8;
            extern "c" fn pango_font_description_free(d: *anyopaque) void;
            extern "c" fn g_free(p: ?*anyopaque) void;
        };
        defer FdLibc.pango_font_description_free(@ptrCast(desc));
        const str_z = FdLibc.pango_font_description_to_string(@ptrCast(desc));
        defer FdLibc.g_free(@ptrCast(@constCast(str_z)));
        const str = std.mem.span(str_z);

        if (std.mem.lastIndexOfScalar(u8, str, ' ')) |sp| {
            const family = str[0..sp];
            const size = str[sp + 1 ..];
            config_bridge.setKey(std.heap.c_allocator, "font-family", family, priv.profile_path) catch |err| {
                log.warn("font-family write failed: {s}", .{@errorName(err)});
            };
            if (std.fmt.parseFloat(f64, size)) |_| {
                config_bridge.setKey(std.heap.c_allocator, "font-size", size, priv.profile_path) catch |err| {
                    log.warn("font-size write failed: {s}", .{@errorName(err)});
                };
            } else |_| {}
        } else {
            config_bridge.setKey(std.heap.c_allocator, "font-family", str, priv.profile_path) catch |err| {
                log.warn("font-family write failed: {s}", .{@errorName(err)});
            };
        }
        self.syncActiveProfile();
    }

    fn opacityValueChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        const v = adj.getValue();
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3}", .{v}) catch return;
        config_bridge.setKey(std.heap.c_allocator, "background-opacity", slice, priv.profile_path) catch |err| {
            log.warn("background-opacity write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn boldIsBrightChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        const v: []const u8 = if (row.getActive() != 0) "bright" else "";
        config_bridge.setKey(std.heap.c_allocator, "bold-color", v, priv.profile_path) catch |err| {
            log.warn("bold-color write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn backspaceChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        const idx = row.getSelected();
        const maybe_action: ?[]const u8 = switch (idx) {
            0 => null,
            1 => "text:\\x7f",
            2 => "text:\\x08",
            3 => "text:\\x1b[3~",
            else => return,
        };
        config_bridge.setKeybind(std.heap.c_allocator, "backspace", maybe_action, priv.profile_path) catch |err| {
            log.warn("backspace keybind write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn deleteChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        const idx = row.getSelected();
        const maybe_action: ?[]const u8 = switch (idx) {
            0 => null,
            1 => "text:\\x7f",
            2 => "text:\\x08",
            3 => "text:\\x1b[3~",
            else => return,
        };
        config_bridge.setKeybind(std.heap.c_allocator, "delete", maybe_action, priv.profile_path) catch |err| {
            log.warn("delete keybind write failed: {s}", .{@errorName(err)});
        };
        self.syncActiveProfile();
    }

    fn limitScrollbackChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (row.getActive() != 0) {
            const v = adw.SpinRow.getAdjustment(priv.scrollback_limit_row).getValue();
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d:.0}", .{v}) catch return;
            config_bridge.setKey(std.heap.c_allocator, "scrollback-limit", slice, priv.profile_path) catch |err| {
                log.warn("scrollback-limit write failed: {s}", .{@errorName(err)});
            };
        } else {
            config_bridge.setKey(std.heap.c_allocator, "scrollback-limit", "0", priv.profile_path) catch |err| {
                log.warn("scrollback-limit write failed: {s}", .{@errorName(err)});
            };
        }
        self.syncActiveProfile();
    }

    fn scrollbackLimitSpinChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.limit_scrollback_row.getActive() != 0) {
            const v = adj.getValue();
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d:.0}", .{v}) catch return;
            config_bridge.setKey(std.heap.c_allocator, "scrollback-limit", slice, priv.profile_path) catch |err| {
                log.warn("scrollback-limit write failed: {s}", .{@errorName(err)});
            };
            self.syncActiveProfile();
        }
    }

    fn wireSignals(self: *Self) void {
        const priv = self.private();

        _ = gobject.signalConnectData(
            priv.command_entry.as(gobject.Object),
            "changed",
            @ptrCast(&commandChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.login_shell_row.as(gobject.Object),
            "notify::active",
            @ptrCast(&loginShellChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.exit_action_row.as(gobject.Object),
            "notify::selected",
            @ptrCast(&exitActionChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.title_prefix_row.as(gobject.Object),
            "changed",
            @ptrCast(&titlePrefixChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.use_system_font_switch.as(gobject.Object),
            "notify::active",
            @ptrCast(&useSystemFontChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.font_button.as(gobject.Object),
            "notify::font-desc",
            @ptrCast(&fontDescChanged),
            self,
            null,
            .{},
        );

        const opacity_adj = gtk.Range.getAdjustment(priv.opacity_scale.as(gtk.Range));
        _ = gobject.signalConnectData(
            opacity_adj.as(gobject.Object),
            "value-changed",
            @ptrCast(&opacityValueChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.bold_is_bright_row.as(gobject.Object),
            "notify::active",
            @ptrCast(&boldIsBrightChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.backspace_row.as(gobject.Object),
            "notify::selected",
            @ptrCast(&backspaceChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.delete_row.as(gobject.Object),
            "notify::selected",
            @ptrCast(&deleteChanged),
            self,
            null,
            .{},
        );

        _ = gobject.signalConnectData(
            priv.limit_scrollback_row.as(gobject.Object),
            "notify::active",
            @ptrCast(&limitScrollbackChanged),
            self,
            null,
            .{},
        );

        const sb_adj = adw.SpinRow.getAdjustment(priv.scrollback_limit_row);
        _ = gobject.signalConnectData(
            sb_adj.as(gobject.Object),
            "value-changed",
            @ptrCast(&scrollbackLimitSpinChanged),
            self,
            null,
            .{},
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.profile_name) |v| {
            glib.free(@ptrCast(@constCast(v)));
        }
        if (priv.profile_path) |v| {
            std.heap.c_allocator.free(v);
        }

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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "profile-editor",
                }),
            );

            class.bindTemplateChildPrivate("command_entry", .{});
            class.bindTemplateChildPrivate("login_shell_row", .{});
            class.bindTemplateChildPrivate("exit_action_row", .{});
            class.bindTemplateChildPrivate("title_prefix_row", .{});
            class.bindTemplateChildPrivate("use_system_font_switch", .{});
            class.bindTemplateChildPrivate("font_button", .{});
            class.bindTemplateChildPrivate("opacity_scale", .{});
            class.bindTemplateChildPrivate("bold_is_bright_row", .{});
            class.bindTemplateChildPrivate("backspace_row", .{});
            class.bindTemplateChildPrivate("delete_row", .{});
            class.bindTemplateChildPrivate("limit_scrollback_row", .{});
            class.bindTemplateChildPrivate("scrollback_limit_row", .{});

            gobject.ext.registerProperties(class, &.{
                properties.@"profile-name".impl,
            });

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
