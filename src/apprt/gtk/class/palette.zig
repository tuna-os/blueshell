//! Ptyxis-style color palette: parsed at runtime from the vendored
//! `.palette` files (244 schemes). Each palette has a Light and Dark
//! variant containing background/foreground/cursor + 16 ANSI colors.
//!
//! The .palette format is a tiny INI dialect:
//!   [Palette]
//!   Name=My Theme
//!   [Light]
//!   Background=#ffffff
//!   Foreground=#000000
//!   Cursor=#000000
//!   Color0=#000000   ... Color15=#ffffff
//!   [Dark]
//!   ... same keys ...

const std = @import("std");

const embed = @import("palettes_embed.zig");

const log = std.log.scoped(.gtk_ptyxis_palette);

pub const RGB = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn fromHex(s: []const u8) ?RGB {
        const t = if (s.len > 0 and s[0] == '#') s[1..] else s;
        if (t.len != 6) return null;
        const r = std.fmt.parseInt(u8, t[0..2], 16) catch return null;
        const g = std.fmt.parseInt(u8, t[2..4], 16) catch return null;
        const b = std.fmt.parseInt(u8, t[4..6], 16) catch return null;
        return .{ .r = r, .g = g, .b = b };
    }
};

pub const Variant = struct {
    background: ?RGB = null,
    foreground: ?RGB = null,
    cursor: ?RGB = null,
    colors: [16]?RGB = .{null} ** 16,
};

pub const Palette = struct {
    /// File-derived id (basename without .palette).
    id: []const u8,
    /// Display name from the [Palette] Name= field; falls back to id.
    name: []const u8,
    light: Variant = .{},
    dark: Variant = .{},
};

/// Parse a single .palette file's bytes into a Palette. The returned
/// slices reference `bytes` directly — caller must keep `bytes` alive.
pub fn parse(id: []const u8, bytes: []const u8) Palette {
    var p: Palette = .{ .id = id, .name = id };

    var section: enum { none, palette, light, dark } = .none;

    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[Palette]")) section = .palette
            else if (std.mem.eql(u8, line, "[Light]")) section = .light
            else if (std.mem.eql(u8, line, "[Dark]")) section = .dark
            else section = .none;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        switch (section) {
            .palette => {
                if (std.mem.eql(u8, key, "Name")) {
                    p.name = val;
                } else {
                    // Many palettes (Gogh-derived, e.g. Aci, Aco, etc.)
                    // put Background/Foreground/Color0..15 directly
                    // under [Palette] with no [Light]/[Dark] sections.
                    // Apply such keys to BOTH variants so the renderer's
                    // dark-then-light fallback finds them either way.
                    applyKey(&p.light, key, val);
                    applyKey(&p.dark, key, val);
                }
            },
            .light, .dark => {
                const v: *Variant = if (section == .light) &p.light else &p.dark;
                applyKey(v, key, val);
            },
            .none => {},
        }
    }

    return p;
}

fn applyKey(v: *Variant, key: []const u8, val: []const u8) void {
    const rgb = RGB.fromHex(val) orelse return;
    if (std.mem.eql(u8, key, "Background")) {
        v.background = rgb;
    } else if (std.mem.eql(u8, key, "Foreground")) {
        v.foreground = rgb;
    } else if (std.mem.eql(u8, key, "Cursor")) {
        v.cursor = rgb;
    } else if (std.mem.startsWith(u8, key, "Color")) {
        const n = std.fmt.parseInt(u8, key[5..], 10) catch return;
        if (n < 16) v.colors[n] = rgb;
    }
}

/// Parse all vendored palettes. Caller-owned slice; the palette `bytes`
/// fields reference embedded data (static lifetime).
pub fn loadAll(alloc: std.mem.Allocator) ![]Palette {
    var list = try alloc.alloc(Palette, embed.entries.len);
    for (embed.entries, 0..) |entry, i| {
        list[i] = parse(entry.name, entry.bytes);
    }
    return list;
}

test "parse 3024" {
    const bytes =
        \\[Palette]
        \\Name=3024
        \\
        \\[Light]
        \\Background=#F7F7F7
        \\Foreground=#4A4543
        \\Color0=#090300
        \\Color15=#F7F7F7
    ;
    const p = parse("3024", bytes);
    try std.testing.expectEqualStrings("3024", p.name);
    try std.testing.expect(p.light.background.?.r == 0xF7);
    try std.testing.expect(p.light.colors[15].?.r == 0xF7);
}
