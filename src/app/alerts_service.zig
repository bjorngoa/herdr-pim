//! Raises herdr notifications for role changes between `pim status` runs.
const std = @import("std");
const rows_mod = @import("../domain/rows.zig");
const alerts = @import("../domain/alerts.zig");
const store = @import("../adapters/json_store.zig");
const herdr = @import("../adapters/herdr.zig");
const messages = @import("../present/messages.zig");
const session_mod = @import("session.zig");

const log = std.log.scoped(.alerts);

const file_name = "alerts.json";
pub const warn_before_s = 15 * 60;

/// Sends due notifications and remembers them. A notification that cannot be
/// delivered is logged and not retried, so a broken herdr never spams later.
pub fn process(
    arena: std.mem.Allocator,
    env: session_mod.Env,
    notifier: herdr.Notifier,
    rows: []const rows_mod.Row,
    now: i64,
) !void {
    const previous = store.load(alerts.Memory, arena, env.io, env.state_dir, file_name);
    const result = try alerts.evaluate(arena, previous, rows, now, warn_before_s);
    for (result.alerts) |alert| {
        const n = try messages.describeAlert(arena, alert, now);
        notifier.show(arena, env.io, n.title, n.body) catch |err| log.warn("cannot show notification: {t}", .{err});
    }
    try store.save(alerts.Memory, env.io, env.state_dir, file_name, result.memory);
}
