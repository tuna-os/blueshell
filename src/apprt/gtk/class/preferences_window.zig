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
const Application = @import("application.zig").Application;

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
        bold_is_bright_row: *adw.SwitchRow,
        scrollback_limit_row: *adw.SpinRow,

        pub var offset: c_int = 0;
    };

    pub fn new() *Self {
        return gobject.ext.newInstance(Self, .{});
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

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

        // Scrollback.
        const sb_adj = adw.SpinRow.getAdjustment(priv.scrollback_limit_row);
        sb_adj.setValue(@floatFromInt(@min(cfg.@"scrollback-limit", std.math.maxInt(u32))));
    }

    fn cursorShapeChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        const i = row.getSelected();
        const value: []const u8 = switch (i) {
            0 => "block",
            1 => "bar",
            2 => "underline",
            else => return,
        };
        config_bridge.setKey(std.heap.c_allocator, "cursor-style", value) catch |err| {
            log.warn("cursor-style write: {s}", .{@errorName(err)});
        };
    }

    fn cursorBlinkingChanged(row: *adw.ComboRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        const i = row.getSelected();
        const value: []const u8 = switch (i) {
            0 => "true", // Follow System ≈ default on
            1 => "true",
            2 => "false",
            else => return,
        };
        config_bridge.setKey(std.heap.c_allocator, "cursor-style-blink", value) catch |err| {
            log.warn("cursor-style-blink write: {s}", .{@errorName(err)});
        };
    }

    fn audibleBellChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        const v: []const u8 = if (row.getActive() != 0) "true" else "false";
        config_bridge.setKey(std.heap.c_allocator, "audible-bell", v) catch |err| {
            log.warn("audible-bell write: {s}", .{@errorName(err)});
        };
    }

    fn boldIsBrightChanged(row: *adw.SwitchRow, _: *gobject.ParamSpec, _: *Self) callconv(.c) void {
        const v: []const u8 = if (row.getActive() != 0) "true" else "false";
        config_bridge.setKey(std.heap.c_allocator, "bold-is-bright", v) catch |err| {
            log.warn("bold-is-bright write: {s}", .{@errorName(err)});
        };
    }

    fn scrollbackLimitChanged(adj: *gtk.Adjustment, _: *Self) callconv(.c) void {
        const v = adj.getValue();
        var buf: [32]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d:.0}", .{v}) catch return;
        config_bridge.setKey(std.heap.c_allocator, "scrollback-limit", slice) catch |err| {
            log.warn("scrollback-limit write: {s}", .{@errorName(err)});
        };
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

    fn populatePalettes(flowbox: *gtk.FlowBox) !void {
        const alloc = std.heap.c_allocator;
        const palettes = try palette_mod.loadAll(alloc);
        defer alloc.free(palettes);

        for (palettes) |p| {
            const card = makePaletteCard(p) orelse continue;
            flowbox.append(card.as(gtk.Widget));
        }

        log.info("populated {d} palettes in flowbox", .{palettes.len});
    }

    /// Build a single Ptyxis-style palette swatch card. Returns null on
    /// allocator failures; caller appends the result to a container.
    fn makePaletteCard(p: palette_mod.Palette) ?*gtk.Button {
        // Prefer the dark variant if it has data, else light.
        const v: *const palette_mod.Variant = if (p.dark.background != null) &p.dark else &p.light;
        const bg = v.background orelse palette_mod.RGB{ .r = 0x20, .g = 0x20, .b = 0x20 };
        const fg = v.foreground orelse palette_mod.RGB{ .r = 0xe0, .g = 0xe0, .b = 0xe0 };
        // For the sample-text colour use a slightly dimmed foreground —
        // Ptyxis uses an italic muted variant.
        const muted = palette_mod.RGB{
            .r = @intCast((@as(u16, fg.r) + @as(u16, bg.r) * 2) / 3),
            .g = @intCast((@as(u16, fg.g) + @as(u16, bg.g) * 2) / 3),
            .b = @intCast((@as(u16, fg.b) + @as(u16, bg.b) * 2) / 3),
        };

        // Outer vertical box: name (top), sample (middle), color strip (bottom).
        const box = gtk.Box.new(gtk.Orientation.vertical, 8);
        box.as(gtk.Widget).setHexpand(1);
        box.as(gtk.Widget).setVexpand(0);
        box.as(gtk.Widget).setMarginTop(14);
        box.as(gtk.Widget).setMarginBottom(14);
        box.as(gtk.Widget).setMarginStart(14);
        box.as(gtk.Widget).setMarginEnd(14);

        // Card-level CSS — background and rounded corners coloured by palette bg.
        const card_css = gtk.CssProvider.new();
        var card_buf: [192]u8 = undefined;
        const card_rule = std.fmt.bufPrintZ(&card_buf, ".ptyxis-pal-card{{background:#{x:0>2}{x:0>2}{x:0>2};border-radius:9px;}}.ptyxis-pal-card label{{color:#{x:0>2}{x:0>2}{x:0>2};}}.ptyxis-pal-card label.muted{{color:#{x:0>2}{x:0>2}{x:0>2};font-style:italic;font-family:monospace;}}", .{
            bg.r, bg.g, bg.b, fg.r, fg.g, fg.b, muted.r, muted.g, muted.b,
        }) catch return null;
        _ = card_css.loadFromString(card_rule);

        // Click-target wraps the box.
        const btn = gtk.Button.new();
        btn.setChild(box.as(gtk.Widget));
        btn.as(gtk.Widget).addCssClass("flat");
        btn.as(gtk.Widget).addCssClass("ptyxis-pal-card");
        gtk.StyleContext.addProviderForDisplay(
            (gtk.Widget.getDisplay(btn.as(gtk.Widget))),
            card_css.as(gtk.StyleProvider),
            800,
        );
        _ = gobject.Object.unref(card_css.as(gobject.Object));

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

        // Color strip — 7 representative colors from the ANSI 1..6 + 13.
        // Matches Ptyxis's row of seven dots.
        const strip = gtk.Box.new(gtk.Orientation.horizontal, 6);
        strip.as(gtk.Widget).setMarginTop(4);
        const want: [7]u4 = .{ 1, 2, 3, 4, 5, 6, 14 };
        for (want) |i| {
            const c = v.colors[i] orelse continue;
            const dot = gtk.DrawingArea.new();
            dot.as(gtk.Widget).setSizeRequest(18, 18);
            const dcss = gtk.CssProvider.new();
            var db: [96]u8 = undefined;
            const drule = std.fmt.bufPrintZ(&db, "drawingarea{{background:#{x:0>2}{x:0>2}{x:0>2};border-radius:5px;}}", .{
                c.r, c.g, c.b,
            }) catch continue;
            _ = dcss.loadFromString(drule);
            gtk.StyleContext.addProviderForDisplay(
                (gtk.Widget.getDisplay(dot.as(gtk.Widget))),
                dcss.as(gtk.StyleProvider),
                800,
            );
            _ = gobject.Object.unref(dcss.as(gobject.Object));
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
            try config_bridge.setKey(alloc, "background", h);
        }
        if (v.foreground) |c| {
            const h = try std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
            try config_bridge.setKey(alloc, "foreground", h);
        }
        if (v.cursor) |c| {
            const h = try std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b });
            try config_bridge.setKey(alloc, "cursor-color", h);
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
            try config_bridge.setKeyList(alloc, "palette", entry_slices[0..n_entries]);
        }
        log.info("applied palette: {s} ({d} entries)", .{ p.name, n_entries });
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
            class.bindTemplateChildPrivate("bold_is_bright_row", .{});
            class.bindTemplateChildPrivate("scrollback_limit_row", .{});
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
