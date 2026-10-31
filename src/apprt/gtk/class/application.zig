const builtin = @import("builtin");
const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const glibunix = @import("glibunix");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const build_info = @import("../build/info.zig");
const cli = @import("../../../cli.zig");
const global = @import("../../../global.zig");
const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const CoreApp = @import("../../../App.zig");
const compat_file = @import("../../../lib/compat/file.zig");
const compat_fd = @import("../../../lib/compat/fd.zig");
const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/main.zig");
const systemd = @import("../../../os/systemd.zig");
const xev = global.xev;
const Binding = @import("../../../input.zig").Binding;
const CoreConfig = configpkg.Config;

const ext = @import("../ext.zig");
const key = @import("../key.zig");
const adw_version = @import("../adw_version.zig");
const gtk_version = @import("../gtk_version.zig");
const winprotopkg = @import("../winproto.zig");
const ApprtApp = @import("../App.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Config = @import("config.zig").Config;
const actions = @import("actions.zig");
const Action = actions.Action;
const Surface = @import("surface.zig").Surface;
const SplitTree = @import("split_tree.zig").SplitTree;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const ConfigErrorsDialog = @import("config_errors_dialog.zig").ConfigErrorsDialog;
const ContainerClient = @import("container_client.zig").Client;
const PtyxisContainer = @import("container_object.zig").Container;
const PreferencesWindow = @import("preferences_window.zig").PreferencesWindow;
const ProfileEditor = @import("profile_editor.zig").ProfileEditor;
const palette_mod = @import("palette.zig");

comptime {
    _ = ContainerClient.spawn;
    _ = ContainerClient.listContainers;
    _ = ContainerClient.listAsModel;
    _ = ContainerClient.createPty;
    _ = ContainerClient.spawnInContainer;
    _ = ContainerClient.deinit;
    _ = PtyxisContainer.new;
    _ = PtyxisContainer.getGObjectType;
    _ = PreferencesWindow.new;
    _ = PreferencesWindow.getGObjectType;
    _ = ProfileEditor.new;
    _ = ProfileEditor.getGObjectType;
    _ = palette_mod.loadAll;
}
const GlobalShortcuts = @import("global_shortcuts.zig").GlobalShortcuts;
const OpenURI = @import("../portal.zig").OpenURI;
const media = @import("../media.zig");
const Overrides = @import("Overrides.zig");

const log = std.log.scoped(.gtk_ghostty_application);

extern "c" fn setenv(name: ?[*]const u8, value: ?[*]const u8, overwrite: c_int) c_int;

/// Function used to funnel GLib/GObject/GTK log messages into Zig's logging
/// system rather than just getting dumped directly to stderr.
fn glibLogWriterFunction(
    level: glib.LogLevelFlags,
    fields: [*]const glib.LogField,
    n_fields: usize,
    _: ?*anyopaque,
) callconv(.c) glib.LogWriterOutput {
    const glib_log = std.log.scoped(.glib);

    var message_: ?[]const u8 = null;
    var domain_: ?[]const u8 = null;
    for (0..n_fields) |i| {
        const field = fields[i];
        const k = std.mem.span(field.f_key orelse continue);
        const v: []const u8 = v: {
            if (field.f_length >= 0) {
                const v: [*]const u8 = @ptrCast(field.f_value orelse continue);
                break :v v[0..@intCast(field.f_length)];
            }
            const v: [*:0]const u8 = @ptrCast(field.f_value orelse continue);
            break :v std.mem.span(v);
        };
        if (std.mem.eql(u8, k, "MESSAGE")) {
            message_ = v;
            continue;
        }
        if (std.mem.eql(u8, k, "GLIB_DOMAIN")) {
            domain_ = v;
            continue;
        }
    }

    const message = message_ orelse return .unhandled;
    const domain = domain_ orelse "«unknown»";

    if (level.level_error) {
        glib_log.err("ERROR: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_critical) {
        glib_log.err("CRITICAL: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_warning) {
        glib_log.warn("WARNING: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_message) {
        glib_log.info("MESSAGE: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_info) {
        glib_log.info("INFO: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_debug) {
        glib_log.debug("DEBUG: {s}: {s}", .{ domain, message });
        return .handled;
    }
    glib_log.debug("UNKNOWN: {s}: {s}", .{ domain, message });
    return .handled;
}

/// The primary entrypoint for the Ghostty GTK application.
///
/// This requires a `ghostty.App` and `ghostty.Config` and takes
/// care of the rest. Call `run` to run the application to completion.
pub const Application = extern struct {
    /// This type creates a new GObject class. Since the Application is
    /// the primary entrypoint I'm going to use this as a place to document
    /// how this all works and where you can find resources for it, but
    /// this applies to any other GObject class within this apprt.
    ///
    /// The various fields (parent_instance) and constants (Parent,
    /// getGObjectType, etc.) are mandatory "interfaces" for zig-gobject
    /// to create a GObject class.
    ///
    /// I found these to be the best resources:
    ///
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/extensions/gobject2.zig
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/example/src/custom_class.zig
    ///
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyApplication",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                "config",
                Self,
                ?*Config,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Config,
                        .{
                            .getter = Self.getConfig,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The apprt App. This is annoying that we need this it'd be
        /// nicer to just make THIS the apprt app but the current libghostty
        /// API doesn't allow that.
        rt_app: *ApprtApp,

        /// The libghostty App instance.
        core_app: *CoreApp,

        /// The configuration for the application.
        config: *Config,

        /// State and logic for the underlying windowing protocol.
        winproto: winprotopkg.App,

        /// The global shortcut logic.
        global_shortcuts: *GlobalShortcuts,

        /// This is set to true so long as we request a window exactly
        /// once. This prevents quitting the app before we've shown one
        /// window.
        requested_window: bool = false,

        /// This is set to false internally when the event loop
        /// should exit and the application should quit. This must
        /// only be set by the main loop thread.
        running: bool = false,

        /// True once we've told systemd that startup is complete. Reloads
        /// before then (e.g. syncing the color scheme during startup) must
        /// not notify systemd, or it sees READY=1 before we're ready.
        systemd_ready: bool = false,

        /// The timer used to quit the application after the last window is
        /// closed. Even if there is no quit delay set, this is the state
        /// used to determine to close the app.
        quit_timer: union(enum) {
            off,
            active: c_uint,
            expired,
        } = .off,

        /// If non-null, we're currently showing a config errors dialog.
        /// This is a WeakRef because the dialog can close on its own
        /// outside of our own lifecycle and that's okay.
        config_errors_dialog: WeakRef(ConfigErrorsDialog) = .empty,

        /// glib source for our signal handler.
        signal_source: ?c_uint = null,

        /// CSS Provider for any styles based on Ghostty configuration values.
        css_provider: *gtk.CssProvider,

        /// Providers for loading custom stylesheets defined by user
        custom_css_providers: std.ArrayListUnmanaged(*gtk.CssProvider) = .empty,

        /// A copy of the LANG environment variable that was provided to Ghostty
        /// by the system. If this is null, the LANG environment variable did
        /// not exist in Ghostty's environment variable.
        saved_language: ?[:0]const u8 = null,

        open_uri: OpenURI = undefined,

        // The audio bell's MediaFile, reused across bells so we don't leak a
        // GStreamer pipeline (and its GL threads) on every ring. Built lazily
        // on the first audio bell and rebuilt when `bell-audio-path` changes;
        // unref'd on dispose. See ringBell and media.zig.
        bell_media: ?*gtk.MediaFile = null,
        /// Connected ptyxis-agent client + cached container list as a
        /// Gio.ListStore<GhosttyPtyxisContainer>. Both null until startup
        /// successfully spawns the agent.
        container_client: ?ContainerClient = null,
        container_model: ?*gio.ListStore = null,

        /// Set by the window's container-spawn path immediately before
        /// performBindingAction(.new_tab). The next Surface to initialize
        /// consumes this fd and adopts it instead of forking a child.
        /// Cleared on consume so it never leaks into an unrelated surface.
        pending_external_master_fd: ?c_int = null,

        /// Display name + symbolic icon name to apply to the next tab
        /// created during the container-spawn flow. Cleared on consume.
        pending_container_title: ?[:0]const u8 = null,
        pending_container_icon: ?[:0]const u8 = null,

        /// Active GLib timeout id for the debounced reload trigger.
        /// Slider drags can fire value-changed 30+ times/sec; debouncing
        /// at 300ms collapses those into a single config reload.
        pending_reload_timer: c_uint = 0,

        /// True while the in-flight config reload was initiated by us rather
        /// than by the user (the style picker writing `window-theme`, or a
        /// soft reload after a desktop light/dark switch). Windows read this
        /// to skip the "Reloaded the configuration" toast, which should only
        /// appear for reloads the user actually asked for. Set for the whole
        /// reload — every window reads it — and recomputed on the next one.
        quiet_reload: bool = false,

        /// Requested by triggerReloadOpts, consumed by the reload it queued.
        pending_quiet_reload: bool = false,

        pub var offset: c_int = 0;
    };

    /// Get this application as the default, allowing access to its
    /// properties globally.
    ///
    /// This asserts that there is a default application and that the
    /// default application is a GhosttyApplication. The program would have
    /// to be in a very bad state for this to be violated.
    pub fn default() *Self {
        const app = gio.Application.getDefault().?;
        return gobject.ext.cast(Self, app).?;
    }

    /// Creates a new Application instance.
    ///
    /// This does a lot more work than a typical class instantiation,
    /// because we expect that this is the main program entrypoint.
    ///
    /// The only failure mode of initializing the application is early OOM.
    /// Early OOM can't be recovered from. Every other error is mapped to
    /// some degraded state where we can at least show a window with an error.
    pub fn new(
        rt_app: *ApprtApp,
        core_app: *CoreApp,
    ) Allocator.Error!*Self {
        const alloc = core_app.alloc;

        // Capture GLib/GObject/GTK log messages and funnel them through Zig's
        // logging system rather than just getting dumped directly to stderr.
        _ = glib.logSetWriterFunc(glibLogWriterFunction, null, null);

        // Log our GTK versions
        gtk_version.logVersion();
        adw_version.logVersion();

        // Load our configuration.
        var config = CoreConfig.load(alloc) catch |err| err: {
            // If we fail to load the configuration, then we should log
            // the error in the diagnostics so it can be shown to the user.
            // We can still load a default which only fails for OOM, allowing
            // us to startup.
            var def: CoreConfig = try .default(alloc);
            errdefer def.deinit();
            try def.addDiagnosticFmt(
                "error loading user configuration: {}",
                .{err},
            );

            break :err def;
        };
        defer config.deinit();

        // Set the old language,
        const saved_language: ?[:0]const u8 = saved_language: {
            const old_language = old_language: {
                const lang = global.environ().getPosix("LANG") orelse break :old_language null;
                break :old_language alloc.dupeSentinel(u8, @ptrCast(lang), 0) catch null;
            };
            if (config.language) |language| {
                // Override LANG if we need to (sync global environs if so)
                _ = setenv("LANG", @ptrCast(language), 1);
                global.syncEnviron();
            }
            break :saved_language old_language;
        };

        // Set gettext global domain to be our app so that our unqualified
        // translations map to our translations.
        internal_os.i18n.initGlobalDomain() catch |err| {
            // Failures shuldn't stop application startup. Our app may
            // not translate correctly but it should still work. In the
            // future we may want to add this to the GUI to show.
            log.warn("i18n initialization failed error={}", .{err});
        };

        // Setup our GTK init env vars
        setGtkEnv(&config) catch |err| switch (err) {
            error.WriteFailed => {
                // If we fail to set GTK environment variables then we still
                // try to start the application...
                log.warn(
                    "error setting GTK environment variables err={}",
                    .{err},
                );
            },
        };
        adw.init();

        const single_instance = switch (config.@"gtk-single-instance") {
            .true => true,
            .false => false,
            // This should have been resolved to true/false during config loading.
            .detect => unreachable,
        };

        // Setup the flags for our application.
        const app_flags: gio.ApplicationFlags = app_flags: {
            var flags: gio.ApplicationFlags = .flags_default_flags;
            if (!single_instance) flags.non_unique = true;
            break :app_flags flags;
        };

        // Our app ID determines uniqueness and maps to our desktop file.
        // We append "-debug" to the ID if we're in debug mode so that we
        // can develop Ghostty in Ghostty.
        const app_id: [:0]const u8 = app_id: {
            if (config.class) |class| {
                if (gio.Application.idIsValid(class) != 0) {
                    break :app_id class;
                } else {
                    log.warn("invalid 'class' in config, ignoring", .{});
                }
            }

            break :app_id build_info.application_id;
        };

        const display: *gdk.Display = gdk.Display.getDefault() orelse {
            // I'm unsure of any scenario where this happens. Because we don't
            // want to litter null checks everywhere, we just exit here.
            log.warn("gdk display is null, exiting", .{});
            std.process.exit(1);
        };

        // Setup our windowing protocol logic
        var wp: winprotopkg.App = winprotopkg.App.init(
            alloc,
            display,
            app_id,
            &config,
        ) catch |err| wp: {
            // If we fail to detect or setup the windowing protocol
            // specifies, we fallback to a noop implementation so we can
            // still launch.
            log.warn("error initializing windowing protocol err={}", .{err});
            break :wp .{ .none = .{} };
        };
        errdefer wp.deinit();
        log.debug("windowing protocol={s}", .{@tagName(wp)});

        // Create our GTK Application which encapsulates our process.
        log.debug("creating GTK application id={s} single-instance={}", .{
            app_id,
            single_instance,
        });

        // Wrap our configuration in a GObject.
        const config_obj: *Config = try .new(alloc, &config);
        errdefer config_obj.unref();

        // Internally, GTK ensures that only one instance of this provider
        // exists in the provider list for the display.
        const css_provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(
            display,
            css_provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3,
        );
        errdefer css_provider.unref();

        // Initialize the app.
        const self = gobject.ext.newInstance(Self, .{
            .application_id = app_id.ptr,
            .flags = app_flags,

            // Force the resource path to a known value so it doesn't depend
            // on the app id (which changes between debug/release and can be
            // user-configured) and force it to load in compiled resources.
            .resource_base_path = build_info.resource_path,
        });

        // Setup our private state. More setup is done in the init
        // callback that GObject calls, but we can't pass this data through
        // to there (and we don't need it there directly) so this is here.
        const priv: *Private = self.private();
        priv.* = .{
            .rt_app = rt_app,
            .core_app = core_app,
            .config = config_obj,
            .winproto = wp,
            .css_provider = css_provider,
            .custom_css_providers = .empty,
            .global_shortcuts = gobject.ext.newInstance(GlobalShortcuts, .{}),
            .saved_language = saved_language,
            .open_uri = .init(rt_app),
        };

        // Signals
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            propConfig,
            self,
            .{ .detail = "config" },
        );

        _ = gtk.CssProvider.signals.parsing_error.connect(
            css_provider,
            *Self,
            signalCssParsingError,
            self,
            .{},
        );

        // Trigger initial config changes
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        return self;
    }

    /// Force deinitialize the application.
    ///
    /// Normally in a GObject lifecycle, this would be called by the
    /// finalizer. But applications are never fully unreferenced so this
    /// ensures that our memory is cleaned up properly.
    pub fn deinit(self: *Self) void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        priv.config.unref();
        priv.winproto.deinit();
        priv.open_uri.deinit();
        priv.global_shortcuts.unref();
        if (priv.saved_language) |language| alloc.free(language);
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                priv.css_provider.as(gtk.StyleProvider),
            );

            for (priv.custom_css_providers.items) |provider| {
                gtk.StyleContext.removeProviderForDisplay(
                    display,
                    provider.as(gtk.StyleProvider),
                );
            }
        }
        priv.css_provider.unref();
        for (priv.custom_css_providers.items) |provider| provider.unref();
        priv.custom_css_providers.deinit(alloc);
    }

    /// The global allocator that all other classes should use by
    /// calling `Application.default().allocator()`. Zig code should prefer
    /// this wherever possible so we get leak detection in debug/tests.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().core_app.alloc;
    }

    /// Get the original language that Ghostty was launched with. This returns a
    /// pointer to internal memory so it must be copied by callers.
    pub fn savedLanguage(self: *Self) ?[:0]const u8 {
        return self.private().saved_language;
    }

    /// Run the application. This is a replacement for `gio.Application.run`
    /// because we want more tight control over our event loop so we can
    /// integrate it with libghostty.
    pub fn run(self: *Self) !void {
        // Based on the actual `gio.Application.run` implementation:
        // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533

        // Acquire the default context for the application
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;

        // The final cleanup that is always required at the end of running.
        defer {
            // Ensure our timer source is removed
            self.stopQuitTimer();

            // Sync any remaining settings
            gio.Settings.sync();

            // Clear out the event loop, don't block.
            while (glib.MainContext.iteration(ctx, 0) != 0) {}

            // Release the context so something else can use it.
            defer glib.MainContext.release(ctx);
        }

        // Register the application
        var err_: ?*glib.Error = null;
        if (self.as(gio.Application).register(
            null,
            &err_,
        ) == 0) {
            if (err_) |err| {
                defer err.free();
                log.warn(
                    "error registering application: {s}",
                    .{err.f_message orelse "(unknown)"},
                );
            }

            return error.ApplicationRegisterFailed;
        }
        assert(err_ == null);

        // This just calls the `activate` signal but its part of the normal startup
        // routine so we just call it, but only if the config allows it (this allows
        // for launching Ghostty in the "background" without immediately opening
        // a window).
        //
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        const priv = self.private();
        {
            // We need to scope any config access because once we run our
            // event loop, this can change out from underneath us.
            const config = priv.config.get();
            if (config.@"initial-window") self.as(gio.Application).activate();
        }

        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running.
        if (self.as(gio.Application).getIsRemote() != 0) {
            log.debug(
                "application is remote, exiting run loop after activation",
                .{},
            );
            return;
        }

        // Tell systemd that we are ready.
        systemd.notify.ready();
        priv.systemd_ready = true;

        log.debug("entering runloop", .{});
        defer log.debug("exiting runloop", .{});
        priv.running = true;
        while (priv.running) {
            _ = glib.MainContext.iteration(ctx, 1);

            // Tick the core Ghostty terminal app
            try priv.core_app.tick(priv.rt_app);

            // Check if we must quit based on the current state.
            const must_quit = q: {
                // If we are configured to always stay running, don't quit.
                const config = priv.config.get();
                if (!config.@"quit-after-last-window-closed") break :q false;

                // If the quit timer has expired, quit.
                if (priv.quit_timer == .expired) {
                    log.debug("must_quit due to quit timer expired", .{});
                    break :q true;
                }

                // If we have no windows attached to our app, also quit.
                // We only do this if we don't have the closed delay set,
                // because with the closed delay set we'll exit eventually.
                if (config.@"quit-after-last-window-closed-delay" == null) {
                    if (priv.requested_window and @as(
                        ?*glib.List,
                        self.as(gtk.Application).getWindows(),
                    ) == null) {
                        log.debug("must_quit due to no app windows", .{});
                        break :q true;
                    }
                }

                // No quit conditions met
                break :q false;
            };

            if (must_quit) {
                // All must quit scenarios do not need confirmation.
                // Furthermore, must quit scenarios may result in a situation
                // where its unsafe to even access the app/surface memory
                // since its in the process of being freed. We must simply
                // begin our exit immediately.
                self.quitNow();
            }
        }
    }

    /// Quit the application. This will start the process to stop the
    /// run loop. It will not `posix.exit`.
    pub fn quit(self: *Self) void {
        const priv = self.private();

        // If our run loop has already exited then we are done.
        if (!priv.running) return;

        // If our core app doesn't need to confirm quit then we
        // can exit immediately.
        if (!priv.core_app.needsConfirmQuit()) {
            self.quitNow();
            return;
        }

        // Get the parent for our dialog
        const parent: ?*gtk.Widget = parent: {
            const list = gtk.Window.listToplevels();
            defer list.free();
            const focused = @as(?*glib.List, list.findCustom(
                null,
                actions.findActiveWindow,
            )) orelse {
                // If we have an active surface then we should have
                // a window available but in the rare case we don't we
                // should exit so we don't crash.
                break :parent null;
            };
            break :parent @ptrCast(@alignCast(focused.f_data));
        };

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.app);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Application,
            handleCloseConfirmation,
            self,
            .{},
        );

        // Show it
        dialog.present(parent);
    }

    fn quitNow(self: *Self) void {
        // Get all our windows and destroy them, forcing them to free.
        const list = gtk.Window.listToplevels();
        defer list.free();
        list.foreach(struct {
            fn callback(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const ptr = data orelse return;
                const window: *gtk.Window = @ptrCast(@alignCast(ptr));

                // We only want to destroy our windows. These windows own
                // every other type of window that is possible so this will
                // trigger a proper shutdown sequence.
                //
                // We previously just destroyed ALL windows but this leads to
                // a double-free with the fcitx ime, because it has a nested
                // gtk.Window as a property that we don't own and it later
                // tries to free on its own. I think this is probably a bug in
                // the fcitx ime widget but still, we don't want a double free!
                if (gobject.ext.isA(window, Window)) {
                    window.destroy();
                }
            }
        }.callback, null);

        // Trigger our runloop exit.
        self.private().running = false;
    }

    /// apprt API to perform an action.
    pub fn performAction(
        self: *Self,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .close_tab => return Action.closeTab(target, value),
            .close_window => return Action.closeWindow(target),

            .copy_title_to_clipboard => return Action.copyTitleToClipboard(target),

            .config_change => try Action.configChange(
                self,
                target,
                value.config,
            ),

            .desktop_notification => Action.desktopNotification(self, target, value),

            .equalize_splits => return Action.equalizeSplits(target),

            .goto_split => return Action.gotoSplit(target, value),

            .goto_window => return Action.gotoWindow(value),

            .goto_tab => return Action.gotoTab(target, value),

            .initial_size => return Action.initialSize(target, value),

            .inspector => return Action.controlInspector(target, value),
            .export_terminal_io => return try Action.exportTerminalIO(
                self,
                target,
                value,
            ),

            .key_sequence => return Action.keySequence(target, value),
            .key_table => return Action.keyTable(target, value),

            .mouse_over_link => Action.mouseOverLink(target, value),
            .mouse_shape => Action.mouseShape(target, value),
            .mouse_visibility => Action.mouseVisibility(target, value),

            .move_tab => return Action.moveTab(target, value),
            .move_tab_to_new_window => return Action.moveTabToNewWindow(target),

            .new_split => return Action.newSplit(target, value),

            .new_tab => return Action.newTab(target, .none),

            .new_window => try Action.newWindow(
                self,
                switch (target) {
                    .app => null,
                    .surface => |v| v,
                },
                .none,
            ),

            .open_config => return Action.openConfig(self, value),

            .open_url => Action.openUrl(self, value),

            .pwd => Action.pwd(target, value),

            .present_terminal => return Action.presentTerminal(target),

            .progress_report => return Action.progressReport(target, value),

            .prompt_title => return Action.promptTitle(target, value),

            .quit => self.quit(),

            .quit_timer => try Action.quitTimer(self, value),

            .reload_config => try Action.reloadConfig(self, target, value),

            .render => Action.render(target),

            .resize_split => return Action.resizeSplit(target, value),

            .resize_window => return Action.resizeWindow(target, value),

            .ring_bell => Action.ringBell(target),

            // GTK has no accessibility consumer for this yet.
            .selection_changed => {},

            .scrollbar => Action.scrollbar(target, value),

            .set_title => Action.setTitle(target, value),
            .set_tab_title => return Action.setTabTitle(target, value),
            .set_window_title => return Action.setWindowTitle(target, value),

            .show_child_exited => return Action.showChildExited(target, value),

            .show_gtk_inspector => Action.showGtkInspector(),

            .size_limit => return Action.sizeLimit(target, value),

            .toggle_maximize => Action.toggleMaximize(target),
            .toggle_fullscreen => Action.toggleFullscreen(target),
            .toggle_quick_terminal => return Action.toggleQuickTerminal(self),
            .toggle_tab_overview => return Action.toggleTabOverview(target),
            .toggle_window_decorations => return Action.toggleWindowDecorations(target),
            .toggle_command_palette => return Action.toggleCommandPalette(target),
            .toggle_split_zoom => return Action.toggleSplitZoom(target),
            .show_on_screen_keyboard => return Action.showOnScreenKeyboard(target),
            .command_finished => return Action.commandFinished(target, value),
            .readonly => return Action.setReadonly(target, value),

            .start_search => Action.startSearch(target, value),
            .end_search => Action.endSearch(target),
            .search_total => Action.searchTotal(target, value),
            .search_selected => Action.searchSelected(target, value),

            // cell_size fires when the font metrics change (zoom in/out).
            // The renderer already handles reflowing; we just acknowledge it.
            // Full window-step-resize support can be added later.
            .cell_size => return switch (target) {
                .app => false,
                .surface => true,
            },

            // Unimplemented
            .secure_input,
            .close_all_windows,
            .float_window,
            .toggle_visibility,
            .toggle_background_opacity,
            .render_inspector,
            .renderer_health,
            .color_change,
            .reset_window_size,
            .check_for_updates,
            .undo,
            .redo,
            => {
                log.warn("unimplemented action={}", .{action});
                return false;
            },
        }

        // Assume it was handled. The unhandled case must be explicit
        // in the switch above.
        return true;
    }

    /// Returns the core app associated with this application. This is
    /// not a reference-counted type so you should not store this.
    pub fn core(self: *Self) *CoreApp {
        return self.private().core_app;
    }

    /// Returns the apprt application associated with this application.
    pub fn rt(self: *Self) *ApprtApp {
        return self.private().rt_app;
    }

    /// Returns the app winproto implementation.
    pub fn winproto(self: *Self) *winprotopkg.App {
        return &self.private().winproto;
    }

    /// Returns the open URI portal implementation.
    pub fn openUri(self: *Self) *OpenURI {
        return &self.private().open_uri;
    }

    /// Mark that a window request has been made so the quit policy does not
    /// race a delayed window creation.
    pub fn markWindowRequested(self: *Self) void {
        self.private().requested_window = true;
    }

    /// Whether startup has completed far enough for systemd reload notices.
    pub fn systemdReady(self: *Self) bool {
        return self.private().systemd_ready;
    }

    /// Set the reload-origin state consumed by the next config reload.
    pub fn beginConfigReload(self: *Self, soft: bool) void {
        const priv = self.private();
        priv.quiet_reload = soft or priv.pending_quiet_reload;
        priv.pending_quiet_reload = false;
    }

    /// This will get called when there are no more open surfaces.
    pub fn startQuitTimer(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // Cancel any previous timer.
        self.stopQuitTimer();

        // This is a no-op unless we are configured to quit after last window is closed.
        if (!config.@"quit-after-last-window-closed") return;

        // If a delay is configured, set a timeout function to quit after the delay.
        if (config.@"quit-after-last-window-closed-delay") |v| {
            priv.quit_timer = .{
                .active = glib.timeoutAdd(
                    v.asMilliseconds(),
                    handleQuitTimerExpired,
                    self,
                ),
            };
        } else {
            // If no delay is configured, treat it as expired.
            priv.quit_timer = .expired;
        }
    }

    /// This will get called when a new surface gets opened.
    pub fn stopQuitTimer(self: *Self) void {
        const priv = self.private();
        switch (priv.quit_timer) {
            .off => {},
            .expired => priv.quit_timer = .off,
            .active => |source| {
                if (glib.Source.remove(source) == 0) {
                    log.warn(
                        "unable to remove quit timer source={d}",
                        .{source},
                    );
                }

                priv.quit_timer = .off;
            },
        }
    }

    fn loadRuntimeCss(self: *Self) (Allocator.Error || std.Io.Writer.Error)!void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        const config = priv.config.get();

        var buf: std.Io.Writer.Allocating = try .initCapacity(alloc, 2048);
        defer buf.deinit();

        const writer = &buf.writer;

        // Load standard css first as it can override some of the user configured styling.
        try loadRuntimeCss414(config, writer);
        try loadRuntimeCss416(config, writer);

        const unfocused_fill: CoreConfig.Color = config.@"unfocused-split-fill" orelse config.background;

        try writer.print(
            \\widget.unfocused-split {{
            \\ opacity: {d:.2};
            \\ background-color: rgb({d},{d},{d});
            \\}}
            \\
        , .{
            1.0 - config.@"unfocused-split-opacity",
            unfocused_fill.r,
            unfocused_fill.g,
            unfocused_fill.b,
        });

        if (config.@"split-divider-color") |color| {
            try writer.print(
                \\.window .split paned > separator {{
                \\  color: rgb({[r]d},{[g]d},{[b]d});
                \\  background: rgb({[r]d},{[g]d},{[b]d});
                \\}}
                \\
            , .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            });
        }

        if (config.@"window-title-font-family") |font_family| {
            try writer.print(
                \\.window headerbar {{
                \\  font-family: "{[font_family]s}";
                \\}}
                \\
            , .{ .font_family = font_family });
        }

        const contents = buf.written();

        log.debug("runtime CSS is {d} bytes", .{contents.len});

        const bytes = glib.Bytes.new(contents.ptr, contents.len);
        defer bytes.unref();

        // Clears any previously loaded CSS from this provider
        priv.css_provider.loadFromBytes(bytes);
    }

    /// Load runtime CSS for older than GTK 4.16
    fn loadRuntimeCss414(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeAtLeast(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        switch (window_theme) {
            .ghostty => try writer.print(
                \\windowhandle {{
                \\  background-color: rgb({d},{d},{d});
                \\  color: rgb({d},{d},{d});
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: oklab(from rgb({d},{d},{d}) calc(l * 0.9) a b / alpha);
                \\}}
                \\
            , .{
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    /// Load runtime for GTK 4.16 and newer
    fn loadRuntimeCss416(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeUntil(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        try writer.writeAll(
            \\/*
            \\ * Child Exited Overlay
            \\ */
            \\
            \\.child-exited.normal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--success-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.child-exited.abnormal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Surface
            \\ */
            \\
            \\.surface progressbar.error trough progress {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.surface .bell-overlay {
            \\  border-color: color-mix(
            \\    in srgb,
            \\    var(--accent-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Drag and Drop Overlay
            \\ */
            \\.drop-overlay.drop-left {
            \\  background: linear-gradient(
            \\    to left,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\.drop-overlay.drop-right {
            \\  background: linear-gradient(
            \\    to right,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\.drop-overlay.drop-top {
            \\  background: linear-gradient(
            \\    to top,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\.drop-overlay.drop-bottom {
            \\  background: linear-gradient(
            \\    to bottom,
            \\    transparent, 50%,
            \\    color-mix(in srgb, var(--accent-bg-color), transparent 80%) 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Splits
            \\ */
            \\
            \\.window .split paned > separator {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--window-bg-color),
            \\    transparent 0%
            \\  );
            \\}
            \\
        );

        switch (window_theme) {
            .ghostty => try writer.print(
                \\:root {{
                \\  --ghostty-fg: rgb({d},{d},{d});
                \\  --ghostty-bg: rgb({d},{d},{d});
                \\  --headerbar-fg-color: var(--ghostty-fg);
                \\  --headerbar-bg-color: var(--ghostty-bg);
                \\  --headerbar-backdrop-color: oklab(from var(--headerbar-bg-color) calc(l * 0.9) a b / alpha);
                \\  --overview-fg-color: var(--ghostty-fg);
                \\  --overview-bg-color: var(--ghostty-bg);
                \\  --popover-fg-color: var(--ghostty-fg);
                \\  --popover-bg-color: var(--ghostty-bg);
                \\  --window-fg-color: var(--ghostty-fg);
                \\  --window-bg-color: var(--ghostty-bg);
                \\}}
                \\listview.command-palette-view {{
                \\  --view-fg-color: var(--ghostty-fg);
                \\  --view-bg-color: var(--ghostty-bg);
                \\}}
                \\windowhandle {{
                \\  background-color: var(--headerbar-bg-color);
                \\  color: var(--headerbar-fg-color);
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: var(--headerbar-backdrop-color);
                \\}}
            , .{
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    const LoadCustomCssError = std.Io.File.OpenError ||
        compat_file.ReadToEndAllocError ||
        std.mem.Allocator.Error;

    fn loadCustomCss(self: *Self) LoadCustomCssError!void {
        const priv: *Private = self.private();
        const alloc = self.allocator();
        const display = gdk.Display.getDefault() orelse {
            log.warn("unable to get display", .{});
            return;
        };

        // unload the previously loaded style providers
        for (priv.custom_css_providers.items) |provider| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
            );
            provider.unref();
        }
        priv.custom_css_providers.clearRetainingCapacity();

        const config = priv.config.get();
        for (config.@"gtk-custom-css".value.items) |p| {
            const path, const optional = switch (p) {
                .optional => |path| .{ path, true },
                .required => |path| .{ path, false },
            };
            const file = std.Io.Dir.openFileAbsolute(
                global.io(),
                path,
                .{},
            ) catch |err| {
                if (err != error.FileNotFound or !optional) {
                    log.warn(
                        "error opening gtk-custom-css file {s}: {}",
                        .{ path, err },
                    );
                }
                continue;
            };
            defer file.close(global.io());

            const css_file_size_limit = 5 * 1024 * 1024; // 5MB

            log.info("loading gtk-custom-css path={s}", .{path});

            const contents = compat_file.readToEndAlloc(
                file,
                alloc,
                css_file_size_limit,
            ) catch |err| switch (err) {
                error.FileTooBig => {
                    log.warn("gtk-custom-css file {s} was larger than {Bi}", .{ path, css_file_size_limit });
                    continue;
                },
                else => |e| return e,
            };

            defer alloc.free(contents);

            const bytes = glib.Bytes.new(contents.ptr, contents.len);
            defer bytes.unref();

            const css_provider = gtk.CssProvider.new();
            errdefer css_provider.unref();

            _ = gtk.CssProvider.signals.parsing_error.connect(
                css_provider,
                *Self,
                signalCssParsingError,
                self,
                .{},
            );

            try priv.custom_css_providers.append(alloc, css_provider);

            css_provider.loadFromBytes(bytes);

            gtk.StyleContext.addProviderForDisplay(
                display,
                css_provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_USER,
            );
        }
    }

    fn syncActionAccelerators(self: *Self) void {
        self.syncActionAccelerator("app.quit", .{ .quit = {} });
        self.syncActionAccelerator("app.open-config::os-open", .{ .open_config = .os_open });
        self.syncActionAccelerator("app.open-config::new-window", .{ .open_config = .new_window });
        self.syncActionAccelerator("app.reload-config", .{ .reload_config = {} });
        self.syncActionAccelerator("win.toggle-inspector", .{ .inspector = .toggle });
        self.syncActionAccelerator("app.show-gtk-inspector", .show_gtk_inspector);
        self.syncActionAccelerator("win.toggle-command-palette", .toggle_command_palette);
        self.syncActionAccelerator("win.close", .{ .close_window = {} });
        self.syncActionAccelerator("win.new-window", .{ .new_window = {} });
        self.syncActionAccelerator("win.new-tab", .{ .new_tab = {} });
        self.syncActionAccelerator("win.close-tab::this", .{ .close_tab = .this });
        self.syncActionAccelerator("tab.close::this", .{ .close_tab = .this });
        self.syncActionAccelerator("win.split-right", .{ .new_split = .right });
        self.syncActionAccelerator("win.split-down", .{ .new_split = .down });
        self.syncActionAccelerator("win.split-left", .{ .new_split = .left });
        self.syncActionAccelerator("win.split-up", .{ .new_split = .up });
        self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = .mixed });
        self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
        self.syncActionAccelerator("win.reset", .{ .reset = {} });
        self.syncActionAccelerator("win.clear", .{ .clear_screen = {} });
        self.syncActionAccelerator("win.prompt-title", .{ .prompt_surface_title = {} });
        self.syncActionAccelerator("split-tree.new-split::left", .{ .new_split = .left });
        self.syncActionAccelerator("split-tree.new-split::right", .{ .new_split = .right });
        self.syncActionAccelerator("split-tree.new-split::up", .{ .new_split = .up });
        self.syncActionAccelerator("split-tree.new-split::down", .{ .new_split = .down });
    }

    fn syncActionAccelerator(
        self: *Self,
        gtk_action: [:0]const u8,
        action: input.Binding.Action,
    ) void {
        const gtk_app = self.as(gtk.Application);

        // Reset it initially
        const zero = [_:null]?[*:0]const u8{};
        gtk_app.setAccelsForAction(gtk_action, &zero);

        const config = self.private().config.get();
        const trigger = config.keybind.set.getTrigger(action) orelse return;
        var buf: [1024]u8 = undefined;
        const accel = if (key.accelFromTrigger(
            &buf,
            trigger,
        )) |accel_|
            accel_ orelse return
        else |err| switch (err) {
            // This should really never, never happen. Its not critical enough
            // to actually crash, but this is a bug somewhere. An accelerator
            // for a trigger can't possibly be more than 1024 bytes.
            error.WriteFailed => {
                log.warn("accelerator somehow longer than 1024 bytes: {f}", .{trigger});
                return;
            },
        };
        const accels = [_:null]?[*:0]const u8{accel};

        gtk_app.setAccelsForAction(gtk_action, &accels);
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns the configuration for this application.
    ///
    /// The reference count is increased.
    pub fn getConfig(self: *Self) *Config {
        return self.private().config.ref();
    }

    /// Set the configuration for this application. The reference count
    /// is increased on the new configuration and the old one is
    /// unreferenced.
    ///
    /// If the config has errors this may show the config errors dialog.
    pub fn setConfig(self: *Self, config: *Config) void {
        const priv = self.private();
        priv.config.unref();
        priv.config = config.ref();
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Show our errors if we have any
        self.showConfigErrorsDialog();
    }

    fn propConfig(
        _: *Application,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Sync our accelerators for menu items.
        self.syncActionAccelerators();

        // Sync our light/dark mode with the (possibly changed)
        // window-theme configuration.
        self.syncStyleManager();

        // Load our runtime and custom CSS. If this fails then our window is
        // just stuck with the old CSS but we don't want to fail the entire
        // config change operation.
        self.loadRuntimeCss() catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => log.warn(
                "out of memory loading runtime CSS, no runtime CSS applied",
                .{},
            ),
        };
        self.loadCustomCss() catch |err| {
            log.warn(
                "failed to load custom CSS, no custom CSS applied, err={}",
                .{err},
            );
        };
    }

    /// Log CSS parsing error
    fn signalCssParsingError(
        _: *gtk.CssProvider,
        css_section: *gtk.CssSection,
        err: *glib.Error,
        _: *Self,
    ) callconv(.c) void {
        const location = css_section.toString();
        defer glib.free(location);
        if (comptime gtk_version.atLeast(4, 16, 0)) bytes: {
            const bytes = css_section.getBytes() orelse break :bytes;
            var len: usize = undefined;
            const ptr = bytes.getData(&len) orelse break :bytes;
            const data = ptr[0..len];
            log.warn("css parsing failed at {s}: {s} {d} {s}\n{s}", .{
                location,
                glib.quarkToString(err.f_domain),
                err.f_code,
                err.f_message orelse "«unknown»",
                data,
            });
            return;
        }
        log.warn("css parsing failed at {s}: {s} {d} {s}", .{
            location,
            glib.quarkToString(err.f_domain),
            err.f_code,
            err.f_message orelse "«unknown»",
        });
    }

    //---------------------------------------------------------------
    // Libghostty Callbacks

    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn startup(self: *Self) callconv(.c) void {
        log.debug("startup", .{});

        gio.Application.virtual_methods.startup.call(
            Class.parent,
            self.as(Parent),
        );

        // Set ourselves as the default application.
        gio.Application.setDefault(self.as(gio.Application));

        // The D-Bus connection is only valid after GApplication startup.
        self.openUri().setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );

        // Setup our event loop
        self.startupXev();

        // Setup some signal handlers. This must happen before anything
        // that might notify systemd, since with Type=notify-reload systemd
        // refuses to start us if our reload signal has no handler.
        self.startupSignals();

        // Setup our style manager (light/dark mode)
        self.startupStyleManager();

        // Setup our action map
        self.startupActionMap();

        // Setup our global shortcuts
        self.startupGlobalShortcuts();

        // If we have any config diagnostics from loading, then we
        // show the diagnostics dialog. We show this one as a general
        // modal (not to any specific window) because we don't even
        // know if the window will load.
        self.showConfigErrorsDialog();

        // Spawn ptyxis-agent and cache the container model. Failure is
        // non-fatal — Host-only tabs still work without it.
        self.startupContainerClient();

        // Optional: auto-open Preferences window for smoke testing and
        // screenshot walkthroughs (gated on env var, off by default).
        // A value naming a page ("appearance", "behavior", "shortcuts",
        // "profiles") opens that page; any other value opens the default.
        if (global.environ().getPosix("GHOSTTY_PTYXIS_TEST_PREFS")) |page| {
            const window = PreferencesWindow.new();
            for ([_][:0]const u8{ "appearance", "behavior", "shortcuts", "profiles" }) |known| {
                if (std.mem.eql(u8, page, known)) {
                    window.as(adw.PreferencesWindow).setVisiblePageName(known.ptr);
                    break;
                }
            }
            window.as(gtk.Window).present();
        }

        // Optional: smoke test the config-file mutator.
        if (global.environ().getPosix("GHOSTTY_PTYXIS_TEST_CONFIG_WRITE")) |val| {
            const cb = @import("config_bridge.zig");
            cb.setKey(std.heap.c_allocator, "background-opacity", val, null) catch |err| {
                log.warn("config_bridge.setKey test failed: {s}", .{@errorName(err)});
            };
        }

        // Optional: smoke test the palette applier.
        if (global.environ().getPosix("GHOSTTY_PTYXIS_TEST_PALETTE")) |id| {
            PreferencesWindow.applyPalette(id) catch |err| {
                log.warn("applyPalette test failed: {s}", .{@errorName(err)});
            };
        }

        // Optional: smoke test CreatePty via the agent.
        if (global.environ().getPosix("GHOSTTY_PTYXIS_TEST_CREATEPTY")) |_| {
            const priv2 = self.private();
            if (priv2.container_client) |*c| {
                const fd = c.createPty() catch |err| blk: {
                    log.warn("CreatePty smoke failed: {s}", .{@errorName(err)});
                    break :blk -1;
                };
                if (fd >= 0) {
                    log.info("CreatePty smoke ok: master fd={d}", .{fd});
                    compat_fd.close(fd);
                }
            }
        }

        // Optional: smoke test the full spawn-in-container path.
        // Set GHOSTTY_PTYXIS_TEST_SPAWN to a container id (e.g. "session"
        // or a podman name) to drive: CreatePty → Container.Spawn → echo
        // a sentinel into the slave to prove it's live.
        if (global.environ().getPosix("GHOSTTY_PTYXIS_TEST_SPAWN")) |id| {
            self.smokeSpawnFlow(id) catch |err| {
                log.warn("spawn smoke failed: {s}", .{@errorName(err)});
            };
        }
    }

    fn smokeSpawnFlow(self: *Self, id: []const u8) !void {
        const priv = self.private();
        const store = priv.container_model orelse return error.NoModel;
        const c_ptr = if (priv.container_client) |*c| c else return error.NoClient;

        // Find container_path by id.
        const lm = store.as(gio.ListModel);
        const n = lm.getNItems();
        var i: c_uint = 0;
        const container_path: [:0]const u8 = blk: while (i < n) : (i += 1) {
            const raw = lm.getItem(i) orelse continue;
            const obj: *gobject.Object = @ptrCast(@alignCast(raw));
            defer gobject.Object.unref(obj);
            const c = gobject.ext.cast(PtyxisContainer, obj) orelse continue;
            const cid = c.getId() orelse continue;
            if (std.mem.eql(u8, cid, id)) break :blk (c.objectPath() orelse continue);
        } else return error.ContainerNotFound;

        const master = try c_ptr.createPty();
        defer compat_fd.close(master);

        // Open slave.
        const Libc = struct {
            extern "c" fn grantpt(fd: c_int) c_int;
            extern "c" fn unlockpt(fd: c_int) c_int;
            extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
            extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
        };
        _ = Libc.grantpt(master);
        _ = Libc.unlockpt(master);
        const slave_name = Libc.ptsname(master) orelse return error.PtsName;
        const slave_fd = Libc.open(slave_name, 2 | 0o400);
        if (slave_fd < 0) return error.OpenSlave;
        defer compat_fd.close(slave_fd);

        log.info("smoke spawn: container={s} master={d} slave_name={s}", .{
            container_path, master, slave_name,
        });

        const argv = [_][]const u8{ "/bin/sh", "-c", "echo PTYXIS_SMOKE_OK > /dev/tty; sleep 0.3" };
        const cwd = "/";
        const env = [_][2][]const u8{
            .{ "TERM", "xterm-256color" },
            .{ "PATH", "/usr/bin:/bin" },
        };

        const proc = try c_ptr.spawnInContainer(container_path, cwd, &argv, slave_fd, &env);
        defer std.heap.c_allocator.free(proc);
        log.info("smoke spawn: proc={s}", .{proc});

        // Read sentinel back from master. The shell may not have flushed
        // by the time we get here; retry briefly.
        var buf: [256]u8 = undefined;
        const ReadLibc = struct {
            extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
        };
        var tries: u8 = 0;
        while (tries < 20) : (tries += 1) {
            const n_read = ReadLibc.read(master, &buf, buf.len);
            if (n_read > 0) {
                log.info("smoke spawn read {d} bytes: {s}", .{ n_read, buf[0..@intCast(n_read)] });
                return;
            }
            std.Io.sleep(global.io(), .fromMilliseconds(50), .awake) catch {};
        }
        log.warn("smoke spawn: no output within timeout", .{});
    }

    fn startupContainerClient(self: *Self) void {
        const priv = self.private();
        const alloc = std.heap.c_allocator;

        const agent_path = resolveAgentPath(alloc) catch |err| {
            log.warn("agent path resolution failed: {s}", .{@errorName(err)});
            return;
        };
        defer alloc.free(agent_path);

        var client = ContainerClient.spawn(alloc, agent_path) catch |err| {
            log.warn("ptyxis-agent spawn failed: {s} (path={s})", .{
                @errorName(err), agent_path,
            });
            return;
        };
        errdefer client.deinit();

        const store = client.listAsModel() catch |err| {
            log.warn("ListContainers failed: {s}", .{@errorName(err)});
            return;
        };

        priv.container_client = client;
        priv.container_model = store;

        const n = store.as(gio.ListModel).getNItems();
        log.info("ptyxis-agent ready: {d} containers cached", .{n});
    }

    /// Find a working ptyxis-agent binary. Honours $PTYXIS_AGENT_PATH first,
    /// then tries paths relative to the running binary (dev + installed),
    /// then well-known system install locations.
    fn resolveAgentPath(alloc: std.mem.Allocator) ![:0]u8 {
        if (global.environ().getPosix("PTYXIS_AGENT_PATH")) |p| {
            return try alloc.dupeZ(u8, p);
        }

        // Try paths relative to the running executable.
        if (std.process.executablePathAlloc(global.io(), alloc)) |self_exe| {
            defer alloc.free(self_exe);
            if (std.fs.path.dirname(self_exe)) |bin_dir| {
                // ${prefix}/libexec/ptyxis-agent (installed layout)
                if (std.fs.path.dirname(bin_dir)) |prefix| {
                    const installed = try std.fs.path.joinZ(
                        alloc,
                        &.{ prefix, "libexec", "ptyxis-agent" },
                    );
                    errdefer alloc.free(installed);
                    if (std.Io.Dir.accessAbsolute(global.io(), installed, .{})) {
                        return installed;
                    } else |_| alloc.free(installed);
                }

                // Dev tree: <repo>/third_party/ptyxis-agent/build/ptyxis-agent
                // Reachable from zig-out/bin via ../../third_party/...
                if (std.fs.path.dirname(bin_dir)) |zig_out| {
                    if (std.fs.path.dirname(zig_out)) |repo| {
                        const dev_path = try std.fs.path.joinZ(
                            alloc,
                            &.{ repo, "third_party", "ptyxis-agent", "build", "ptyxis-agent" },
                        );
                        errdefer alloc.free(dev_path);
                        if (std.Io.Dir.accessAbsolute(global.io(), dev_path, .{})) {
                            return dev_path;
                        } else |_| alloc.free(dev_path);
                    }
                }
            }
        } else |_| {}

        const candidates = [_][]const u8{
            "/app/libexec/ptyxis-agent",
            "/usr/local/libexec/ptyxis-agent",
            "/usr/libexec/ptyxis-agent",
        };
        for (candidates) |c| {
            std.Io.Dir.accessAbsolute(global.io(), c, .{}) catch continue;
            return try alloc.dupeZ(u8, c);
        }
        return error.AgentNotFound;
    }

    /// Get the ListModel of containers known to the agent, or null if the
    /// agent could not be reached. Caller does NOT own a ref.
    pub fn containerModel(self: *Self) ?*gio.ListStore {
        return self.private().container_model;
    }

    /// Get the live ContainerClient, or null if the agent never spawned.
    pub fn containerClient(self: *Self) ?*ContainerClient {
        const priv = self.private();
        return if (priv.container_client) |*c| c else null;
    }

    /// Stash a master_fd that the next Surface to initialize will adopt.
    /// Used by the container-spawn path: the agent already created the
    /// shell process, so the new Surface skips its own fork.
    pub fn setPendingExternalMasterFd(self: *Self, fd: c_int) void {
        self.private().pending_external_master_fd = fd;
    }

    /// Atomically read and clear the pending external master fd. Returns
    /// null if no container spawn is in flight.
    pub fn takePendingExternalMasterFd(self: *Self) ?c_int {
        const priv = self.private();
        const fd = priv.pending_external_master_fd;
        priv.pending_external_master_fd = null;
        return fd;
    }

    /// Stash title + icon-name for the next tab created during the
    /// container-spawn flow. Strings are dup'd with c_allocator. Either
    /// argument may be empty to clear.
    pub fn setPendingContainerTabMetadata(
        self: *Self,
        title: []const u8,
        icon: []const u8,
    ) void {
        const priv = self.private();
        if (priv.pending_container_title) |s| std.heap.c_allocator.free(s);
        if (priv.pending_container_icon) |s| std.heap.c_allocator.free(s);
        priv.pending_container_title = null;
        priv.pending_container_icon = null;
        if (title.len > 0) {
            priv.pending_container_title = std.heap.c_allocator.dupeZ(u8, title) catch null;
        }
        if (icon.len > 0) {
            priv.pending_container_icon = std.heap.c_allocator.dupeZ(u8, icon) catch null;
        }
    }

    pub fn takePendingContainerTabTitle(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        const t = priv.pending_container_title;
        priv.pending_container_title = null;
        return t;
    }

    pub fn takePendingContainerTabIcon(self: *Self) ?[:0]const u8 {
        const priv = self.private();
        const i = priv.pending_container_icon;
        priv.pending_container_icon = null;
        return i;
    }

    /// Trigger a config reload from any caller, debounced 300ms. The
    /// preferences UI uses this so slider/switch/font changes visibly
    /// apply without the user having to restart or hit "Reload Config".
    /// Repeated calls within the debounce window collapse to one reload.
    pub fn triggerReload(self: *Self) void {
        self.triggerReloadOpts(.{});
    }

    /// `quiet` suppresses the config-reload toast for this reload; use it
    /// for reloads the user didn't explicitly request.
    pub fn triggerReloadOpts(self: *Self, opts: struct { quiet: bool = false }) void {
        const priv = self.private();
        if (opts.quiet) priv.pending_quiet_reload = true;
        if (priv.pending_reload_timer != 0) {
            _ = glib.Source.remove(priv.pending_reload_timer);
            priv.pending_reload_timer = 0;
        }
        priv.pending_reload_timer = glib.timeoutAdd(300, &reloadFire, self);
    }

    /// Whether the config reload being applied right now was internal.
    /// Windows use this to decide whether to show the reload toast; it is
    /// a peek, not a take, because every window has to see the same answer.
    pub fn isQuietReload(self: *Self) bool {
        return self.private().quiet_reload;
    }

    fn reloadFire(data: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(data.?));
        const priv = self.private();
        priv.pending_reload_timer = 0;
        priv.core_app.performAction(self.rt(), .reload_config) catch |err| {
            log.warn("debounced reload err={}", .{err});
        };
        return 0; // G_SOURCE_REMOVE
    }

    /// Configure libxev to use a specific backend.
    ///
    /// This must be called before any other xev APIs are used.
    fn startupXev(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // If our backend is auto then we have no setup to do.
        if (config.@"async-backend" == .auto) return;

        // Setup our event loop backend to the preferred method
        const result: bool = switch (config.@"async-backend") {
            .auto => unreachable,
            .epoll => if (comptime xev.dynamic) xev.prefer(.epoll) else false,
            .io_uring => if (comptime xev.dynamic) xev.prefer(.io_uring) else false,
        };

        if (result) {
            log.info(
                "libxev manual backend={s}",
                .{@tagName(xev.backend)},
            );
        } else {
            log.warn(
                "libxev manual backend failed, using default={s}",
                .{@tagName(xev.backend)},
            );
        }
    }

    /// Setup the style manager on startup. The primary task here is to
    /// setup our initial light/dark mode based on the configuration and
    /// setup listeners for changes to the style manager.
    fn startupStyleManager(self: *Self) void {
        // Setup our initial light/dark
        const style = self.as(adw.Application).getStyleManager();
        self.syncStyleManager();

        // Setup color change notifications
        _ = gobject.Object.signals.notify.connect(
            style,
            *Self,
            handleStyleManagerDark,
            self,
            .{ .detail = "dark" },
        );

        // Do an initial color scheme sync. This is idempotent and does nothing
        // if our current theme matches what libghostty has so its safe to
        // call.
        handleStyleManagerDark(style, undefined, self);
    }

    /// The color scheme (light or dark) the application is currently
    /// rendering with, as reported by the libadwaita style manager.
    pub fn colorScheme(self: *Self) apprt.ColorScheme {
        const style = self.as(adw.Application).getStyleManager();
        return if (style.getDark() == 0) .light else .dark;
    }

    /// Apply `window-theme` to the libadwaita style manager. This is called
    /// on startup and again whenever the configuration changes so that the
    /// light/dark selector (and `window-theme` in general) applies without
    /// requiring a restart.
    fn syncStyleManager(self: *Self) void {
        const config = self.private().config.get();
        self.applyWindowTheme(config.@"window-theme", config.background);
    }

    /// Apply a `window-theme` value to the libadwaita style manager.
    ///
    /// The style picker calls this directly on click so the new style takes
    /// effect immediately, rather than a few hundred milliseconds later when
    /// the debounced config reload lands.
    pub fn applyWindowTheme(
        self: *Self,
        theme: CoreConfig.WindowTheme,
        background: CoreConfig.Color,
    ) void {
        const style = self.as(adw.Application).getStyleManager();
        style.setColorScheme(switch (theme) {
            .auto, .ghostty => auto: {
                const lum = background.toTerminalRGB().perceivedLuminance();
                break :auto if (lum > 0.5)
                    .prefer_light
                else
                    .prefer_dark;
            },
            .system => .prefer_light,
            .dark => .force_dark,
            .light => .force_light,
        });
    }

    /// Setup signal handlers
    fn startupSignals(self: *Self) void {
        const priv = self.private();
        assert(priv.signal_source == null);
        priv.signal_source = glibunix.signalAdd(
            @intFromEnum(std.posix.SIG.USR2),
            handleSigusr2,
            self,
        );
    }

    /// Setup our action map.
    fn startupActionMap(self: *Self) void {
        const t_variant_type = glib.ext.VariantType.newFor(u64);
        defer t_variant_type.free();

        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();

        const tas_variant_type = glib.VariantType.new("(tas)");
        defer tas_variant_type.free();

        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();

        const action_map = [_]ext.actions.Action(Self){
            .init("new-window", actionNewWindow, null),
            .init("new-window-command", actionNewWindow, as_variant_type),
            .init("new-tab", actionNewTab, tas_variant_type),
            .init("open-config", actionOpenConfig, s_variant_type),
            .init("preferences", actionPreferences, null),
            .init("present-surface", actionPresentSurface, t_variant_type),
            .init("quit", actionQuit, null),
            .init("reload-config", actionReloadConfig, null),
            .init("toggle-quick-terminal", actionToggleQuickTerminal, null),
            .init("ring-bell", actionRingBell, null),
        };

        ext.actions.add(Self, self, &action_map);
    }

    /// Setup our global shortcuts.
    fn startupGlobalShortcuts(self: *Self) void {
        const priv = self.private();

        // On startup, our dbus connection should be available.
        priv.global_shortcuts.setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );

        // Setup a binding so that the shortcut config always matches the app.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            priv.global_shortcuts.as(gobject.Object),
            "config",
            .{ .sync_create = true },
        );

        // Setup the signal handler for global shortcut triggers
        _ = GlobalShortcuts.signals.trigger.connect(
            priv.global_shortcuts,
            *Application,
            globalShortcutTrigger,
            self,
            .{},
        );

        _ = GlobalShortcuts.signals.@"bind-failed".connect(
            priv.global_shortcuts,
            *Application,
            globalShortcutBindFailed,
            self,
            .{},
        );
    }

    fn activate(self: *Self) callconv(.c) void {
        log.debug("activate", .{});

        // Queue a new window
        const priv = self.private();
        _ = priv.core_app.mailbox.push(global.io(), .{
            .new_window = .{},
        }, .{ .forever = {} });

        // Call the parent activate method.
        gio.Application.virtual_methods.activate.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config_errors_dialog.get()) |diag| {
            diag.close();
            diag.unref(); // strong ref from get()
        }
        priv.config_errors_dialog.deinit();
        if (priv.signal_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove signal source", .{});
            }
            priv.signal_source = null;
        }

        if (priv.bell_media) |v| {
            v.unref();
            priv.bell_media = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        self.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    /// SIGUSR2 signal handler via g_unix_signal_add
    fn handleSigusr2(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_CONTINUE)));

        log.info("received SIGUSR2, reloading configuration", .{});
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };

        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn handleCloseConfirmation(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.quitNow();
    }

    fn handleQuitTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        priv.quit_timer = .expired;
        return 0;
    }

    fn handleStyleManagerDark(
        style: *adw.StyleManager,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const scheme: apprt.ColorScheme = if (style.getDark() == 0)
            .light
        else
            .dark;
        log.debug("style manager changed scheme={}", .{scheme});

        const priv: *Private = self.private();
        const core_app = priv.core_app;
        core_app.colorSchemeEvent(self.rt(), scheme) catch |err| {
            log.warn("error updating app color scheme err={}", .{err});
        };
        for (core_app.surfaces.items) |surface| {
            surface.core().colorSchemeCallback(scheme) catch |err| {
                log.warn(
                    "unable to tell surface about color scheme change err={}",
                    .{err},
                );
            };
        }

        if (gtk_version.atLeast(4, 20, 0)) {
            const gtk_scheme: gtk.InterfaceColorScheme = switch (scheme) {
                .light => gtk.InterfaceColorScheme.light,
                .dark => gtk.InterfaceColorScheme.dark,
            };
            var value = gobject.ext.Value.newFrom(gtk_scheme);
            gobject.Object.setProperty(
                priv.css_provider.as(gobject.Object),
                "prefers-color-scheme",
                &value,
            );
            for (priv.custom_css_providers.items) |css_provider| {
                gobject.Object.setProperty(
                    css_provider.as(gobject.Object),
                    "prefers-color-scheme",
                    &value,
                );
            }
        }
    }

    fn handleReloadConfig(
        _: *ConfigErrorsDialog,
        self: *Self,
    ) callconv(.c) void {
        // We clear our dialog reference because its going to close
        // after response handling and we don't want to reuse it.
        const priv = self.private();
        priv.config_errors_dialog.set(null);

        // Reload our config as if the app reloaded.
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };
    }

    /// Show the config errors dialog if the config on our application
    /// has diagnostics.
    fn showConfigErrorsDialog(self: *Self) void {
        const priv = self.private();

        // If we already have a dialog, just update the config.
        if (priv.config_errors_dialog.get()) |diag| {
            defer diag.unref(); // get gets a strong ref

            var value = gobject.ext.Value.newFrom(priv.config);
            defer value.unset();
            gobject.Object.setProperty(
                diag.as(gobject.Object),
                "config",
                &value,
            );

            if (!priv.config.hasDiagnostics()) {
                diag.close();
            } else {
                diag.present(null);
            }

            return;
        }

        // No diagnostics, do nothing.
        if (!priv.config.hasDiagnostics()) return;

        // No dialog yet, initialize a new one. There's no need to unref
        // here because the widget that it becomes a part of takes ownership.
        const dialog: *ConfigErrorsDialog = .new(priv.config);
        priv.config_errors_dialog.set(dialog);

        // Connect to the reload signal so we know to reload our config.
        _ = ConfigErrorsDialog.signals.@"reload-config".connect(
            dialog,
            *Application,
            handleReloadConfig,
            self,
            .{},
        );

        // Show it
        dialog.present(null);
    }

    fn globalShortcutTrigger(
        _: *GlobalShortcuts,
        action: *const Binding.Action,
        self: *Self,
    ) callconv(.c) void {
        self.core().performAllAction(self.rt(), action.*) catch |err| {
            log.warn("failed to perform action={}", .{err});
        };
    }

    /// May fire before any window exists, hence a desktop notification
    /// rather than a toast.
    fn globalShortcutBindFailed(
        _: *GlobalShortcuts,
        failure: *const GlobalShortcuts.BindFailed,
        self: *Self,
    ) callconv(.c) void {
        var label_buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&label_buf);
        const label: []const u8 = label: {
            const ok = key.labelFromTrigger(&writer, failure.trigger) catch false;
            break :label if (ok) writer.buffered() else "?";
        };

        const detail: [*:0]const u8 = detail: {
            if (failure.message[0] != 0) break :detail failure.message;
            break :detail if (failure.revoked)
                i18n._("The keybind was revoked by the system.")
            else
                i18n._("The keybind was denied by the system.");
        };

        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrintZ(
            &body_buf,
            "{s}: {s}",
            .{ label, detail },
        ) catch return;

        Action.desktopNotification(self, .app, .{
            .title = std.mem.span(i18n._("Global keybind unavailable")),
            .body = body,
        });
    }

    fn actionReloadConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .reload_config) catch |err| {
            log.warn("error reloading config err={}", .{err});
        };
    }

    fn actionToggleQuickTerminal(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .toggle_quick_terminal) catch |err| {
            log.warn("error toggling quick terminal err={}", .{err});
        };
    }

    fn actionQuit(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .quit) catch |err| {
            log.warn("error quitting err={}", .{err});
        };
    }

    /// Handle `app.new-window` and `app.new-window-command` GTK actions
    pub fn actionNewWindow(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new window action", .{});

        var arena: std.heap.ArenaAllocator = .init(self.core().alloc);
        defer arena.deinit();

        const alloc = arena.allocator();

        const overrides = overrides: {
            // were we given a parameter?
            const arguments = parameter_ orelse break :overrides null;

            const as_variant_type = glib.VariantType.new("as");
            defer as_variant_type.free();

            // ensure that the supplied parameter is an array of strings
            if (glib.Variant.isOfType(arguments, as_variant_type) == 0) {
                log.warn("parameter is of type '{s}', not '{s}'", .{
                    arguments.getTypeString(),
                    as_variant_type.peekString()[0..as_variant_type.getStringLength()],
                });
                break :overrides null;
            }

            var arguments_it: glib.VariantIter = undefined;
            _ = arguments_it.init(arguments);

            break :overrides Overrides.parse(alloc, &arguments_it) catch null;
        };

        Action.newWindow(
            self,
            null,
            if (overrides) |o| .{
                .command = o.command,
                .shell_integration = o.shell_integration,
                .working_directory = o.working_directory,
                .title = o.title,
            } else .none,
        ) catch |err| {
            log.warn("unable to create new window: {t}", .{err});
        };
    }

    /// Handle `app.new-tab` GTK action
    pub fn actionNewTab(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new tab action", .{});

        const core_app = self.core();

        var arena: std.heap.ArenaAllocator = .init(core_app.alloc);
        defer arena.deinit();

        const alloc = arena.allocator();

        const surface_id_, const overrides = result: {
            // were we given a parameter?
            const parameter = parameter_ orelse {
                log.warn("app.new-tab did not receive a parameter", .{});
                return;
            };

            log.warn("got parameter: {s}", .{parameter.getTypeString()});

            const tas_variant_type = glib.VariantType.new("(tas)");
            defer tas_variant_type.free();

            // ensure that the supplied parameter is an array of strings
            if (glib.Variant.isOfType(parameter, tas_variant_type) == 0) {
                log.warn("parameter is of type '{s}', not '{s}'", .{
                    parameter.getTypeString(),
                    tas_variant_type.peekString()[0..tas_variant_type.getStringLength()],
                });
                return;
            }

            var surface_id: u64 = 0;
            var arguments_it_: ?*glib.VariantIter = null;
            defer if (arguments_it_) |arguments_it| arguments_it.free();

            parameter.get("(tas)", &surface_id, &arguments_it_);

            const arguments_it = arguments_it_ orelse return;

            const overrides = Overrides.parse(alloc, arguments_it) catch return;

            break :result .{ if (surface_id == 0) null else surface_id, overrides };
        };

        const surface_ = surface: {
            if (surface_id_) |surface_id| find_by_id: {
                break :surface core_app.findSurfaceByID(surface_id) orelse {
                    log.warn("new-tab: unable to find surface 0x{x:0>16}", .{surface_id});
                    break :find_by_id;
                };
            }
            find_focused: {
                break :surface core_app.focusedSurface() orelse {
                    log.warn("new-tab: unable to find surface", .{});
                    break :find_focused;
                };
            }
            break :surface null;
        };

        if (surface_) |surface| {
            if (!Action.newTab(
                .{
                    .surface = surface,
                },
                .{
                    .command = overrides.command,
                    .shell_integration = overrides.shell_integration,
                    .working_directory = overrides.working_directory,
                    .title = overrides.title,
                },
            )) {
                log.warn("new-tab: unable to create tab", .{});
            }
        } else {
            Action.newWindow(
                self,
                null,
                .{
                    .command = overrides.command,
                    .shell_integration = overrides.shell_integration,
                    .working_directory = overrides.working_directory,
                    .title = overrides.title,
                },
            ) catch |err| {
                log.warn("new-tab: unable to create new window: {t}", .{err});
            };
        }
    }

    pub fn actionOpenConfig(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const target: CoreApp.Message.OpenConfig = target: {
            const target_map: std.StaticStringMap(CoreApp.Message.OpenConfig) = .initComptime(&.{
                .{ "os-open", .os_open },
                .{ "new-window", .new_window },
            });

            const parameter = parameter_ orelse {
                log.warn("no parameter provided to app.open-config action", .{});
                break :target .os_open;
            };

            const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
            defer s_variant_type.free();

            if (parameter.isOfType(s_variant_type) == 0) {
                log.warn("parameter to app.open-config action is of type '{s}' not '{s}'", .{
                    parameter.getTypeString(),
                    s_variant_type.peekString()[0..s_variant_type.getStringLength()],
                });
                break :target .os_open;
            }

            var len: usize = undefined;
            const buf = parameter.getString(&len);
            const str = buf[0..len];

            break :target target_map.get(str) orelse {
                log.warn("'{s}' is not configured as a target for the app.open-config action", .{str});
                break :target .os_open;
            };
        };

        _ = self.core().mailbox.push(global.io(), .{ .open_config = target }, .forever);
    }

    pub fn actionPreferences(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        _: *Self,
    ) callconv(.c) void {
        const window = PreferencesWindow.new();
        window.as(gtk.Window).present();
    }

    fn actionPresentSurface(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const parameter = parameter_ orelse return;

        const t = glib.ext.VariantType.newFor(u64);
        defer glib.VariantType.free(t);

        // Make sure that we've received a u64 from the system.
        if (glib.Variant.isOfType(parameter, t) == 0) {
            return;
        }

        // Convert the u64 to a core surface by using it as a surface ID.
        // A value of zero means that there was no target surface for the
        // notification so we don't focus any surface.
        const surface_id = parameter.getUint64();
        if (surface_id == 0) return;
        const surface = self.core().findSurfaceByID(surface_id) orelse return;

        _ = self.core().mailbox.push(
            global.io(),
            .{
                .surface_message = .{
                    .surface = surface,
                    .message = .present_surface,
                },
            },
            .forever,
        );
    }

    pub fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv: *Private = self.private();
        const config = priv.config.get();

        // Do our sound
        if (config.@"bell-features".audio) audio: {
            const config_path = config.@"bell-audio-path" orelse break :audio;
            const path, const required = switch (config_path) {
                .optional => |path| .{ path, false },
                .required => |path| .{ path, true },
            };

            const volume = std.math.clamp(
                config.@"bell-audio-volume",
                0.0,
                1.0,
            );

            // Reuse one MediaFile per application (rebuilt only when the path
            // changes) so each bell replays the same pipeline instead of
            // leaking a fresh one. Assign unconditionally: bellMediaFile frees
            // any stale MediaFile and returns the current slot value (possibly
            // null if the path is now inaccessible), so priv.bell_media never
            // dangles.
            priv.bell_media = media.bellMediaFile(priv.bell_media, path, required);
            const media_file = priv.bell_media orelse break :audio;
            media.playBell(media_file, volume);
        }
    }

    //----------------------------------------------------------------
    // Boilerplate/Noise

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
            // Register our compiled resources exactly once.
            {
                const ghostty_gtk_resources = @import("ghostty_gtk_resources");
                if (ghostty_gtk_resources.ghostty_get_resource()) |ptr| {
                    gio.resourcesRegister(@ptrCast(@alignCast(ptr)));
                } else {
                    // If we fail to load resources then things will
                    // probably look really bad but it shouldn't stop our
                    // app from loading.
                    log.warn("unable to load resources", .{});
                }
            }

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Virtual methods
            gio.Application.virtual_methods.activate.implement(class, &activate);
            gio.Application.virtual_methods.startup.implement(class, &startup);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };

    pub fn openUrlFallback(self: *Application, kind: apprt.action.OpenUrl.Kind, url: []const u8) void {
        _ = self;
        // Fallback to the minimal cross-platform way of opening a URL.
        // This is always a safe fallback and enables for example Windows
        // to open URLs (GTK on Windows via WSL is a thing).
        internal_os.open(
            kind,
            url,
        ) catch |err| log.warn("unable to open url: {}", .{err});
    }
};


/// This sets various GTK-related environment variables as necessary
/// given the runtime environment or configuration.
///
/// This must be called BEFORE GTK initialization.
fn setGtkEnv(config: *const CoreConfig) std.Io.Writer.Error!void {
    assert(gtk.isInitialized() == 0);

    const gdk_debug: struct {
        /// Output OpenGL debug information,
        /// `gtk-opengl-debug` dumps logs directly to stderr so both must be true
        /// to enable OpenGL debugging.
        opengl: bool = false,
    } = .{
        .opengl = global.logging().stderr and config.@"gtk-opengl-debug",
    };

    const gdk_disable: struct {
        // Even though we don't use GTK's GL context anymore, there can still
        // occasionally be conflicts when Vulkan and OpenGL are used together.
        // Disabling Vulkan also saves hundreds of milliseconds of initialization
        // time on certain systems.
        vulkan: bool = true,
    } = .{};

    {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_debug)).@"struct".fields) |field| {
            if (@field(gdk_debug, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = writer.buffered();
        log.warn("setting GDK_DEBUG={s}", .{value[0 .. value.len - 1]});
        _ = setenv("GDK_DEBUG", @ptrCast(value[0 .. value.len - 1 :0]), 1);
    }

    {
        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_disable)).@"struct".fields) |field| {
            if (@field(gdk_disable, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = writer.buffered();
        log.warn("setting GDK_DISABLE={s}", .{value[0 .. value.len - 1]});
        _ = setenv("GDK_DISABLE", @ptrCast(value[0 .. value.len - 1 :0]), 1);
    }

    // Sync environ after altering system env
    global.syncEnviron();
}
