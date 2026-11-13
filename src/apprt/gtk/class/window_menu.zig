//! Ptyxis-style hamburger menu for the Blueshell window: the System /
//! Light / Dark style selector and the zoom row, embedded in the main
//! menu's popover via gtk_popover_menu_add_child.
//!
//! This is fork-owned code. It lives outside `window.zig` so that the
//! upstream file only carries the call sites and one `Private` field
//! (see UPSTREAM_SYNC.md, "Additions over modifications").

const std = @import("std");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const configpkg = @import("../../../config.zig");
const Application = @import("application.zig").Application;
const config_bridge = @import("config_bridge.zig");

const log = std.log.scoped(.gtk_ghostty_window);

/// One popover's style selector: the three grouped circles.
const ThemeSelector = struct {
    follow: *gtk.CheckButton,
    light: *gtk.CheckButton,
    dark: *gtk.CheckButton,
};

/// Per-window state of the hamburger menu. A window embeds one of these
/// in its private data; it must not move after `init`, because the
/// selector signal handlers hold a pointer to it.
pub const HamburgerMenu = struct {
    zoom_label: ?*gtk.Label = null,
    zoom_label_compact: ?*gtk.Label = null,

    /// The style selector lives in both the normal and the compact
    /// header's menu, so we keep both groups and refresh them together.
    /// Index 0 is the primary popover, 1 the compact one.
    theme_selectors: [2]?ThemeSelector = .{ null, null },

    /// Set while we're updating the style selector to match the
    /// config so that the resulting "toggled" signals don't write
    /// the config (and trigger a reload) right back.
    theme_syncing: bool = false,

    /// Build the menu model, set it on both header menu buttons and add
    /// the custom theme-selector and zoom-row children to their popovers.
    pub fn init(
        self: *HamburgerMenu,
        menu_button: *gtk.MenuButton,
        menu_button_compact: *gtk.MenuButton,
    ) void {
        // ── Build the GMenu model ─────────────────────────────────────────
        const menu = gio.Menu.new();
        defer _ = gobject.Object.unref(menu.as(gobject.Object));

        // Section 1: custom theme-selector widget slot
        const theme_section = gio.Menu.new();
        defer _ = gobject.Object.unref(theme_section.as(gobject.Object));
        const theme_item = gio.MenuItem.new(null, null);
        theme_item.setAttributeValue("custom", glib.Variant.newString("theme-buttons"));
        theme_section.appendItem(theme_item);
        _ = gobject.Object.unref(theme_item.as(gobject.Object));
        menu.appendSection(null, theme_section.as(gio.MenuModel));

        // Section 2: custom zoom widget slot
        const zoom_section = gio.Menu.new();
        defer _ = gobject.Object.unref(zoom_section.as(gobject.Object));
        const zoom_item = gio.MenuItem.new(null, null);
        zoom_item.setAttributeValue("custom", glib.Variant.newString("zoom-row"));
        zoom_section.appendItem(zoom_item);
        _ = gobject.Object.unref(zoom_item.as(gobject.Object));
        menu.appendSection(null, zoom_section.as(gio.MenuModel));

        // Section 3: New Tab / New Window
        const tabs_section = gio.Menu.new();
        defer _ = gobject.Object.unref(tabs_section.as(gobject.Object));
        tabs_section.append("New _Tab", "win.new-tab");
        tabs_section.append("New _Window", "win.new-window");
        menu.appendSection(null, tabs_section.as(gio.MenuModel));

        // Section 4: Tab overview
        const overview_section = gio.Menu.new();
        defer _ = gobject.Object.unref(overview_section.as(gobject.Object));
        overview_section.append("Show Open Tabs", "win.tab-overview");
        // Agent awareness (RFC #22): jump to the next tab whose agent is
        // waiting on input. No-op when agent detection is off or nothing
        // is blocked.
        overview_section.append("Next Blocked Agent", "win.next-blocked-agent");
        menu.appendSection(null, overview_section.as(gio.MenuModel));

        // Section 5: Fullscreen toggle.
        const fs_section = gio.Menu.new();
        defer _ = gobject.Object.unref(fs_section.as(gobject.Object));
        fs_section.append("Fullscreen", "win.fullscreen");
        menu.appendSection(null, fs_section.as(gio.MenuModel));

        // Section 6: Preferences / About
        const prefs_section = gio.Menu.new();
        defer _ = gobject.Object.unref(prefs_section.as(gobject.Object));
        prefs_section.append("_Preferences", "app.preferences");
        prefs_section.append("_About Blueshell", "win.about");
        menu.appendSection(null, prefs_section.as(gio.MenuModel));

        // Set the menu on both buttons (popover is created lazily on first
        // use, but MenuButton creates it immediately when a model is set).
        menu_button.setMenuModel(menu.as(gio.MenuModel));
        menu_button_compact.setMenuModel(menu.as(gio.MenuModel));

        // Install CSS for the theme-selector circles.
        installThemeSelectorCSS(menu_button.as(gtk.Widget));

        // Add custom children to both popovers.
        self.addChildren(menu_button, true);
        self.addChildren(menu_button_compact, false);
    }

    /// Build theme-selector and zoom-row and add them to `button`'s popover.
    /// `primary` = true for the headerbar button (stores refs for update).
    fn addChildren(self: *HamburgerMenu, button: *gtk.MenuButton, primary: bool) void {
        const popover_widget = button.getPopover() orelse return;
        const popover: *gtk.PopoverMenu = gobject.ext.cast(gtk.PopoverMenu, popover_widget) orelse return;

        // ── Theme selector ───────────────────────────────────────────────
        const sel_box = gtk.Box.new(gtk.Orientation.horizontal, 0);
        sel_box.as(gtk.Widget).addCssClass("ptyxis-theme-selector");
        sel_box.as(gtk.Widget).setHalign(.center);

        const follow_btn = gtk.CheckButton.new();
        follow_btn.as(gtk.Widget).addCssClass("follow");
        follow_btn.as(gtk.Widget).setTooltipText("Follow System Style");
        follow_btn.as(gtk.Widget).setHexpand(1);
        follow_btn.as(gtk.Widget).setHalign(.center);

        const light_btn = gtk.CheckButton.new();
        light_btn.as(gtk.Widget).addCssClass("light");
        light_btn.as(gtk.Widget).setTooltipText("Light Style");
        light_btn.as(gtk.Widget).setHexpand(1);
        light_btn.as(gtk.Widget).setHalign(.center);
        light_btn.setGroup(follow_btn);

        const dark_btn = gtk.CheckButton.new();
        dark_btn.as(gtk.Widget).addCssClass("dark");
        dark_btn.as(gtk.Widget).setTooltipText("Dark Style");
        dark_btn.as(gtk.Widget).setHexpand(1);
        dark_btn.as(gtk.Widget).setHalign(.center);
        dark_btn.setGroup(follow_btn);

        sel_box.append(follow_btn.as(gtk.Widget));
        sel_box.append(light_btn.as(gtk.Widget));
        sel_box.append(dark_btn.as(gtk.Widget));

        const selector: ThemeSelector = .{
            .follow = follow_btn,
            .light = light_btn,
            .dark = dark_btn,
        };
        self.theme_selectors[if (primary) 0 else 1] = selector;

        // Set initial state BEFORE wiring signals so setActive() doesn't
        // trigger spurious config writes during init.
        self.setThemeSelector(selector);

        // Wire theme toggle signals (after initial state is set).
        _ = gobject.signalConnectData(follow_btn.as(gobject.Object), "toggled", @ptrCast(&themeFollowToggled), self, null, .{});
        _ = gobject.signalConnectData(light_btn.as(gobject.Object), "toggled", @ptrCast(&themeLightToggled), self, null, .{});
        _ = gobject.signalConnectData(dark_btn.as(gobject.Object), "toggled", @ptrCast(&themeDarkToggled), self, null, .{});

        _ = popover.addChild(sel_box.as(gtk.Widget), "theme-buttons");

        // ── Zoom row ─────────────────────────────────────────────────────
        const zoom_box = gtk.Box.new(gtk.Orientation.horizontal, 6);
        zoom_box.as(gtk.Widget).addCssClass("ptyxis-zoom-row");
        zoom_box.as(gtk.Widget).setHexpand(1);
        zoom_box.as(gtk.Widget).setMarginTop(4);
        zoom_box.as(gtk.Widget).setMarginBottom(4);

        const zoom_out = gtk.Button.newFromIconName("zoom-out-symbolic");
        zoom_out.as(gtk.Widget).addCssClass("circular");
        zoom_out.as(gtk.Widget).addCssClass("flat");
        zoom_out.as(gtk.Widget).setTooltipText("Zoom Out");
        zoom_out.as(gtk.Actionable).setActionName("win.zoom-out");

        const zoom_lbl = gtk.Label.new("100%");
        zoom_lbl.as(gtk.Widget).setHexpand(1);
        zoom_lbl.as(gtk.Widget).setHalign(.center);
        zoom_lbl.as(gtk.Widget).addCssClass("flat");

        const zoom_in = gtk.Button.newFromIconName("zoom-in-symbolic");
        zoom_in.as(gtk.Widget).addCssClass("circular");
        zoom_in.as(gtk.Widget).addCssClass("flat");
        zoom_in.as(gtk.Widget).setTooltipText("Zoom In");
        zoom_in.as(gtk.Actionable).setActionName("win.zoom-in");

        zoom_box.append(zoom_out.as(gtk.Widget));
        zoom_box.append(zoom_lbl.as(gtk.Widget));
        zoom_box.append(zoom_in.as(gtk.Widget));

        if (primary) self.zoom_label = zoom_lbl else self.zoom_label_compact = zoom_lbl;

        _ = popover.addChild(zoom_box.as(gtk.Widget), "zoom-row");
    }

    /// Show `text` (e.g. "120%") in the zoom row of both popovers.
    pub fn setZoomText(self: *HamburgerMenu, text: [*:0]const u8) void {
        if (self.zoom_label) |lbl| lbl.setText(text);
        if (self.zoom_label_compact) |lbl| lbl.setText(text);
    }

    fn setThemeSelector(self: *HamburgerMenu, selector: ThemeSelector) void {
        const cfg = Application.default().getConfig().get();
        const active_idx: usize = switch (cfg.@"window-theme") {
            .auto, .system => 0,
            .light => 1,
            .dark, .ghostty => 2,
        };

        self.theme_syncing = true;
        defer self.theme_syncing = false;

        selector.follow.setActive(if (active_idx == 0) 1 else 0);
        selector.light.setActive(if (active_idx == 1) 1 else 0);
        selector.dark.setActive(if (active_idx == 2) 1 else 0);
    }

    /// Point every style selector in this window at the current config.
    /// Called whenever the config changes and whenever a menu opens, so the
    /// selection can't drift from reality (another window, an edited config
    /// file, or a reload that lands after the menu was last drawn).
    pub fn syncThemeSelectors(self: *HamburgerMenu) void {
        for (self.theme_selectors) |maybe| {
            if (maybe) |selector| self.setThemeSelector(selector);
        }
    }

    /// Apply and persist a style-picker choice, unless we're the ones who
    /// just set the button state.
    fn setWindowTheme(
        self: *HamburgerMenu,
        btn: *gtk.CheckButton,
        theme: configpkg.Config.WindowTheme,
    ) void {
        if (btn.getActive() == 0) return;
        if (self.theme_syncing) return;

        const app = Application.default();

        // Apply immediately so the click feels instant instead of waiting
        // on the debounced reload below.
        app.applyWindowTheme(theme, app.getConfig().get().background);

        // Then persist it for the next launch. A failed write must not
        // leave the picker claiming a style we didn't save, so put the
        // buttons back the way the config says.
        config_bridge.setKey(
            std.heap.c_allocator,
            "window-theme",
            @tagName(theme),
            null,
        ) catch |err| {
            log.warn("window-theme write failed: {s}", .{@errorName(err)});
            self.syncThemeSelectors();
            app.applyWindowTheme(
                app.getConfig().get().@"window-theme",
                app.getConfig().get().background,
            );
            return;
        };

        // Quiet: the user asked for a style, not for a config reload, so
        // this shouldn't raise the "Reloaded the configuration" toast.
        app.triggerReloadOpts(.{ .quiet = true });
    }

    fn themeFollowToggled(btn: *gtk.CheckButton, self: *HamburgerMenu) callconv(.c) void {
        self.setWindowTheme(btn, .system);
    }

    fn themeLightToggled(btn: *gtk.CheckButton, self: *HamburgerMenu) callconv(.c) void {
        self.setWindowTheme(btn, .light);
    }

    fn themeDarkToggled(btn: *gtk.CheckButton, self: *HamburgerMenu) callconv(.c) void {
        self.setWindowTheme(btn, .dark);
    }
};

/// Display-wide stylesheet for the style selector. Installed once per
/// process — it used to be added per window, stacking an identical
/// provider on the display for every window that was opened.
var theme_selector_css_installed: bool = false;

fn installThemeSelectorCSS(widget: *gtk.Widget) void {
    if (theme_selector_css_installed) return;
    theme_selector_css_installed = true;

    const css =
        \\.ptyxis-theme-selector checkbutton {
        \\  min-width: 44px;
        \\  min-height: 44px;
        \\  padding: 1px;
        \\  background-clip: content-box;
        \\  border-radius: 9999px;
        \\  box-shadow: inset 0 0 0 1px alpha(currentColor, 0.2);
        \\  margin: 6px;
        \\}
        \\.ptyxis-theme-selector checkbutton:checked {
        \\  box-shadow:
        \\    inset 0 0 0 3px @accent_bg_color,
        \\    0 0 0 1px alpha(@accent_bg_color, 0.35);
        \\}
        \\.ptyxis-theme-selector checkbutton.follow {
        \\  background-image: linear-gradient(to bottom right, #fff 49.99%, #202020 50.01%);
        \\}
        \\.ptyxis-theme-selector checkbutton.light {
        \\  background-color: #fff;
        \\}
        \\.ptyxis-theme-selector checkbutton.dark {
        \\  background-color: #202020;
        \\}
        \\.ptyxis-theme-selector checkbutton radio,
        \\.ptyxis-theme-selector checkbutton check {
        \\  -gtk-icon-source: none;
        \\  border: none;
        \\  background: none;
        \\  box-shadow: none;
        \\  min-width: 0;
        \\  min-height: 0;
        \\  margin: 0;
        \\  padding: 0;
        \\}
        \\.ptyxis-zoom-row {
        \\  padding: 0 12px;
        \\}
    ;
    const provider = gtk.CssProvider.new();
    provider.loadFromString(css);
    gtk.StyleContext.addProviderForDisplay(
        gtk.Widget.getDisplay(widget),
        provider.as(gtk.StyleProvider),
        600,
    );
    _ = gobject.Object.unref(provider.as(gobject.Object));
}
