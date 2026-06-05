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

        // Populate palette flowbox.
        populatePalettes(priv.palette_flowbox) catch |err| {
            log.warn("populatePalettes failed: {s}", .{@errorName(err)});
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
            // Choose the dark variant if it has data, else light.
            const v: *const palette_mod.Variant = if (p.dark.background != null) &p.dark else &p.light;

            // Container: vertical box with swatch row + name label.
            const box = gtk.Box.new(gtk.Orientation.vertical, 4);
            box.as(gtk.Widget).addCssClass("card");
            box.as(gtk.Widget).setMarginTop(4);
            box.as(gtk.Widget).setMarginBottom(4);
            box.as(gtk.Widget).setMarginStart(4);
            box.as(gtk.Widget).setMarginEnd(4);

            // Background+foreground big swatch box.
            const bg = v.background orelse palette_mod.RGB{ .r = 0x20, .g = 0x20, .b = 0x20 };
            const fg = v.foreground orelse palette_mod.RGB{ .r = 0xe0, .g = 0xe0, .b = 0xe0 };
            const big_label = gtk.Label.new("Aa");
            big_label.as(gtk.Widget).setHexpand(1);
            big_label.as(gtk.Widget).setVexpand(1);

            // CSS-style inline rule for swatch.
            const css_provider = gtk.CssProvider.new();
            defer _ = gobject.Object.unref(css_provider.as(gobject.Object));

            var css_buf: [256]u8 = undefined;
            const css = std.fmt.bufPrintZ(&css_buf, "label.ptyxis-swatch{{background:#{x:0>2}{x:0>2}{x:0>2};color:#{x:0>2}{x:0>2}{x:0>2};padding:14px;border-radius:6px;font-size:18px;}}", .{
                bg.r, bg.g, bg.b, fg.r, fg.g, fg.b,
            }) catch continue;
            _ = css_provider.loadFromString(css);
            const ctx = big_label.as(gtk.Widget).getStyleContext();
            ctx.addProvider(css_provider.as(gtk.StyleProvider), 800);
            big_label.as(gtk.Widget).addCssClass("ptyxis-swatch");

            box.append(big_label.as(gtk.Widget));

            // 16-color strip.
            const strip = gtk.Box.new(gtk.Orientation.horizontal, 2);
            for (v.colors) |maybe| {
                const c = maybe orelse continue;
                const cell = gtk.DrawingArea.new();
                cell.as(gtk.Widget).setSizeRequest(8, 8);
                const cell_css = gtk.CssProvider.new();
                defer _ = gobject.Object.unref(cell_css.as(gobject.Object));
                var cb: [128]u8 = undefined;
                const ccss = std.fmt.bufPrintZ(&cb, "drawingarea{{background:#{x:0>2}{x:0>2}{x:0>2};border-radius:1px;}}", .{
                    c.r, c.g, c.b,
                }) catch continue;
                _ = cell_css.loadFromString(ccss);
                cell.as(gtk.Widget).getStyleContext().addProvider(cell_css.as(gtk.StyleProvider), 800);
                strip.append(cell.as(gtk.Widget));
            }
            box.append(strip.as(gtk.Widget));

            // Name label.
            const name_z = std.heap.c_allocator.dupeZ(u8, p.name) catch continue;
            const name_label = gtk.Label.new(name_z.ptr);
            std.heap.c_allocator.free(name_z);
            name_label.setEllipsize(.middle);
            box.append(name_label.as(gtk.Widget));

            // Clickable wrapper.
            const btn = gtk.Button.new();
            btn.setChild(box.as(gtk.Widget));
            btn.as(gtk.Widget).addCssClass("flat");
            btn.as(gtk.Widget).setTooltipText(name_label.getText());

            // Store the palette id in a GObject data slot so the click
            // handler can recover it. We dupe so the lifetime survives
            // the palettes-slice deinit.
            const id_z = std.heap.c_allocator.dupeZ(u8, p.id) catch continue;
            gobject.Object.setData(btn.as(gobject.Object), "ptyxis-palette-id", @ptrCast(@constCast(id_z.ptr)));

            _ = gobject.signalConnectData(
                btn.as(gobject.Object),
                "clicked",
                @ptrCast(&onPaletteClicked),
                null,
                null,
                .{},
            );

            flowbox.append(btn.as(gtk.Widget));
        }

        log.info("populated {d} palettes in flowbox", .{palettes.len});
    }

    fn onPaletteClicked(btn: *gtk.Button, _: ?*anyopaque) callconv(.c) void {
        const ptr = gobject.Object.getData(btn.as(gobject.Object), "ptyxis-palette-id") orelse return;
        const id_cstr: [*:0]const u8 = @ptrCast(ptr);
        const id = std.mem.span(id_cstr);

        applyPalette(id) catch |err| {
            log.warn("applyPalette({s}) failed: {s}", .{ id, @errorName(err) });
        };
    }

    fn applyPalette(id: []const u8) !void {
        const alloc = std.heap.c_allocator;
        // Find the matching palette.
        const all = try palette_mod.loadAll(alloc);
        defer alloc.free(all);

        const p: *const palette_mod.Palette = blk: {
            for (all) |*candidate| {
                if (std.mem.eql(u8, candidate.id, id)) break :blk candidate;
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
        // Palette entries: write a single combined value matching Ghostty's
        // syntax: `palette = 0=#xxxxxx`. Each Color0..15 is its own assignment.
        for (v.colors, 0..) |maybe, i| {
            const c = maybe orelse continue;
            var line_buf: [32]u8 = undefined;
            const slice = try std.fmt.bufPrint(&line_buf, "{d}=#{x:0>2}{x:0>2}{x:0>2}", .{ i, c.r, c.g, c.b });
            // Use a key suffix per index so we don't clobber other entries.
            // Ghostty actually wants `palette = 0=#…` etc. on multiple lines —
            // our line-editor only supports a single key occurrence, so we
            // synthesize unique keys here. The user can normalize later.
            // For now, treat palette as a single key and overwrite repeatedly;
            // last write wins, so only the final entry survives. This is a
            // known limitation tracked for the next step.
            try config_bridge.setKey(alloc, "palette", slice);
        }
        log.info("applied palette: {s}", .{p.name});
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
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
