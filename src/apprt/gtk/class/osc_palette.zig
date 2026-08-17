//! Per-surface palette overrides via OSC escape sequences (issue #9).
//!
//! Ghostty's config palette is global; these helpers instead build the
//! runtime color-control sequences (OSC 4 indexed colors, 10 foreground,
//! 11 background, 12 cursor, and their 104/110/111/112 reset variants)
//! and inject them into ONE surface's terminal stream via the
//! `inject_output` termio message. The bytes go through the terminal
//! parser exactly as if a program inside the tab had printed them — the
//! child process never sees them, no config file changes, and the
//! override is naturally session-scoped.
//!
//! Known limitation (v1): a config reload repaints from the global
//! config, clobbering the override until the user re-applies it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const palette_mod = @import("palette.zig");
const CoreSurface = @import("../../../Surface.zig");

const log = std.log.scoped(.gtk_ptyxis_osc_palette);

/// OSC resets: indexed palette (104), foreground (110), background
/// (111), cursor (112). BEL-terminated; Ghostty accepts BEL and ST.
pub const reset_sequences = "\x1b]104\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07";

/// Build the OSC byte stream that applies `variant` to a terminal.
/// Caller owns the returned slice.
pub fn buildApplySequences(alloc: Allocator, variant: *const palette_mod.Variant) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);

    if (variant.background) |c|
        try w.print("\x1b]11;#{x:0>2}{x:0>2}{x:0>2}\x07", .{ c.r, c.g, c.b });
    if (variant.foreground) |c|
        try w.print("\x1b]10;#{x:0>2}{x:0>2}{x:0>2}\x07", .{ c.r, c.g, c.b });
    if (variant.cursor) |c|
        try w.print("\x1b]12;#{x:0>2}{x:0>2}{x:0>2}\x07", .{ c.r, c.g, c.b });
    for (variant.colors, 0..) |maybe, i| {
        const c = maybe orelse continue;
        try w.print("\x1b]4;{d};#{x:0>2}{x:0>2}{x:0>2}\x07", .{ i, c.r, c.g, c.b });
    }

    return try out.toOwnedSlice(alloc);
}

/// Pick the variant to apply, preferring dark (matches the preferences
/// window's applyPaletteToPath behavior).
pub fn preferredVariant(p: *const palette_mod.Palette) *const palette_mod.Variant {
    return if (p.dark.background != null) &p.dark else &p.light;
}

/// Apply the palette with the given id to a single surface.
pub fn applyToSurface(surface: *CoreSurface, id: []const u8) !void {
    const alloc = std.heap.c_allocator;

    const palettes = try palette_mod.loadAll(alloc);
    defer alloc.free(palettes);

    const p: *const palette_mod.Palette = blk: {
        for (palettes) |*candidate| {
            if (std.ascii.eqlIgnoreCase(candidate.id, id)) break :blk candidate;
        }
        return error.PaletteNotFound;
    };

    const bytes = try buildApplySequences(alloc, preferredVariant(p));
    // Ownership moves to the termio thread, which frees after parsing.
    surface.io.queueMessage(.{ .inject_output = .{
        .alloc = alloc,
        .data = bytes,
    } }, .unlocked);
    log.info("applied per-surface palette: {s}", .{id});
}

/// Reset a single surface's colors back to the config-derived defaults.
pub fn resetSurface(surface: *CoreSurface) !void {
    const alloc = std.heap.c_allocator;
    const bytes = try alloc.dupe(u8, reset_sequences);
    surface.io.queueMessage(.{ .inject_output = .{
        .alloc = alloc,
        .data = bytes,
    } }, .unlocked);
    log.info("reset per-surface palette", .{});
}

test "osc_palette: apply sequences" {
    const alloc = std.testing.allocator;
    var variant: palette_mod.Variant = .{
        .background = .{ .r = 0x1e, .g = 0x1e, .b = 0x2e },
        .foreground = .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 },
        .cursor = .{ .r = 0xff, .g = 0x00, .b = 0x00 },
    };
    variant.colors[0] = .{ .r = 0x00, .g = 0x00, .b = 0x00 };
    variant.colors[15] = .{ .r = 0xff, .g = 0xff, .b = 0xff };

    const bytes = try buildApplySequences(alloc, &variant);
    defer alloc.free(bytes);

    try std.testing.expectEqualStrings(
        "\x1b]11;#1e1e2e\x07" ++
            "\x1b]10;#cdd6f4\x07" ++
            "\x1b]12;#ff0000\x07" ++
            "\x1b]4;0;#000000\x07" ++
            "\x1b]4;15;#ffffff\x07",
        bytes,
    );
}

test "osc_palette: empty variant builds nothing" {
    const alloc = std.testing.allocator;
    const variant: palette_mod.Variant = .{};
    const bytes = try buildApplySequences(alloc, &variant);
    defer alloc.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "osc_palette: reset sequence shape" {
    try std.testing.expect(std.mem.indexOf(u8, reset_sequences, "\x1b]104\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, reset_sequences, "\x1b]110\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, reset_sequences, "\x1b]111\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, reset_sequences, "\x1b]112\x07") != null);
}
