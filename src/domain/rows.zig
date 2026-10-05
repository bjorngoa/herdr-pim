//! Joins eligibilities with current assignments and in-flight requests into
//! one display row per eligible role. Matching is by (scope, role definition),
//! case-insensitive, because ARM does not normalise casing across APIs.
const std = @import("std");
const role = @import("role.zig");
const scope_mod = @import("scope.zig");

pub const State = enum { active, pending, eligible };

pub const Row = struct {
    eligibility: role.Eligibility,
    subscription_name: []const u8,
    state: State,
    /// Set when `state == .active` and the activation is time-bound.
    active_until: ?i64 = null,
};

/// Builds rows sorted for display. The caller owns the returned slice; strings
/// are borrowed from `snapshot`.
pub fn build(gpa: std.mem.Allocator, snapshot: role.Snapshot, now: i64) std.mem.Allocator.Error![]Row {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var active: std.StringHashMapUnmanaged(?i64) = .empty;
    for (snapshot.assignments) |a| {
        if (a.kind != .activated) continue;
        if (a.ends_at) |end| if (end <= now) continue;
        const gop = try active.getOrPut(scratch, try roleKey(scratch, a.scope, a.role_definition_id));
        gop.value_ptr.* = if (gop.found_existing) laterEnd(gop.value_ptr.*, a.ends_at) else a.ends_at;
    }

    var pending: std.StringHashMapUnmanaged(void) = .empty;
    for (snapshot.requests) |r| {
        if (r.isInFlight(now)) try pending.put(scratch, try roleKey(scratch, r.scope, r.role_definition_id), {});
    }

    var subscription_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (snapshot.subscriptions) |s| {
        try subscription_names.put(scratch, try std.ascii.allocLowerString(scratch, s.id), s.name);
    }

    const rows = try gpa.alloc(Row, snapshot.eligibilities.len);
    errdefer gpa.free(rows);
    for (snapshot.eligibilities, rows) |e, *row| {
        const k = try roleKey(scratch, e.scope, e.role_definition_id);
        const subscription_id = if (scope_mod.Scope.parse(e.scope)) |s| s.subscription_id else |_| "";
        const lower_id = try std.ascii.allocLowerString(scratch, subscription_id);
        row.* = .{
            .eligibility = e,
            .subscription_name = subscription_names.get(lower_id) orelse subscription_id,
            .state = .eligible,
        };
        if (active.get(k)) |until| {
            row.state = .active;
            row.active_until = until;
        } else if (pending.contains(k)) {
            row.state = .pending;
        }
    }

    std.mem.sort(Row, rows, {}, lessThan);
    return rows;
}

/// True when every term occurs (case-insensitively) in the row's scope,
/// subscription or role name. An empty term list matches everything.
pub fn matches(row: Row, terms: []const []const u8) bool {
    for (terms) |term| {
        const fields = [_][]const u8{ row.eligibility.scope_name, row.subscription_name, row.eligibility.role_name };
        const found = for (fields) |f| {
            if (std.ascii.findIgnoreCase(f, term) != null) break true;
        } else false;
        if (!found) return false;
    }
    return true;
}

/// Case-insensitive identity of a role at a scope, used to join ARM collections.
pub fn roleKey(allocator: std.mem.Allocator, scope: []const u8, role_definition_id: []const u8) std.mem.Allocator.Error![]const u8 {
    const joined = try std.fmt.allocPrint(allocator, "{s}|{s}", .{
        std.mem.trimEnd(u8, scope, "/"),
        scope_mod.lastSegment(role_definition_id),
    });
    return std.ascii.lowerString(joined, joined);
}

fn laterEnd(a: ?i64, b: ?i64) ?i64 {
    const x = a orelse return null;
    const y = b orelse return null;
    return @max(x, y);
}

fn stateRank(s: State) u8 {
    return switch (s) {
        .active => 0,
        .pending => 1,
        .eligible => 2,
    };
}

fn lessThan(_: void, a: Row, b: Row) bool {
    if (a.state != b.state) return stateRank(a.state) < stateRank(b.state);
    if (a.state == .active) {
        const ae = a.active_until orelse std.math.maxInt(i64);
        const be = b.active_until orelse std.math.maxInt(i64);
        if (ae != be) return ae < be;
    }
    const pairs = [_][2][]const u8{
        .{ a.subscription_name, b.subscription_name },
        .{ a.eligibility.scope_name, b.eligibility.scope_name },
        .{ a.eligibility.role_name, b.eligibility.role_name },
    };
    for (pairs) |p| switch (std.ascii.orderIgnoreCase(p[0], p[1])) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    };
    return false;
}

const testing = std.testing;

fn elig(scope: []const u8, name: []const u8, role_name: []const u8) role.Eligibility {
    return .{
        .schedule_id = "sched",
        .scope = scope,
        .scope_name = name,
        .role_definition_id = "/subscriptions/s1/providers/Microsoft.Authorization/roleDefinitions/r1",
        .role_name = role_name,
    };
}

fn snapshotOf(
    eligibilities: []const role.Eligibility,
    assignments: []const role.Assignment,
    requests: []const role.Request,
) role.Snapshot {
    return .{
        .fetched_at = 0,
        .eligibilities = eligibilities,
        .assignments = assignments,
        .requests = requests,
        .subscriptions = &.{.{ .id = "S1", .name = "Sub One" }},
    };
}

test "build marks active, pending and eligible rows, matching case-insensitively" {
    const now: i64 = 1000;
    const eligibilities = [_]role.Eligibility{
        elig("/subscriptions/s1/resourceGroups/rg-a", "rg-a", "Owner"),
        elig("/subscriptions/s1/resourceGroups/rg-b", "rg-b", "Owner"),
        elig("/subscriptions/s1/resourceGroups/rg-c", "rg-c", "Owner"),
    };
    const assignments = [_]role.Assignment{.{
        .scope = "/SUBSCRIPTIONS/S1/RESOURCEGROUPS/RG-C",
        .role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/R1",
        .kind = .activated,
        .ends_at = now + 600,
    }};
    const requests = [_]role.Request{.{
        .scope = "/subscriptions/s1/resourceGroups/rg-b",
        .role_definition_id = "r1",
        .status = "PendingApproval",
        .created_at = now - 10,
    }};

    const rows = try build(testing.allocator, snapshotOf(&eligibilities, &assignments, &requests), now);
    defer testing.allocator.free(rows);

    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqualStrings("rg-c", rows[0].eligibility.scope_name);
    try testing.expectEqual(State.active, rows[0].state);
    try testing.expectEqual(@as(?i64, now + 600), rows[0].active_until);
    try testing.expectEqual(State.pending, rows[1].state);
    try testing.expectEqual(State.eligible, rows[2].state);
    try testing.expectEqualStrings("Sub One", rows[2].subscription_name);
}

test "build ignores expired activations and standing assignments" {
    const now: i64 = 1000;
    const eligibilities = [_]role.Eligibility{elig("/subscriptions/s1/resourceGroups/rg-a", "rg-a", "Owner")};
    const assignments = [_]role.Assignment{
        .{ .scope = "/subscriptions/s1/resourceGroups/rg-a", .role_definition_id = "r1", .kind = .activated, .ends_at = now },
        .{ .scope = "/subscriptions/s1/resourceGroups/rg-a", .role_definition_id = "r1", .kind = .assigned },
    };
    const rows = try build(testing.allocator, snapshotOf(&eligibilities, &assignments, &.{}), now);
    defer testing.allocator.free(rows);
    try testing.expectEqual(State.eligible, rows[0].state);
}

test "build keeps the latest end time when activations overlap" {
    const now: i64 = 1000;
    const eligibilities = [_]role.Eligibility{elig("/subscriptions/s1/resourceGroups/rg-a", "rg-a", "Owner")};
    const assignments = [_]role.Assignment{
        .{ .scope = "/subscriptions/s1/resourceGroups/rg-a", .role_definition_id = "r1", .kind = .activated, .ends_at = now + 60 },
        .{ .scope = "/subscriptions/s1/resourceGroups/rg-a/", .role_definition_id = "r1", .kind = .activated, .ends_at = now + 900 },
    };
    const rows = try build(testing.allocator, snapshotOf(&eligibilities, &assignments, &.{}), now);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(?i64, now + 900), rows[0].active_until);
}

test "build falls back to the subscription id when the name is unknown" {
    const eligibilities = [_]role.Eligibility{elig("/subscriptions/unknown/resourceGroups/rg", "rg", "Owner")};
    const rows = try build(testing.allocator, snapshotOf(&eligibilities, &.{}, &.{}), 0);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("unknown", rows[0].subscription_name);
}

test "matches requires every term in some field" {
    const row: Row = .{ .eligibility = elig("/s", "OrdersProdRG", "Contributor"), .subscription_name = "Contoso", .state = .eligible };
    try testing.expect(matches(row, &.{}));
    try testing.expect(matches(row, &.{ "orders", "contrib" }));
    try testing.expect(matches(row, &.{"contoso"}));
    try testing.expect(!matches(row, &.{ "orders", "owner" }));
}
