//! Maps terminal key events to picker inputs.
const std = @import("std");
const vaxis = @import("vaxis");
const Input = @import("model.zig").Input;

const Key = vaxis.Key;

pub fn translate(key: Key) ?Input {
    const ctrl: Key.Modifiers = .{ .ctrl = true };
    const shift: Key.Modifiers = .{ .shift = true };

    if (key.matches('c', ctrl)) return .quit;
    if (key.matches('d', ctrl)) return .deactivate;
    if (key.matches('r', ctrl)) return .refresh;
    if (key.matches('w', ctrl)) return .delete_word;
    if (key.matches('u', ctrl)) return .clear_line;
    if (key.matches('n', ctrl)) return .down;
    if (key.matches('p', ctrl)) return .up;

    if (key.matches(Key.tab, shift)) return .shift_tab;
    const plain = [_]struct { u21, Input }{
        .{ Key.up, .up },
        .{ Key.down, .down },
        .{ Key.page_up, .page_up },
        .{ Key.page_down, .page_down },
        .{ Key.home, .home },
        .{ Key.end, .end },
        .{ Key.tab, .tab },
        .{ Key.enter, .enter },
        .{ Key.escape, .escape },
        .{ Key.backspace, .backspace },
    };
    for (plain) |p| if (key.matches(p[0], .{})) return p[1];

    if (key.mods.ctrl or key.mods.alt or key.mods.super) return null;
    if (key.text) |t| if (t.len > 0) return .{ .text = t };
    return null;
}

const testing = std.testing;

test "control shortcuts map to commands" {
    try testing.expectEqual(Input.quit, translate(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }).?);
    try testing.expectEqual(Input.deactivate, translate(.{ .codepoint = 'd', .mods = .{ .ctrl = true } }).?);
    try testing.expectEqual(Input.refresh, translate(.{ .codepoint = 'r', .mods = .{ .ctrl = true } }).?);
    try testing.expectEqual(Input.down, translate(.{ .codepoint = 'n', .mods = .{ .ctrl = true } }).?);
}

test "navigation and editing keys" {
    try testing.expectEqual(Input.up, translate(.{ .codepoint = Key.up }).?);
    try testing.expectEqual(Input.enter, translate(.{ .codepoint = Key.enter }).?);
    try testing.expectEqual(Input.tab, translate(.{ .codepoint = Key.tab }).?);
    try testing.expectEqual(Input.shift_tab, translate(.{ .codepoint = Key.tab, .mods = .{ .shift = true } }).?);
    try testing.expectEqual(Input.backspace, translate(.{ .codepoint = Key.backspace }).?);
}

test "printable keys become text; other modified keys are ignored" {
    try testing.expectEqualStrings("a", translate(.{ .codepoint = 'a', .text = "a" }).?.text);
    try testing.expectEqualStrings("Ø", translate(.{ .codepoint = 'ø', .text = "Ø", .mods = .{ .shift = true } }).?.text);
    try testing.expect(translate(.{ .codepoint = 'x', .text = "x", .mods = .{ .alt = true } }) == null);
    try testing.expect(translate(.{ .codepoint = 'q', .mods = .{ .ctrl = true } }) == null);
}
