//! herdr integration through its CLI (`herdr notification show`).
const std = @import("std");

pub const Error = error{NotificationFailed} || std.process.RunError;

const timeout_s = 5;

pub const Notifier = struct {
    /// herdr executable: `$HERDR_BIN_PATH` inside herdr, else `herdr` on PATH.
    bin: []const u8,

    pub fn fromEnv(env: *const std.process.Environ.Map) Notifier {
        if (env.get("HERDR_BIN_PATH")) |path| if (path.len > 0) return .{ .bin = path };
        return .{ .bin = "herdr" };
    }

    /// Shows a toast. `title` and `body` are passed as arguments, not through
    /// a shell, and must already be sanitized for display.
    pub fn show(self: Notifier, arena: std.mem.Allocator, io: std.Io, title: []const u8, body: []const u8) Error!void {
        const result = try std.process.run(arena, io, .{
            .argv = &.{ self.bin, "notification", "show", title, "--body", body },
            .stdout_limit = .limited(16 * 1024),
            .stderr_limit = .limited(16 * 1024),
            .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
        });
        const ok = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) return error.NotificationFailed;
    }
};

const testing = std.testing;

test "fromEnv prefers the running herdr binary" {
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings("herdr", Notifier.fromEnv(&env).bin);
    try env.put("HERDR_BIN_PATH", "/opt/herdr/bin/herdr");
    try testing.expectEqualStrings("/opt/herdr/bin/herdr", Notifier.fromEnv(&env).bin);
}
