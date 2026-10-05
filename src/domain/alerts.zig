//! Decides which notifications to raise as roles change between status runs:
//! an activation about to expire, an activation that expired, and a pending
//! request that became active. Pure; the caller persists `Memory`.
const std = @import("std");
const rows_mod = @import("rows.zig");

const Row = rows_mod.Row;

pub const Kind = enum { expiring, expired, activated };

pub const Alert = struct {
    kind: Kind,
    row: Row,
};

/// What was seen for a role on the previous run.
pub const Seen = struct {
    id: []const u8,
    state: rows_mod.State,
    until: ?i64 = null,
    /// An `expiring` alert was raised for this `until`.
    warned: bool = false,
};

pub const Memory = struct {
    pub const schema_version: u32 = 1;

    version: u32 = schema_version,
    seen: []const Seen = &.{},
};

pub const Result = struct {
    alerts: []const Alert,
    memory: Memory,
};

/// An activation that disappears within this long of its end counts as
/// expired rather than manually deactivated.
const expiry_grace_s = 120;

/// Without `previous` (first run) only expiry warnings are raised, so nothing
/// is reported for changes that happened before pim was watching.
pub fn evaluate(
    arena: std.mem.Allocator,
    previous: ?Memory,
    rows: []const Row,
    now: i64,
    warn_before_s: i64,
) std.mem.Allocator.Error!Result {
    var before: std.StringHashMapUnmanaged(Seen) = .empty;
    if (previous) |p| for (p.seen) |s| try before.put(arena, s.id, s);

    var alerts: std.ArrayList(Alert) = .empty;
    var seen: std.ArrayList(Seen) = .empty;
    for (rows) |row| {
        const id = row.eligibility.schedule_id;
        const last = before.get(id);
        switch (row.state) {
            .active => {
                if (last) |l| if (l.state == .pending) try alerts.append(arena, .{ .kind = .activated, .row = row });
                var warned = if (last) |l| l.state == .active and l.until == row.active_until and l.warned else false;
                if (row.active_until) |until| if (!warned and until > now and until - now <= warn_before_s) {
                    try alerts.append(arena, .{ .kind = .expiring, .row = row });
                    warned = true;
                };
                try seen.append(arena, .{ .id = id, .state = .active, .until = row.active_until, .warned = warned });
            },
            .pending => try seen.append(arena, .{ .id = id, .state = .pending }),
            .eligible => if (last) |l| if (l.state == .active) if (l.until) |until| if (until <= now + expiry_grace_s) {
                try alerts.append(arena, .{ .kind = .expired, .row = row });
            },
        }
    }
    return .{ .alerts = alerts.items, .memory = .{ .seen = seen.items } };
}

const testing = std.testing;

fn testRow(id: []const u8, state: rows_mod.State, until: ?i64) Row {
    return .{
        .eligibility = .{ .schedule_id = id, .scope = "", .scope_name = "rg", .role_definition_id = "", .role_name = "Owner" },
        .subscription_name = "Sub",
        .state = state,
        .active_until = until,
    };
}

const warn = 15 * 60;

test "warns once when an activation nears its end" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const far = try evaluate(arena, null, &.{testRow("a", .active, 10_000)}, 0, warn);
    try testing.expectEqual(@as(usize, 0), far.alerts.len);

    const near = try evaluate(arena, far.memory, &.{testRow("a", .active, 10_000)}, 10_000 - 600, warn);
    try testing.expectEqual(@as(usize, 1), near.alerts.len);
    try testing.expectEqual(Kind.expiring, near.alerts[0].kind);

    const again = try evaluate(arena, near.memory, &.{testRow("a", .active, 10_000)}, 10_000 - 300, warn);
    try testing.expectEqual(@as(usize, 0), again.alerts.len);

    const renewed = try evaluate(arena, again.memory, &.{testRow("a", .active, 20_000)}, 20_000 - 60, warn);
    try testing.expectEqual(Kind.expiring, renewed.alerts[0].kind);
}

test "reports expiry but not manual deactivation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const memory: Memory = .{ .seen = &.{
        .{ .id = "expired", .state = .active, .until = 1_000 },
        .{ .id = "manual", .state = .active, .until = 50_000 },
    } };
    const result = try evaluate(arena, memory, &.{ testRow("expired", .eligible, null), testRow("manual", .eligible, null) }, 1_030, warn);
    try testing.expectEqual(@as(usize, 1), result.alerts.len);
    try testing.expectEqual(Kind.expired, result.alerts[0].kind);
    try testing.expectEqualStrings("expired", result.alerts[0].row.eligibility.schedule_id);
    try testing.expectEqual(@as(usize, 0), result.memory.seen.len);
}

test "announces pending requests that became active" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = try evaluate(arena, .{}, &.{testRow("p", .pending, null)}, 0, warn);
    try testing.expectEqual(@as(usize, 0), first.alerts.len);
    const next = try evaluate(arena, first.memory, &.{testRow("p", .active, 99_999)}, 10, warn);
    try testing.expectEqual(Kind.activated, next.alerts[0].kind);
}

test "first run reports nothing but imminent expiry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const rows = [_]Row{ testRow("a", .active, 100), testRow("b", .eligible, null), testRow("c", .pending, null) };
    const result = try evaluate(arena_state.allocator(), null, &rows, 0, warn);
    try testing.expectEqual(@as(usize, 1), result.alerts.len);
    try testing.expectEqual(Kind.expiring, result.alerts[0].kind);
    try testing.expectEqual(@as(usize, 2), result.memory.seen.len);
}
