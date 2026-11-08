const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const internal_os = @import("../../../os/main.zig");
const systemd = @import("../../../os/systemd.zig");
const terminal = @import("../../../terminal/main.zig");
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const CoreConfig = configpkg.Config;
const CoreSurface = @import("../../../Surface.zig");

const ext = @import("../ext.zig");
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const SplitTree = @import("split_tree.zig").SplitTree;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;
const Overrides = @import("Overrides.zig");

const log = std.log.scoped(.gtk_ghostty_application_action);

pub const Action = struct {
    pub fn closeTab(target: apprt.Target, value: apprt.Action.Value(.close_tab)) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction(
                    "tab.close",
                    glib.ext.VariantType.stringFor([:0]const u8),
                    @as([*:0]const u8, @tagName(value)),
                ) != 0;
            },
        }
    }

    pub fn closeWindow(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("win.close", null) != 0;
            },
        }
    }

    pub fn copyTitleToClipboard(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.gobj().copyTitleToClipboard(),
        };
    }

    pub fn exportTerminalIO(
        self: *Application,
        target: apprt.Target,
        value: apprt.Action.Value(.export_terminal_io),
    ) Allocator.Error!bool {
        const surface = switch (target) {
            .app => return false,
            .surface => |v| v.rt_surface.gobj(),
        };

        const alloc = self.allocator();
        const contents = try alloc.dupe(u8, value.contents);
        errdefer alloc.free(contents);
        const request = try alloc.create(ExportTerminalIORequest);
        errdefer alloc.destroy(request);
        request.* = .{
            .alloc = alloc,
            .contents = contents,
        };

        const parent = ext.getAncestor(gtk.Window, surface.as(gtk.Widget));
        const dialog = gtk.FileChooserNative.new(
            i18n._("Export Terminal IO Events"),
            parent,
            .save,
            i18n._("Export"),
            i18n._("Cancel"),
        );
        const chooser = dialog.as(gtk.FileChooser);
        chooser.setCreateFolders(1);
        chooser.setCurrentName("ghostty-terminal-io.txt");

        _ = gtk.NativeDialog.signals.response.connect(
            dialog,
            *ExportTerminalIORequest,
            ExportTerminalIORequest.response,
            request,
            .{ .destroyData = ExportTerminalIORequest.destroy },
        );
        dialog.as(gtk.NativeDialog).show();
        return true;
    }

    const ExportTerminalIORequest = struct {
        alloc: Allocator,
        contents: []u8,

        fn destroy(self: *ExportTerminalIORequest) callconv(.c) void {
            self.alloc.free(self.contents);
            self.alloc.destroy(self);
        }

        fn response(
            dialog: *gtk.FileChooserNative,
            response_id: c_int,
            self: *ExportTerminalIORequest,
        ) callconv(.c) void {
            defer dialog.unref();

            if (response_id != @intFromEnum(gtk.ResponseType.accept)) return;

            const file = dialog.as(gtk.FileChooser).getFile() orelse {
                log.warn("inspector export dialog returned no file", .{});
                return;
            };
            defer file.unref();

            var gerr: ?*glib.Error = null;
            const replaced = file.replaceContents(
                self.contents.ptr,
                self.contents.len,
                null,
                0,
                .{},
                null,
                null,
                &gerr,
            );
            if (gerr) |err| {
                defer err.free();
                log.err(
                    "failed to export terminal IO events err={s}",
                    .{err.f_message orelse "(unknown)"},
                );
                return;
            }
            if (replaced == 0) {
                log.err("failed to export terminal IO events", .{});
            }
        }
    };

    pub fn configChange(
        self: *Application,
        target: apprt.Target,
        new_config: *const CoreConfig,
    ) !void {
        // Wrap our config in a GObject. This will clone it.
        const alloc = self.allocator();
        const config_obj: *Config = try .new(alloc, new_config);
        defer config_obj.unref();

        switch (target) {
            .surface => |core| core.rt_surface.surface.setConfig(config_obj),
            .app => self.setConfig(config_obj),
        }
    }

    pub fn desktopNotification(
        self: *Application,
        target: apprt.Target,
        n: apprt.action.DesktopNotification,
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| {
                v.rt_surface.gobj().sendDesktopNotification(n.title, n.body);
                return;
            },
        }

        // Set a default title if we don't already have one
        const t = switch (n.title.len) {
            0 => "Ghostty",
            else => n.title,
        };

        const notification = gio.Notification.new(t);
        defer notification.unref();
        notification.setBody(n.body);

        const icon = gio.ThemedIcon.new("com.mitchellh.ghostty");
        defer icon.unref();
        notification.setIcon(icon.as(gio.Icon));
        notification.setDefaultActionAndTargetValue(
            "app.present-surface",
            glib.Variant.newUint64(0),
        );

        // We set the notification ID to the body content. If the content is the
        // same, this notification may replace a previous notification
        const gio_app = self.as(gio.Application);
        gio_app.sendNotification(n.body, notification);
    }

    pub fn equalizeSplits(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("equalize splits to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("split-tree.equalize", null) != 0;
            },
        }
    }

    pub fn gotoSplit(
        target: apprt.Target,
        to: apprt.action.GotoSplit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Design note: we can't use widget actions here because
                // we need to know whether there is a goto target for returning
                // the proper perform result (boolean).

                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring goto_split", .{});
                    return false;
                };

                return tree.goto(switch (to) {
                    .previous => .previous_wrapped,
                    .next => .next_wrapped,
                    .up => .{ .spatial = .up },
                    .down => .{ .spatial = .down },
                    .left => .{ .spatial = .left },
                    .right => .{ .spatial = .right },
                });
            },
        }
    }

    pub fn gotoTab(
        target: apprt.Target,
        tab: apprt.action.GotoTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.selectTab(switch (tab) {
                    .previous => .previous,
                    .next => .next,
                    .last => .last,
                    else => .{ .n = @intCast(@intFromEnum(tab)) },
                });
            },
        }
    }

    pub fn gotoWindow(direction: apprt.action.GotoWindow) bool {
        const glist = gtk.Window.listToplevels();
        defer glist.free();

        // The window we're starting from is typically our active window.
        const starting: *glib.List = @as(?*glib.List, glist.findCustom(
            null,
            findActiveWindow,
        )) orelse glist;

        // Go forward or backwards in the list until we find a valid
        // window that is visible.
        var current_: ?*glib.List = starting;
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        // If we reached here, we didn't find a valid window to focus.
        // Wrap around.
        current_ = switch (direction) {
            .next => glist,
            .previous => last: {
                var end: *glib.List = glist;
                while (end.f_next) |next| end = next;
                break :last end;
            },
        };
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            if (current_ == starting) break;
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        return false;
    }

    fn gotoWindowMaybe(gtk_window: *gtk.Window) bool {
        // If it is already active skip it.
        if (gtk_window.isActive() != 0) return false;
        // If it is hidden, skip it.
        if (gtk_window.as(gtk.Widget).isVisible() == 0) return false;
        // If it isn't a Ghostty window, skip it.
        const window = gobject.ext.cast(
            Window,
            gtk_window,
        ) orelse return false;

        // Focus our active surface
        const surface = window.getActiveSurface() orelse return false;
        gtk.Window.present(gtk_window);
        surface.grabFocus();
        return true;
    }

    pub fn initialSize(
        target: apprt.Target,
        value: apprt.action.InitialSize,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                surface.setDefaultSize(.{
                    .width = value.width,
                    .height = value.height,
                });
                return true;
            },
        }
    }

    pub fn mouseOverLink(
        target: apprt.Target,
        value: apprt.action.MouseOverLink,
    ) void {
        switch (target) {
            .app => log.warn("mouse over link to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHoverUrl(
                if (value.url.len > 0) value.url else null,
            ),
        }
    }

    pub fn mouseShape(
        target: apprt.Target,
        shape: terminal.MouseShape,
    ) void {
        switch (target) {
            .app => log.warn("mouse shape to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseShape(shape),
        }
    }

    pub fn mouseVisibility(
        target: apprt.Target,
        visibility: apprt.action.MouseVisibility,
    ) void {
        switch (target) {
            .app => log.warn("mouse visibility to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHidden(switch (visibility) {
                .visible => false,
                .hidden => true,
            }),
        }
    }

    pub fn moveTab(
        target: apprt.Target,
        value: apprt.action.MoveTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.moveTab(
                    surface,
                    @intCast(value.amount),
                );
            },
        }
    }

    pub fn moveTabToNewWindow(
        target: apprt.Target,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab_to_new_window", .{});
                    return false;
                };

                return window.moveTabToNewWindow(surface);
            },
        }
    }

    pub fn newSplit(
        target: apprt.Target,
        direction: apprt.action.SplitDirection,
    ) bool {
        switch (target) {
            .app => {
                log.warn("new split to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;

                return surface.as(gtk.Widget).activateAction(
                    "split-tree.new-split",
                    "&s",
                    @tagName(direction).ptr,
                ) != 0;
            },
        }
    }

    pub fn newTab(target: apprt.Target, overrides: Overrides) bool {
        switch (target) {
            .app => {
                log.warn("new tab to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // Get the window ancestor of the surface. Surfaces shouldn't
                // be aware they might be in windows but at the app level we
                // can do this.
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                window.newTab(core, .{
                    .command = overrides.command,
                    .shell_integration = overrides.shell_integration,
                    .working_directory = overrides.working_directory,
                    .title = overrides.title,
                });
                return true;
            },
        }
    }

    pub fn newWindow(self: *Application, parent: ?*CoreSurface, overrides: Overrides) !void {
        // Note that we've requested a window at least once. This is used
        // to trigger quit on no windows. Note I'm not sure if this is REALLY
        // necessary, but I don't want to risk a bug where on a slow machine
        // or something we quit immediately after starting up because there
        // was a delay in the event loop before we created a Window.
        self.markWindowRequested();

        const win = Window.new(self, .{
            .title = overrides.title,
        });
        initAndShowWindow(
            self,
            win,
            parent,
            .{
                .command = overrides.command,
                .shell_integration = overrides.shell_integration,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    fn initAndShowWindow(
        self: *Application,
        win: *Window,
        parent: ?*CoreSurface,
        overrides: Overrides,
    ) void {
        // Setup a binding so that whenever our config changes so does the
        // window. There's never a time when the window config should be out
        // of sync with the application config.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            win.as(gobject.Object),
            "config",
            .{},
        );

        // Create a new tab with window context (first tab in new window)
        win.newTabForWindow(parent, .{
            .command = overrides.command,
            .shell_integration = overrides.shell_integration,
            .working_directory = overrides.working_directory,
            .title = overrides.title,
        });

        // Estimate the initial window size before presenting so the window
        // manager can position it correctly.
        if (win.getActiveSurface()) |surface| {
            surface.estimateInitialSize();
            if (surface.getDefaultSize()) |size| {
                win.as(gtk.Window).setDefaultSize(
                    @intCast(size.width),
                    @intCast(size.height),
                );
            }
        }

        // Show the window
        gtk.Window.present(win.as(gtk.Window));
    }

    pub fn openConfig(self: *Application, value: apprt.action.OpenConfig) bool {
        const alloc = self.allocator();

        // Get the config file path
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("error getting config file path: {t}", .{err});
            return false;
        };
        defer alloc.free(path);

        switch (value) {
            .os_open => {
                // Open it using openUrl. "path" isn't actually a URL but
                // at the time of writing that works just fine for GTK.
                openUrl(self, .{ .kind = .text, .url = path });
            },

            .new_window => {
                const cmd = internal_os.getConfigEditCommand(alloc, path, .default) catch |err| {
                    log.warn("unable to get command to edit the config: {t}", .{err});
                    return false;
                };
                defer alloc.free(cmd);

                const command: configpkg.Command = .{
                    .direct = &.{ "/bin/sh", "-c", cmd },
                };

                const title = std.fmt.allocPrintSentinel(
                    alloc,
                    "{s} {s}",
                    .{ i18n._("Editing configuration file"), path },
                    0,
                ) catch |err| t: {
                    log.warn("unable to format title: {t}", .{err});
                    break :t null;
                };
                defer if (title) |t| alloc.free(t);

                Action.newWindow(self, null, .{
                    .command = command,
                    .title = title,
                    .shell_integration = null,
                    .working_directory = null,
                }) catch |err| {
                    log.warn("unable to create new window: {t}", .{err});
                    return false;
                };
            },
        }

        return true;
    }

    pub fn openUrl(
        self: *Application,
        value: apprt.action.OpenUrl,
    ) void {
        if (std.mem.startsWith(u8, value.url, "/")) {
            self.openUrlFallback(value.kind, value.url);
            return;
        }
        if (std.mem.startsWith(u8, value.url, "file://")) {
            self.openUrlFallback(value.kind, value.url);
            return;
        }

        self.openUri().start(value) catch |err| {
            log.err("unable to open uri err={}", .{err});
            self.openUrlFallback(value.kind, value.url);
            return;
        };
    }

    pub fn pwd(
        target: apprt.Target,
        value: apprt.action.Pwd,
    ) void {
        switch (target) {
            .app => log.warn("pwd to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setPwd(value.pwd),
        }
    }

    pub fn quitTimer(
        self: *Application,
        mode: apprt.action.QuitTimer,
    ) !void {
        switch (mode) {
            .start => self.startQuitTimer(),
            .stop => self.stopQuitTimer(),
        }
    }

    pub fn presentTerminal(
        target: apprt.Target,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.present();
                break :surface true;
            },
        };
    }

    pub fn progressReport(
        target: apprt.Target,
        value: terminal.osc.Command.ProgressReport,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.setProgressReport(value);
                break :surface true;
            },
        };
    }

    pub fn promptTitle(target: apprt.Target, value: apprt.action.PromptTitle) bool {
        switch (value) {
            .surface => switch (target) {
                .app => return false,
                .surface => |v| {
                    v.rt_surface.surface.promptTitle();
                    return true;
                },
            },
            .tab => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const tab = ext.getAncestor(
                            Tab,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a tab, ignoring prompt_tab_title", .{});
                            return false;
                        };
                        tab.promptTabTitle();
                        return true;
                    },
                }
            },
            .window => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const win = ext.getAncestor(
                            Window,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a window, ignoring prompt_window_title", .{});
                            return false;
                        };
                        win.promptWindowTitle();
                        return true;
                    },
                }
            },
        }
    }

    /// Reload the configuration for the application and propagate it
    /// across the entire application and all terminals.
    pub fn reloadConfig(
        self: *Application,
        target: apprt.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        // Tell systemd that reloading has started, but only once startup
        // is complete. A reload during startup is not a reload to systemd.
        const notify_systemd = self.systemdReady();
        if (notify_systemd) systemd.notify.reloading();

        // When we exit this function tell systemd that reloading has finished.
        defer if (notify_systemd) systemd.notify.ready();

        // Decide once, for this whole reload, whether it was user-initiated.
        // A soft reload is always internal (the desktop switched light/dark);
        // a hard one is quiet only if whoever queued it asked for that.
        self.beginConfigReload(opts.soft);

        // Get our config object.
        const config: *Config = config: {
            // Soft-reloading applies conditional logic to the existing loaded
            // config so we return that as-is (but take a reference).
            if (opts.soft) {
                break :config self.getConfig();
            }

            // Hard reload, load a new config completely.
            const alloc = self.allocator();
            var config = try CoreConfig.load(alloc);
            defer config.deinit();
            break :config try .new(alloc, &config);
        };
        defer config.unref();

        // Update the proper target. This will trigger a `config_change`
        // apprt action which will propagate the config properly to our
        // property system.
        switch (target) {
            .app => try self.core().updateConfig(
                self.rt(),
                config.get(),
            ),
            .surface => |core| try core.updateConfig(config.get()),
        }
    }

    pub fn render(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.redraw(),
        }
    }

    pub fn resizeSplit(
        target: apprt.Target,
        value: apprt.action.ResizeSplit,
    ) bool {
        switch (target) {
            .app => {
                log.warn("resize_split to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring resize_split", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return tree.resize(
                    switch (value.direction) {
                        .up => .up,
                        .down => .down,
                        .left => .left,
                        .right => .right,
                    },
                    value.amount,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn("unable to resize split, out of memory", .{});
                        return false;
                    },
                };
            },
        }
    }

    pub fn resizeWindow(
        target: apprt.Target,
        value: apprt.action.ResizeWindow,
    ) bool {
        switch (target) {
            .app => {
                log.warn("resize_window to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring resize_window", .{});
                    return false;
                };

                return window.resizeSurface(surface, value);
            },
        }
    }

    pub fn ringBell(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setBellRinging(true),
        }
    }

    pub fn scrollbar(
        target: apprt.Target,
        value: apprt.Action.Value(.scrollbar),
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setScrollbar(value),
        }
    }

    pub fn startSearch(target: apprt.Target, value: apprt.action.StartSearch) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(true, value.needle),
        }
    }

    pub fn endSearch(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(false, ""),
        }
    }

    pub fn searchTotal(target: apprt.Target, value: apprt.action.SearchTotal) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchTotal(value.total),
        }
    }

    pub fn searchSelected(target: apprt.Target, value: apprt.action.SearchSelected) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchSelected(value.selected),
        }
    }

    pub fn setTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) void {
        switch (target) {
            .app => log.warn("set_title to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setTitle(value.title),
        }
    }

    pub fn setTabTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        switch (target) {
            .app => {
                log.warn("set_tab_title to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tab = ext.getAncestor(
                    Tab,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a tab, ignoring set_tab_title", .{});
                    return false;
                };
                tab.setTitleOverride(if (value.title.len == 0) null else value.title);
                return true;
            },
        }
    }

    pub fn setWindowTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) bool {
        switch (target) {
            .app => {
                log.warn("set_tab_title to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring set_window_title", .{});
                    return false;
                };
                window.setTitleOverride(if (value.title.len == 0) null else value.title);
                return true;
            },
        }
    }

    pub fn showChildExited(
        target: apprt.Target,
        value: apprt.surface.Message.ChildExited,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.surface.childExited(value),
        };
    }

    pub fn showGtkInspector() void {
        gtk.Window.setInteractiveDebugging(@intFromBool(true));
    }

    pub fn sizeLimit(
        target: apprt.Target,
        value: apprt.action.SizeLimit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Note: we ignore the max size currently because we have
                // no mechanism to enforce it.
                const surface = core.rt_surface.surface;
                surface.setMinSize(.{
                    .width = value.min_width,
                    .height = value.min_height,
                });

                return true;
            },
        }
    }

    pub fn toggleFullscreen(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleFullscreen(),
        }
    }

    pub fn toggleQuickTerminal(self: *Application) bool {
        // If we already have a quick terminal window, we just toggle the
        // visibility of it.
        if (getQuickTerminalWindow()) |win| {
            win.toggleVisibility();
            return true;
        }

        // If we don't support quick terminals then we do nothing.
        if (!self.winproto().supportsQuickTerminal()) return false;

        // Create our new window as a quick terminal
        const win = gobject.ext.newInstance(Window, .{
            .application = self,
            .@"quick-terminal" = true,
        });
        assert(win.isQuickTerminal());
        initAndShowWindow(self, win, null, .none);
        return true;
    }

    pub fn toggleSplitZoom(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("toggle_split_zoom to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // TODO: pass surface ID when we have that
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring toggle_split_zoom", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return surface.as(gtk.Widget).activateAction("split-tree.zoom", null) != 0;
            },
        }
    }

    pub fn showOnScreenKeyboard(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("show_on_screen_keyboard to app is unexpected", .{});
                return false;
            },
            // NOTE: Even though `activateOsk` takes a gdk.Event, it's currently
            // unused by all implementations of `activateOsk` as of GTK 4.18.
            // The commit that introduced the method (ce6aa73c) clarifies that
            // the event *may* be used by other IM backends, but for Linux desktop
            // environments this doesn't matter.
            .surface => |v| return v.rt_surface.surface.showOnScreenKeyboard(null),
        }
    }

    fn getQuickTerminalWindow() ?*Window {
        // Find a quick terminal window.
        const list = gtk.Window.listToplevels();
        defer list.free();
        if (ext.listFind(gtk.Window, list, struct {
            fn find(gtk_win: *gtk.Window) bool {
                const win = gobject.ext.cast(
                    Window,
                    gtk_win,
                ) orelse return false;
                return win.isQuickTerminal();
            }
        }.find)) |w| return gobject.ext.cast(
            Window,
            w,
        ).?;

        return null;
    }

    pub fn toggleMaximize(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleMaximize(),
        }
    }

    pub fn toggleTabOverview(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                window.toggleTabOverview();
                return true;
            },
        }
    }

    pub fn toggleWindowDecorations(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring toggle_window_decorations", .{});
                    return false;
                };

                window.toggleWindowDecorations();
                return true;
            },
        }
    }

    pub fn toggleCommandPalette(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().toggleCommandPalette();
            },
        }
    }

    pub fn controlInspector(target: apprt.Target, value: apprt.Action.Value(.inspector)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().controlInspector(value);
            },
        }
    }

    pub fn commandFinished(target: apprt.Target, value: apprt.Action.Value(.command_finished)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().commandFinished(value);
            },
        }
    }

    pub fn setReadonly(target: apprt.Target, value: apprt.Action.Value(.readonly)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().setReadonly(value);
            },
        }
    }

    pub fn keySequence(target: apprt.Target, value: apprt.Action.Value(.key_sequence)) bool {
        switch (target) {
            .app => {
                log.warn("key_sequence action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keySequenceAction(value) catch |err| {
                    log.warn("error handling key_sequence action: {}", .{err});
                };
                return true;
            },
        }
    }

    pub fn keyTable(target: apprt.Target, value: apprt.Action.Value(.key_table)) bool {
        switch (target) {
            .app => {
                log.warn("key_table action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keyTableAction(value) catch |err| {
                    log.warn("error handling key_table action: {}", .{err});
                };
                return true;
            },
        }
    }
};

pub fn findActiveWindow(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(@constCast(data orelse return -1)));

    // Confusingly, `isActive` returns 1 when active,
    // but we want to return 0 to indicate equality.
    // Abusing integers to be enums and booleans is a terrible idea, C.
    return if (window.isActive() != 0) 0 else -1;
}
