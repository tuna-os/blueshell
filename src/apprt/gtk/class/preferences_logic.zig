//! Pure logic for the Ptyxis-style preferences window: mapping between
//! widget state (combo indices, switch booleans) and Ghostty config file
//! values. Kept free of GTK imports so it can be unit-tested headlessly
//! (`zig build test -Dtest-filter=preferences_logic`).
//!
//! The round-trip tests at the bottom parse every emitted value with
//! Ghostty's real config parser, so an upstream rename/removal of a
//! config enum member fails these tests instead of silently producing
//! config lines Ghostty rejects at runtime.

const std = @import("std");

/// Value tables for each ComboRow, in blueprint model order. The
/// handler indexes with the selected position; the corresponding
/// `loadCurrentValues` switch in preferences_window.zig is the inverse.
pub const cursor_style_values = [_][]const u8{ "block", "block_hollow", "bar", "underline" };
/// Index 0 = Follow System: empty value resets the optional to default.
pub const cursor_blink_values = [_][]const u8{ "", "true", "false" };
pub const scrollbar_values = [_][]const u8{ "system", "never" };
pub const tab_position_values = [_][]const u8{ "current", "end" };
pub const tab_bar_values = [_][]const u8{ "auto", "always", "never" };
pub const tabs_location_values = [_][]const u8{ "top", "bottom" };
pub const window_save_state_values = [_][]const u8{ "default", "never", "always" };
pub const copy_on_select_values = [_][]const u8{ "false", "true", "clipboard" };
pub const shell_integration_values = [_][]const u8{ "detect", "none", "bash", "elvish", "fish", "nushell", "zsh" };
pub const notify_on_finish_values = [_][]const u8{ "never", "unfocused", "always" };
pub const confirm_close_values = [_][]const u8{ "false", "true", "always" };

/// Look up a combo value by selected index; null when the index is out
/// of range (e.g. GTK_INVALID_LIST_POSITION during teardown).
pub fn comboValue(comptime table: []const []const u8, selected: c_uint) ?[]const u8 {
    if (selected >= table.len) return null;
    return table[selected];
}

/// Format a `bell-features` value. Ghostty's packed-struct parser starts
/// from the *defaults* (attention=true, title=true), so features the UI
/// controls must be written explicitly in both polarities — writing only
/// the enabled ones can never turn a default-on feature off.
pub fn formatBellFeatures(buf: []u8, audible: bool, attention: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s},{s},title", .{
        @as([]const u8, if (audible) "audio" else "no-audio"),
        @as([]const u8, if (attention) "attention" else "no-attention"),
    }) catch unreachable;
    return buf[0..w.end];
}

/// Format a `scroll-to-bottom` value with explicit polarities for the
/// same reason as `formatBellFeatures` (keystroke defaults to true).
pub fn formatScrollToBottom(buf: []u8, keystroke: bool, output: bool) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{s},{s}", .{
        @as([]const u8, if (keystroke) "keystroke" else "no-keystroke"),
        @as([]const u8, if (output) "output" else "no-output"),
    }) catch unreachable;
    return buf[0..w.end];
}

pub const FontParts = struct {
    family: []const u8,
    /// Present only when the trailing token parses as a number.
    size: ?[]const u8,
};

/// Split a Pango font description string ("JetBrains Mono 13") into the
/// family and size parts Ghostty stores separately. A description with
/// no trailing numeric size yields the whole string as family.
pub fn splitFontDesc(desc: []const u8) FontParts {
    if (std.mem.lastIndexOfScalar(u8, desc, ' ')) |sp| {
        const size = desc[sp + 1 ..];
        if (std.fmt.parseFloat(f64, size)) |_| {
            return .{ .family = desc[0..sp], .size = size };
        } else |_| {}
    }
    return .{ .family = desc, .size = null };
}

/// Format an `adjust-cell-{width,height}` percentage from the spin-row
/// multiplier (1.0 = no adjustment → "0%", 1.5 → "50%").
pub fn formatSpacingPercent(buf: []u8, multiplier: f64) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{d:.0}%", .{(multiplier - 1.0) * 100.0}) catch unreachable;
    return buf[0..w.end];
}

// ---------------------------------------------------------------------
// Tests. The imports below are analyzed only when tests build, so this
// module stays GTK-free for consumers.

const Config = @import("../../../config.zig").Config;
const args = @import("../../../cli/args.zig");

fn expectParsesAsEnum(comptime E: type, table: []const []const u8) !void {
    // Every table entry must be a member of the enum...
    for (table) |v| {
        _ = std.meta.stringToEnum(E, v) orelse return error.UnknownEnumValue;
    }
    // ...and every enum member must appear in the table, so an upstream
    // addition (new shell, new tab-bar mode) fails loudly here instead
    // of being silently unreachable from the UI.
    inline for (@typeInfo(E).@"enum".fields) |f| {
        var found = false;
        for (table) |v| {
            if (std.mem.eql(u8, v, f.name)) found = true;
        }
        if (!found) return error.EnumValueMissingFromTable;
    }
}

test "preferences_logic: combo tables round-trip through Config enums" {
    try expectParsesAsEnum(Config.CopyOnSelect, &copy_on_select_values);
    try expectParsesAsEnum(Config.ShellIntegration, &shell_integration_values);
    try expectParsesAsEnum(Config.NotifyOnCommandFinish, &notify_on_finish_values);
    try expectParsesAsEnum(Config.WindowSaveState, &window_save_state_values);
    try expectParsesAsEnum(Config.WindowNewTabPosition, &tab_position_values);
    try expectParsesAsEnum(Config.WindowShowTabBar, &tab_bar_values);
}

test "preferences_logic: cursor style table matches terminal CursorStyle" {
    const CursorStyle = @import("../../../terminal/main.zig").CursorStyle;
    try expectParsesAsEnum(CursorStyle, &cursor_style_values);
}

test "preferences_logic: comboValue bounds" {
    try std.testing.expectEqualStrings("block", comboValue(&cursor_style_values, 0).?);
    try std.testing.expectEqualStrings("underline", comboValue(&cursor_style_values, 3).?);
    try std.testing.expect(comboValue(&cursor_style_values, 4) == null);
    // GTK_INVALID_LIST_POSITION
    try std.testing.expect(comboValue(&cursor_style_values, std.math.maxInt(c_uint)) == null);
}

test "preferences_logic: bell features parse and disable default-on features" {
    var buf: [64]u8 = undefined;

    // attention defaults to true; emitting no-attention must disable it.
    {
        const v = try args.parsePackedStruct(
            Config.BellFeatures,
            formatBellFeatures(&buf, true, false),
        );
        try std.testing.expect(v.audio);
        try std.testing.expect(!v.attention);
        try std.testing.expect(v.title);
    }
    {
        const v = try args.parsePackedStruct(
            Config.BellFeatures,
            formatBellFeatures(&buf, false, true),
        );
        try std.testing.expect(!v.audio);
        try std.testing.expect(v.attention);
    }
    {
        const v = try args.parsePackedStruct(
            Config.BellFeatures,
            formatBellFeatures(&buf, false, false),
        );
        try std.testing.expect(!v.audio);
        try std.testing.expect(!v.attention);
        try std.testing.expect(v.title);
    }
}

test "preferences_logic: scroll-to-bottom parses with explicit polarity" {
    var buf: [64]u8 = undefined;
    // keystroke defaults to true; the false case must actually disable it.
    const v = try args.parsePackedStruct(
        Config.ScrollToBottom,
        formatScrollToBottom(&buf, false, true),
    );
    try std.testing.expect(!v.keystroke);
    try std.testing.expect(v.output);
}

test "preferences_logic: splitFontDesc" {
    {
        const p = splitFontDesc("JetBrains Mono 13");
        try std.testing.expectEqualStrings("JetBrains Mono", p.family);
        try std.testing.expectEqualStrings("13", p.size.?);
    }
    {
        const p = splitFontDesc("Monospace 10.5");
        try std.testing.expectEqualStrings("Monospace", p.family);
        try std.testing.expectEqualStrings("10.5", p.size.?);
    }
    {
        // No size — whole string is the family.
        const p = splitFontDesc("Comic Sans");
        try std.testing.expectEqualStrings("Comic Sans", p.family);
        try std.testing.expect(p.size == null);
    }
}

test "preferences_logic: formatSpacingPercent" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0%", formatSpacingPercent(&buf, 1.0));
    try std.testing.expectEqualStrings("50%", formatSpacingPercent(&buf, 1.5));
    try std.testing.expectEqualStrings("-25%", formatSpacingPercent(&buf, 0.75));
}
