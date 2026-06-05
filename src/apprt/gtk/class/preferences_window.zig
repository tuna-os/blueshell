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
const palette_mod = @import("palette.zig");
const profile_store = @import("profile_store.zig");
const Application = @import("application.zig").Application;
const gio = @import("gio");
const glib = @import("glib");

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
        palette_flowbox: *gtk.FlowBox,
        cursor_shape_row: *adw.ComboRow,
        cursor_blinking_row: *adw.ComboRow,
        audible_bell_row: *adw.SwitchRow,
        attention_bell_row: *adw.SwitchRow,
        bold_is_bright_row: *adw.SwitchRow,
        limit_scrollback_row: *adw.SwitchRow,
        scrollback_limit_row: *adw.SpinRow,
        font_button: *gtk.FontDialogButton,
        line_spacing_row: *adw.SpinRow,
        column_spacing_row: *adw.SpinRow,
        tab_position_row: *adw.ComboRow,
        use_system_font_switch: *gtk.Switch,
        profiles_listbox: *gtk.ListBox,
        add_profile_button: *gtk.Button,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // Install per-window actions for the profile row menus (so menu
        // items can reference prefs.profile-save / prefs.profile-delete).
        installProfileActions(self);

        // Load current values from the in-memory config before wiring
        // signals so we don't trigger spurious writebacks.
        loadCurrentValues(self);

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

        // Populate palette flowbox.
        populatePalettes(priv.palette_flowbox) catch |err| {
            log.warn("populatePalettes failed: {s}", .{@errorName(err)});
        };

        // Behavior + cursor rows: write to config on change.
        _ = gobject.signalConnectData(
            priv.cursor_shape_row.as(gobject.Object),
            "notify::selected",
            @ptrCast(&cursorShapeChanged),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            priv.cursor_blinking_row.as(gobject.Object),
            "notify::selected",
            @ptrCast(&cursorBlinkingChanged),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            priv.audible_bell_row.as(gobject.Object),
            "notify::active",
            @ptrCast(&audibleBellChanged),
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
            adw.SpinRow.getAdjustment(priv.scrollback_limit_row).as(gobject.Object),
            "value-changed",
            @ptrCast(&scrollbackLimitChanged),
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
        _ = gobject.signalConnectData(
            priv.attention_bell_row.as(gobject.Object),
            "notify::active",
            @ptrCast(&attentionBellChanged),
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
        _ = gobject.signalConnectData(
            adw.SpinRow.getAdjustment(priv.line_spacing_row).as(gobject.Object),
            "value-changed",
            @ptrCast(&lineSpacingChanged),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            adw.SpinRow.getAdjustment(priv.column_spacing_row).as(gobject.Object),
            "value-changed",
            @ptrCast(&columnSpacingChanged),
            self,
            null,
            .{},
        );
        _ = gobject.signalConnectData(
            priv.tab_position_row.as(gobject.Object),
            "notify::selected",
            @ptrCast(&tabPositionChanged),
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

        // Profiles page: populate and wire the Add button.
        populateProfiles(self);
        _ = gobject.signalConnectData(
            priv.add_profile_button.as(gobject.Object),
            "clicked",
            @ptrCast(&addProfileClicked),
            self,
            null,
            .{},
        );
    }

    fn installProfileActions(self: *Self) void {
        const group = gio.SimpleActionGroup.new();
        const param_s = glib.VariantType.new("s");
        defer param_s.free();

        const save_action = gio.SimpleAction.new("profile-save", param_s);
        _ = gobject.signalConnectData(
            save_action.as(gobject.Object),
            "activate",
            @ptrCast(&profileSaveActivated),
            self,
            null,
            .{},
        );
        group.as(gio.ActionMap).addAction(save_action.as(gio.Action));
        _ = gobject.Object.unref(save_action.as(gobject.Object));

        const del_action = gio.SimpleAction.new("profile-delete", param_s);
        _ = gobject.signalConnectData(
            del_action.as(gobject.Object),
            "activate",
            @ptrCast(&profileDeleteActivated),
            self,
            null,
            .{},
        );
        group.as(gio.ActionMap).addAction(del_action.as(gio.Action));
        _ = gobject.Object.unref(del_action.as(gobject.Object));

        const edit_action = gio.SimpleAction.new("profile-edit", param_s);
        _ = gobject.signalConnectData(
            edit_action.as(gobject.Object),
            "activate",
            @ptrCast(&profileEditActivated),
            self,
            null,
            .{},
        );
        group.as(gio.ActionMap).addAction(edit_action.as(gio.Action));
        _ = gobject.Object.unref(edit_action.as(gobject.Object));

        self.as(gtk.Widget).insertActionGroup("prefs", group.as(gio.ActionGroup));
        _ = gobject.Object.unref(group.as(gobject.Object));
    }

    fn profileSaveActivated(
        _: *gio.SimpleAction,
        parameter: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const p = parameter orelse return;
        var len: usize = 0;
        const c_ptr = glib.Variant.getString(p, &len);
        const name = c_ptr[0..len];
        profile_store.updateFromActive(std.heap.c_allocator, name) catch |err| {
            log.warn("profile save({s}) failed: {s}", .{ name, @errorName(err) });
            return;
        };
        populateProfiles(self);
    }

    fn profileDeleteActivated(
        _: *gio.SimpleAction,
        parameter: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const p = parameter orelse return;
        var len: usize = 0;
        const c_ptr = glib.Variant.getString(p, &len);
        const name = c_ptr[0..len];
        profile_store.delete(std.heap.c_allocator, name) catch |err| {
            log.warn("profile delete({s}) failed: {s}", .{ name, @errorName(err) });
            return;
        };
        populateProfiles(self);
    }

    fn profileEditActivated(
        _: *gio.SimpleAction,
        parameter: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const p = parameter orelse return;
        var len: usize = 0;
        const c_ptr = glib.Variant.getString(p, &len);
        const name = c_ptr[0..len];
        const name_z = std.heap.c_allocator.dupeZ(u8, name) catch return;
        defer std.heap.c_allocator.free(name_z);

        const ProfileEditor = @import("profile_editor.zig").ProfileEditor;
        const editor = ProfileEditor.new(name_z) catch |err| {
            log.warn("failed to open profile editor: {s}", .{@errorName(err)});
            return;
        };
        editor.as(gtk.Window).setTransientFor(self.as(gtk.Window));
        editor.as(gtk.Window).present();
    }

    fn populateProfiles(self: *Self) void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;

        // Clear existing rows.
        while (priv.profiles_listbox.as(gtk.Widget).getFirstChild()) |child| {
            priv.profiles_listbox.remove(@ptrCast(child));
        }

        const profiles = profile_store.list(alloc) catch |err| {
            log.warn("profile list failed: {s}", .{@errorName(err)});
            return;
        };
        defer {
            for (profiles) |p| p.deinit(alloc);
            alloc.free(profiles);
        }

        if (profiles.len == 0) {
            // Empty-state row.
            const row = adw.ActionRow.new();
            row.as(adw.PreferencesRow).setTitle("No profiles yet");
            row.setSubtitle("Click Add to snapshot the current settings");
            row.as(gtk.ListBoxRow).setActivatable(0);
            priv.profiles_listbox.append(row.as(gtk.Widget));
            return;
        }

        for (profiles) |p| {
            const row = adw.ActionRow.new();
            const name_z = alloc.dupeZ(u8, p.name) catch continue;
            // Keep name_z alive for the row's lifetime by attaching it as
            // GObject data; freed in finalize handler.
            gobject.Object.setDataFull(
                row.as(gobject.Object),
                "ptyxis-profile-name",
                @ptrCast(@constCast(name_z.ptr)),
                &freeCString,
            );
            row.as(adw.PreferencesRow).setTitle(name_z.ptr);
            row.as(gtk.ListBoxRow).setActivatable(1);

            if (p.active) {
                const check = gtk.Image.newFromIconName("object-select-symbolic");
                row.addSuffix(check.as(gtk.Widget));
            }

            // Per-row action menu (Edit / Save Changes / Delete).
            const menu = gio.Menu.new();

            const edit_item = gio.MenuItem.new("Edit…", null);
            edit_item.setActionAndTargetValue(
                "prefs.profile-edit",
                glib.Variant.newString(name_z.ptr),
            );
            menu.appendItem(edit_item);
            _ = gobject.Object.unref(edit_item.as(gobject.Object));

            const save_item = gio.MenuItem.new("Save Changes", null);
            save_item.setActionAndTargetValue(
                "prefs.profile-save",
                glib.Variant.newString(name_z.ptr),
            );
            menu.appendItem(save_item);
            _ = gobject.Object.unref(save_item.as(gobject.Object));

            const del_item = gio.MenuItem.new("Delete", null);
            del_item.setActionAndTargetValue(
                "prefs.profile-delete",
                glib.Variant.newString(name_z.ptr),
            );
            menu.appendItem(del_item);
            _ = gobject.Object.unref(del_item.as(gobject.Object));

            const menu_btn = gtk.MenuButton.new();
            menu_btn.setIconName("view-more-symbolic");
            menu_btn.setMenuModel(menu.as(gio.MenuModel));
            menu_btn.as(gtk.Widget).addCssClass("flat");
            menu_btn.as(gtk.Widget).setValign(.center);
            row.addSuffix(menu_btn.as(gtk.Widget));
            _ = gobject.Object.unref(menu.as(gobject.Object));

            priv.profiles_listbox.append(row.as(gtk.Widget));
        }

        // Row activation = switch profile.
        _ = gobject.signalConnectData(
            priv.profiles_listbox.as(gobject.Object),
            "row-activated",
            @ptrCast(&profileRowActivated),
            self,
            null,
            .{ .after = true }, // skip duplicate hookup on rebuild
        );
    }

    fn freeCString(p: ?*anyopaque) callconv(.c) void {
        const ptr = p orelse return;
        const c_ptr: [*:0]u8 = @ptrCast(ptr);
        const slice = std.mem.span(c_ptr);
        std.heap.c_allocator.free(slice);
    }

    fn profileRowActivated(
        _: *gtk.ListBox,
        row: *gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        const data = gobject.Object.getData(
            row.as(gobject.Object),
            "ptyxis-profile-name",
        ) orelse return;
        const c_ptr: [*:0]const u8 = @ptrCast(data);
        const name = std.mem.span(c_ptr);
        profile_store.switchTo(std.heap.c_allocator, name) catch |err| {
            log.warn("profile switchTo({s}) failed: {s}", .{ name, @errorName(err) });
            return;
        };
        Application.default().triggerReload();
        // Re-populate so the active marker moves to the new row.
        populateProfiles(self);
        // Reload the row widgets to reflect the new config too.
        loadCurrentValues(self);
    }

    fn addProfileClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        // Generate a unique default name profile-N; user can rename later
        // via direct file ops. (A rename dialog can come in a follow-up.)
        const alloc = std.heap.c_allocator;
        const profiles = profile_store.list(alloc) catch |err| {
            log.warn("addProfile list failed: {s}", .{@errorName(err)});
            return;
        };
        defer {
            for (profiles) |p| p.deinit(alloc);
            alloc.free(profiles);
        }
        var i: usize = profiles.len + 1;
        const name = while (true) : (i += 1) {
            var buf: [32]u8 = undefined;
            const candidate = std.fmt.bufPrint(&buf, "profile-{d}", .{i}) catch return;
            var taken = false;
            for (profiles) |p| {
                if (std.mem.eql(u8, p.name, candidate)) {
                    taken = true;
                    break;
                }
            }
            if (!taken) {
                break alloc.dupe(u8, candidate) catch return;
            }
        };
        defer alloc.free(name);
        profile_store.add(alloc, name) catch |err| {
            log.warn("profile add({s}) failed: {s}", .{ name, @errorName(err) });
            return;
        };
        populateProfiles(self);
    }

    fn attentionBellChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        // bell-features is a packed-struct list. We write a deterministic
        // list of feature names based on the two switches we expose
        // (audible/attention) plus the title default Ptyxis users expect.
        const audible_on = priv.audible_bell_row.getActive() != 0;
        const attention_on = row.getActive() != 0;
        writeBellFeatures(audible_on, attention_on);
    }

    fn writeBellFeatures(audible: bool, attention: bool) void {
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        if (audible) {
            const w = "audio";
            std.mem.copyForwards(u8, buf[n..], w);
            n += w.len;
        }
        if (attention) {
            if (n > 0) {
                buf[n] = ',';
                n += 1;
            }
            const w = "attention";
            std.mem.copyForwards(u8, buf[n..], w);
            n += w.len;
        }
        // Title flash is sensible default; preserve.
        if (n > 0) {
            buf[n] = ',';
            n += 1;
        }
        std.mem.copyForwards(u8, buf[n..], "title");
        n += "title".len;
        config_bridge.setKey(std.heap.c_allocator, "bell-features", buf[0..n], null) catch |err| {
            log.warn("bell-features write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn limitScrollbackChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        if (row.getActive() != 0) {
            // Re-apply the current spin value.
            const v = adw.SpinRow.getAdjustment(priv.scrollback_limit_row).getValue();
            var buf: [32]u8 = undefined;
            const slice = std.fmt.bufPrint(&buf, "{d:.0}", .{v}) catch return;
            config_bridge.setKey(std.heap.c_allocator, "scrollback-limit", slice, null) catch |err| {
                log.warn("scrollback-limit write: {s}", .{@errorName(err)});
                return;
            };
        } else {
            // 0 means unlimited per Ghostty docs.
            config_bridge.setKey(std.heap.c_allocator, "scrollback-limit", "0", null) catch |err| {
                log.warn("scrollback-limit write: {s}", .{@errorName(err)});
                return;
            };
        }
        Application.default().triggerReload();
    }

    fn lineSpacingChanged(adj: *gtk.Adjustment, _: *Self) callconv(.c) void {
        const v = adj.getValue();
        const pct = (v - 1.0) * 100.0;
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.0}%", .{pct}) catch return;
        config_bridge.setKey(std.heap.c_allocator, "adjust-cell-height", slice, null) catch |err| {
            log.warn("adjust-cell-height write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn columnSpacingChanged(adj: *gtk.Adjustment, _: *Self) callconv(.c) void {
        const v = adj.getValue();
        const pct = (v - 1.0) * 100.0;
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.0}%", .{pct}) catch return;
        config_bridge.setKey(std.heap.c_allocator, "adjust-cell-width", slice, null) catch |err| {
            log.warn("adjust-cell-width write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn tabPositionChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        const i = row.getSelected();
        const value: []const u8 = switch (i) {
            0 => "current",
            1 => "end",
            else => return,
        };
        config_bridge.setKey(std.heap.c_allocator, "window-new-tab-position", value, null) catch |err| {
            log.warn("window-new-tab-position write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn useSystemFontChanged(sw: *gtk.Switch, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        // No Ghostty config key tracks "use system font" directly. When
        // toggled ON we clear font-family so Ghostty falls back to its
        // built-in/system default. When toggled OFF we leave the value
        // alone — the FontDialogButton will write a new one on next pick.
        if (sw.getActive() != 0) {
            config_bridge.setKey(std.heap.c_allocator, "font-family", "", null) catch |err| {
                log.warn("font-family clear: {s}", .{@errorName(err)});
                return;
            };
            Application.default().triggerReload();
        }
    }

    fn fontDescChanged(btn: *gtk.FontDialogButton, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
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
        // Pango format is "Family[,Family…] Size" e.g. "JetBrains Mono 13"
        // Ghostty config wants font-family + font-size separately.
        if (std.mem.lastIndexOfScalar(u8, str, ' ')) |sp| {
            const family = str[0..sp];
            const size = str[sp + 1 ..];
            config_bridge.setKey(std.heap.c_allocator, "font-family", family, null) catch |err| {
                log.warn("font-family write: {s}", .{@errorName(err)});
            };
            // Only write size if it parses as a number.
            if (std.fmt.parseFloat(f64, size)) |_| {
                config_bridge.setKey(std.heap.c_allocator, "font-size", size, null) catch |err| {
                    log.warn("font-size write: {s}", .{@errorName(err)});
                };
            } else |_| {}
        } else {
            config_bridge.setKey(std.heap.c_allocator, "font-family", str, null) catch |err| {
                log.warn("font-family write: {s}", .{@errorName(err)});
            };
        }
        Application.default().triggerReload();
    }

    /// Populate row widgets from the Application's current Config.
    fn loadCurrentValues(self: *Self) void {
        const priv = self.private();
        const app = Application.default();
        const cfg = app.getConfig().get();

        // Opacity.
        const adj = gtk.Range.getAdjustment(priv.opacity_scale.as(gtk.Range));
        adj.setValue(cfg.@"background-opacity");

        // Cursor style (block / bar / underline → indices 0 / 1 / 2).
        const cs_idx: c_uint = switch (cfg.@"cursor-style") {
            .block, .block_hollow => 0,
            .bar => 1,
            .underline => 2,
        };
        priv.cursor_shape_row.setSelected(cs_idx);

        // Cursor blink (true → "On" index 1, false → "Off" index 2, null → "Follow System" index 0).
        const blink_idx: c_uint = if (cfg.@"cursor-style-blink") |b| (if (b) 1 else 2) else 0;
        priv.cursor_blinking_row.setSelected(blink_idx);

        // Scrollback. "Limit Scrollback" is ON when limit > 0.
        const sb = cfg.@"scrollback-limit";
        priv.limit_scrollback_row.setActive(if (sb > 0) 1 else 0);
        const sb_adj = adw.SpinRow.getAdjustment(priv.scrollback_limit_row);
        if (sb > 0) {
            sb_adj.setValue(@floatFromInt(@min(sb, std.math.maxInt(u32))));
        }

        // Cell spacing — Ghostty stores adjust-cell-{height,width} as an
        // optional MetricModifier. Treat the absent case as 1.0× (no
        // adjustment) and only attempt percentage display for the
        // .percent variant.
        priv.line_spacing_row.setValue(spacingValueFromConfig(cfg.@"adjust-cell-height"));
        priv.column_spacing_row.setValue(spacingValueFromConfig(cfg.@"adjust-cell-width"));

        // Tab position.
        priv.tab_position_row.setSelected(switch (cfg.@"window-new-tab-position") {
            .current => 0,
            .end => 1,
        });

        // Use system font: ON when font-family is empty.
        const fam_empty = cfg.@"font-family".list.items.len == 0;
        priv.use_system_font_switch.setActive(if (fam_empty) 1 else 0);

        // Bell features.
        const bf = cfg.@"bell-features";
        priv.audible_bell_row.setActive(if (bf.audio) 1 else 0);
        priv.attention_bell_row.setActive(if (bf.attention) 1 else 0);

        // Bold-is-bright: ON iff bold-color resolves to .bright.
        const bib = if (cfg.@"bold-color") |bc| switch (bc) {
            .bright => true,
            else => false,
        } else false;
        priv.bold_is_bright_row.setActive(if (bib) 1 else 0);
    }

    fn spacingValueFromConfig(mm: anytype) f64 {
        const opt = mm orelse return 1.0;
        return switch (opt) {
            .percent => |p| 1.0 + @as(f64, @floatCast(p)) / 100.0,
            else => 1.0,
        };
    }

    fn cursorShapeChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        const i = row.getSelected();
        const value: []const u8 = switch (i) {
            0 => "block",
            1 => "bar",
            2 => "underline",
            else => return,
        };
        config_bridge.setKey(std.heap.c_allocator, "cursor-style", value, null) catch |err| {
            log.warn("cursor-style write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn cursorBlinkingChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        const i = row.getSelected();
        const value: []const u8 = switch (i) {
            0 => "true", // Follow System ≈ default on
            1 => "true",
            2 => "false",
            else => return,
        };
        config_bridge.setKey(std.heap.c_allocator, "cursor-style-blink", value, null) catch |err| {
            log.warn("cursor-style-blink write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn audibleBellChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        const priv = self.private();
        const audible_on = row.getActive() != 0;
        const attention_on = priv.attention_bell_row.getActive() != 0;
        writeBellFeatures(audible_on, attention_on);
    }

    fn boldIsBrightChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        // Ghostty's bold-color = bright maps bold to bright ANSI colors.
        // When OFF, clear the key (Ghostty default: no bold-color override).
        const v: []const u8 = if (row.getActive() != 0) "bright" else "";
        config_bridge.setKey(std.heap.c_allocator, "bold-color", v, null) catch |err| {
            log.warn("bold-color write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn scrollbackLimitChanged(adj: *gtk.Adjustment, _: *Self) callconv(.c) void {
        const v = adj.getValue();
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.0}", .{v}) catch return;
        config_bridge.setKey(std.heap.c_allocator, "scrollback-limit", slice, null) catch |err| {
            log.warn("scrollback-limit write: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn opacityValueChanged(adj: *gtk.Adjustment, self: *Self) callconv(.c) void {
        _ = self;
        const v = adj.getValue();
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.3}", .{v}) catch return;
        const alloc = std.heap.c_allocator;
        config_bridge.setKey(alloc, "background-opacity", slice, null) catch |err| {
            log.warn("opacity write failed: {s}", .{@errorName(err)});
            return;
        };
        Application.default().triggerReload();
    }

    fn populatePalettes(flowbox: *gtk.FlowBox) !void {
        const alloc = std.heap.c_allocator;
        const palettes = try palette_mod.loadAll(alloc);
        defer alloc.free(palettes);

        // Build one big stylesheet that names each card + each dot by
        // index. Sharing one class name across cards loses styles because
        // GTK keeps only the last provider's value for a given selector
        // — give every card a unique class.
        var css = std.ArrayList(u8){};
        defer css.deinit(alloc);

        // Card base rules.
        try css.appendSlice(alloc,
            \\.ptyxis-pal-card {
            \\  border-radius: 9px;
            \\  padding: 6px;
            \\}
            \\.ptyxis-pal-card .heading { font-weight: 600; }
            \\.ptyxis-pal-card .muted { font-style: italic; font-family: monospace; }
            \\.ptyxis-pal-dot { border-radius: 5px; min-width: 14px; min-height: 14px; }
            \\
        );

        for (palettes, 0..) |p, idx| {
            const v: *const palette_mod.Variant = if (p.dark.background != null) &p.dark else &p.light;
            const bg = v.background orelse palette_mod.RGB{ .r = 0x20, .g = 0x20, .b = 0x20 };
            const fg = v.foreground orelse palette_mod.RGB{ .r = 0xe0, .g = 0xe0, .b = 0xe0 };
            const muted = palette_mod.RGB{
                .r = @intCast((@as(u16, fg.r) + @as(u16, bg.r) * 2) / 3),
                .g = @intCast((@as(u16, fg.g) + @as(u16, bg.g) * 2) / 3),
                .b = @intCast((@as(u16, fg.b) + @as(u16, bg.b) * 2) / 3),
            };
            // Per-card colors.
            try css.writer(alloc).print(
                \\.pp-card-{d} {{ background: #{x:0>2}{x:0>2}{x:0>2}; }}
                \\.pp-card-{d} label {{ color: #{x:0>2}{x:0>2}{x:0>2}; }}
                \\.pp-card-{d} label.muted {{ color: #{x:0>2}{x:0>2}{x:0>2}; }}
                \\
            , .{
                idx, bg.r,    bg.g,    bg.b,
                idx, fg.r,    fg.g,    fg.b,
                idx, muted.r, muted.g, muted.b,
            });
            // Per-dot rules for the 6 indices we render.
            const want: [6]u4 = .{ 1, 2, 3, 4, 5, 6 };
            for (want) |ci| {
                const c = v.colors[ci] orelse continue;
                try css.writer(alloc).print(
                    ".pp-card-{d} .pp-dot-{d} {{ background: #{x:0>2}{x:0>2}{x:0>2}; }}\n",
                    .{ idx, ci, c.r, c.g, c.b },
                );
            }
        }

        const css_z = try alloc.dupeZ(u8, css.items);
        defer alloc.free(css_z);

        const provider = gtk.CssProvider.new();
        _ = provider.loadFromString(css_z.ptr);
        gtk.StyleContext.addProviderForDisplay(
            gtk.Widget.getDisplay(flowbox.as(gtk.Widget)),
            provider.as(gtk.StyleProvider),
            800,
        );
        _ = gobject.Object.unref(provider.as(gobject.Object));

        for (palettes, 0..) |p, idx| {
            const card = makePaletteCard(p, idx) orelse continue;
            flowbox.append(card.as(gtk.Widget));
        }

        log.info("populated {d} palettes in flowbox", .{palettes.len});
    }

    /// Build a single Ptyxis-style palette swatch card. The shared
    /// stylesheet installed by populatePalettes provides the colors via
    /// the unique `pp-card-{idx}` class.
    fn makePaletteCard(p: palette_mod.Palette, idx: usize) ?*gtk.Button {
        const v: *const palette_mod.Variant = if (p.dark.background != null) &p.dark else &p.light;

        // Outer vertical box: name (top), sample (middle), color strip (bottom).
        const box = gtk.Box.new(gtk.Orientation.vertical, 8);
        box.as(gtk.Widget).setHexpand(1);
        box.as(gtk.Widget).setVexpand(0);
        box.as(gtk.Widget).setMarginTop(14);
        box.as(gtk.Widget).setMarginBottom(14);
        box.as(gtk.Widget).setMarginStart(14);
        box.as(gtk.Widget).setMarginEnd(14);

        // Click-target wraps the box. Per-card CSS class comes from the
        // shared stylesheet built in populatePalettes.
        const btn = gtk.Button.new();
        btn.setChild(box.as(gtk.Widget));
        btn.as(gtk.Widget).addCssClass("flat");
        btn.as(gtk.Widget).addCssClass("ptyxis-pal-card");
        var class_buf: [32]u8 = undefined;
        const cls_z = std.fmt.bufPrintZ(&class_buf, "pp-card-{d}", .{idx}) catch return null;
        btn.as(gtk.Widget).addCssClass(cls_z.ptr);

        // Name row.
        const name_z = std.heap.c_allocator.dupeZ(u8, p.name) catch return null;
        defer std.heap.c_allocator.free(name_z);
        const name_label = gtk.Label.new(name_z.ptr);
        name_label.setXalign(0);
        name_label.setEllipsize(.middle);
        name_label.as(gtk.Widget).setHexpand(1);
        name_label.as(gtk.Widget).addCssClass("heading");
        box.append(name_label.as(gtk.Widget));

        // Sample paragraph in italic muted style.
        const sample = gtk.Label.new("The quick brown\nfox jumps over\nthe lazy dog");
        sample.setXalign(0);
        sample.setWrap(1);
        sample.as(gtk.Widget).setHexpand(1);
        sample.as(gtk.Widget).addCssClass("muted");
        box.append(sample.as(gtk.Widget));

        // Color strip — 6 representative ANSI colors 1..6 (red/green/
        // yellow/blue/magenta/cyan), matching Ptyxis's dot row exactly.
        const strip = gtk.Box.new(gtk.Orientation.horizontal, 6);
        strip.as(gtk.Widget).setMarginTop(4);
        strip.as(gtk.Widget).setHexpand(1);
        const want: [6]u4 = .{ 1, 2, 3, 4, 5, 6 };
        for (want) |ci| {
            if (v.colors[ci] == null) continue;
            const dot = gtk.Box.new(gtk.Orientation.horizontal, 0);
            dot.as(gtk.Widget).setSizeRequest(-1, 14);
            dot.as(gtk.Widget).setHexpand(1);
            dot.as(gtk.Widget).addCssClass("pp-dot");
            var dbuf: [32]u8 = undefined;
            const dot_cls = std.fmt.bufPrintZ(&dbuf, "pp-dot-{d}", .{ci}) catch continue;
            dot.as(gtk.Widget).addCssClass(dot_cls.ptr);
            strip.append(dot.as(gtk.Widget));
        }
        box.append(strip.as(gtk.Widget));

        // Tooltip + id payload for the click handler.
        btn.as(gtk.Widget).setTooltipText(name_z.ptr);
        const id_z = std.heap.c_allocator.dupeZ(u8, p.id) catch return null;
        gobject.Object.setData(btn.as(gobject.Object), "ptyxis-palette-id", @ptrCast(@constCast(id_z.ptr)));

        _ = gobject.signalConnectData(
            btn.as(gobject.Object),
            "clicked",
            @ptrCast(&onPaletteClicked),
            null,
            null,
            .{},
        );

        return btn;
    }

    fn onPaletteClicked(btn: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const ptr = gobject.Object.getData(btn.as(gobject.Object), "ptyxis-palette-id") orelse return;
        const id_cstr: [*:0]const u8 = @ptrCast(ptr);
        const id = std.mem.span(id_cstr);

        applyPalette(id) catch |err| {
            log.warn("applyPalette({s}) failed: {s}", .{ id, @errorName(err) });
        };
    }

    pub fn applyPalette(id: []const u8) !void {
        const alloc = std.heap.c_allocator;
        // Find the matching palette.
        const all = try palette_mod.loadAll(alloc);
        defer alloc.free(all);

        const p: *const palette_mod.Palette = blk: {
            for (all) |*candidate| {
                if (std.ascii.eqlIgnoreCase(candidate.id, id)) break :blk candidate;
                if (std.ascii.eqlIgnoreCase(candidate.name, id)) break :blk candidate;
            }
            return error.PaletteNotFound;
        };
        const v: *const palette_mod.Variant = if (p.dark.background != null) &p.dark else &p.light;

        var hex_buf: [16]u8 = undefined;
        if (v.background) |c| {
            const h = try std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
            try config_bridge.setKey(alloc, "background", h, null);
        }
        if (v.foreground) |c| {
            const h = try std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
            try config_bridge.setKey(alloc, "foreground", h, null);
        }
        if (v.cursor) |c| {
            const h = try std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
            try config_bridge.setKey(alloc, "cursor-color", h, null);
        }
        // Palette entries: emit one `palette = N=#hex` line per color via
        // the list-append helper, which removes any existing palette lines
        // first.
        var entry_storage: [16][16]u8 = undefined;
        var entry_slices: [16][]const u8 = undefined;
        var n_entries: usize = 0;
        for (v.colors, 0..) |maybe, i| {
            const c = maybe orelse continue;
            const slice = try std.fmt.bufPrint(&entry_storage[n_entries], "{d}=#{x:0>2}{x:0>2}{x:0>2}", .{ i, c.r, c.g, c.b });
            entry_slices[n_entries] = slice;
            n_entries += 1;
        }
        if (n_entries > 0) {
            try config_bridge.setKeyList(alloc, "palette", entry_slices[0..n_entries], null);
        }
        log.info("applied palette: {s} ({d} entries)", .{ p.name, n_entries });
        Application.default().triggerReload();
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
            class.bindTemplateChildPrivate("palette_flowbox", .{});
            class.bindTemplateChildPrivate("cursor_shape_row", .{});
            class.bindTemplateChildPrivate("cursor_blinking_row", .{});
            class.bindTemplateChildPrivate("audible_bell_row", .{});
            class.bindTemplateChildPrivate("attention_bell_row", .{});
            class.bindTemplateChildPrivate("bold_is_bright_row", .{});
            class.bindTemplateChildPrivate("limit_scrollback_row", .{});
            class.bindTemplateChildPrivate("scrollback_limit_row", .{});
            class.bindTemplateChildPrivate("font_button", .{});
            class.bindTemplateChildPrivate("line_spacing_row", .{});
            class.bindTemplateChildPrivate("column_spacing_row", .{});
            class.bindTemplateChildPrivate("tab_position_row", .{});
            class.bindTemplateChildPrivate("use_system_font_switch", .{});
            class.bindTemplateChildPrivate("profiles_listbox", .{});
            class.bindTemplateChildPrivate("add_profile_button", .{});
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
