//! Log sink that can be muted while a full-screen UI owns the terminal.
const std = @import("std");

var muted: std.atomic.Value(bool) = .init(false);

pub fn setMuted(value: bool) void {
    muted.store(value, .release);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (muted.load(.acquire)) return;
    std.log.defaultLog(level, scope, format, args);
}
