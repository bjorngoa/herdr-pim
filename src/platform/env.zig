//! Opt-in switches read from the environment.
const std = @import("std");

/// Shows a progress window in the picker while roles are being changed.
pub const progress_window = "PIM_PROGRESS_WINDOW";

/// True when `name` is `1`, `true`, `yes` or `on` (any case). Anything else,
/// including unset or empty, is false, so switches stay off by default.
pub fn enabled(env: *const std.process.Environ.Map, name: []const u8) bool {
    const value = std.mem.trim(u8, env.get(name) orelse return false, " ");
    for ([_][]const u8{ "1", "true", "yes", "on" }) |yes| {
        if (std.ascii.eqlIgnoreCase(value, yes)) return true;
    }
    return false;
}

const testing = std.testing;

test "switches are off unless explicitly turned on" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expect(!enabled(&env, progress_window));

    for ([_][]const u8{ "1", "true", "YES", " on " }) |v| {
        try env.put(progress_window, v);
        try testing.expect(enabled(&env, progress_window));
    }
    for ([_][]const u8{ "", "0", "false", "off", "no", "2" }) |v| {
        try env.put(progress_window, v);
        try testing.expect(!enabled(&env, progress_window));
    }
}
