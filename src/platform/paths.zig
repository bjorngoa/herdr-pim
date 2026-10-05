//! Per-user directories, resolved the same way inside and outside herdr so
//! the status bar and the picker share one cache.
const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{NoHomeDirectory} || std.mem.Allocator.Error;

const app_dir = "pim";

/// Resolution order: `PIM_STATE_DIR`, then `%LOCALAPPDATA%\pim` on Windows,
/// else `$XDG_STATE_HOME/pim`, else `$HOME/.local/state/pim`.
pub fn stateDir(arena: std.mem.Allocator, env: *const std.process.Environ.Map) Error![]const u8 {
    return resolve(arena, env, builtin.os.tag == .windows);
}

fn resolve(arena: std.mem.Allocator, env: *const std.process.Environ.Map, windows: bool) Error![]const u8 {
    if (nonEmpty(env, "PIM_STATE_DIR")) |dir| return arena.dupe(u8, dir);
    if (windows) {
        const base = nonEmpty(env, "LOCALAPPDATA") orelse return error.NoHomeDirectory;
        return std.fs.path.join(arena, &.{ base, app_dir });
    }
    if (nonEmpty(env, "XDG_STATE_HOME")) |base| return std.fs.path.join(arena, &.{ base, app_dir });
    const home = nonEmpty(env, "HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(arena, &.{ home, ".local", "state", app_dir });
}

fn nonEmpty(env: *const std.process.Environ.Map, name: []const u8) ?[]const u8 {
    const value = env.get(name) orelse return null;
    return if (value.len == 0) null else value;
}

const testing = std.testing;

fn envOf(pairs: []const [2][]const u8) !std.process.Environ.Map {
    var env: std.process.Environ.Map = .init(testing.allocator);
    errdefer env.deinit();
    for (pairs) |p| try env.put(p[0], p[1]);
    return env;
}

test "stateDir prefers explicit override, then XDG, then HOME" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var env = try envOf(&.{ .{ "PIM_STATE_DIR", "/override" }, .{ "XDG_STATE_HOME", "/xdg" }, .{ "HOME", "/home/u" } });
    defer env.deinit();
    try testing.expectEqualStrings("/override", try resolve(arena, &env, false));

    try env.put("PIM_STATE_DIR", "");
    try testing.expectEqualStrings("/xdg/pim", try resolve(arena, &env, false));

    _ = env.swapRemove("XDG_STATE_HOME");
    try testing.expectEqualStrings("/home/u/.local/state/pim", try resolve(arena, &env, false));

    _ = env.swapRemove("HOME");
    try testing.expectError(error.NoHomeDirectory, resolve(arena, &env, false));
}

test "stateDir uses LOCALAPPDATA on Windows" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var env = try envOf(&.{.{ "LOCALAPPDATA", "C:\\Users\\u\\AppData\\Local" }});
    defer env.deinit();
    const dir = try resolve(arena_state.allocator(), &env, true);
    try testing.expect(std.mem.endsWith(u8, dir, "pim"));
    try testing.expect(std.mem.startsWith(u8, dir, "C:\\Users\\u\\AppData\\Local"));
}
