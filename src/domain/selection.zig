//! Chooses which rows an activate/deactivate command acts on.
const std = @import("std");
const rows_mod = @import("rows.zig");

const Row = rows_mod.Row;

pub const Intent = enum {
    activate,
    deactivate,

    fn wants(intent: Intent) rows_mod.State {
        return switch (intent) {
            .activate => .eligible,
            .deactivate => .active,
        };
    }
};

pub const Outcome = union(enum) {
    /// Rows to act on (never empty).
    targets: []const Row,
    /// Nothing actionable. Holds rows that matched but are in another state
    /// (e.g. already active), which may be empty.
    no_match: []const Row,
    /// Several rows match and `all` was not requested.
    ambiguous: []const Row,
};

/// Rows matching all `terms` and in the state `intent` acts on. When several
/// match, rows whose scope name equals a term exactly win; if still several,
/// they are all selected only when `all` is set. With no terms, `all` selects
/// every row in the wanted state.
pub fn select(arena: std.mem.Allocator, rows: []const Row, terms: []const []const u8, intent: Intent, all: bool) !Outcome {
    var candidates: std.ArrayList(Row) = .empty;
    var others: std.ArrayList(Row) = .empty;
    for (rows) |row| {
        if (!rows_mod.matches(row, terms)) continue;
        try (if (row.state == intent.wants()) &candidates else &others).append(arena, row);
    }
    if (candidates.items.len == 0) return .{ .no_match = others.items };
    if (terms.len == 0 and !all) return .{ .ambiguous = candidates.items };
    if (candidates.items.len == 1) return .{ .targets = candidates.items };

    var exact: std.ArrayList(Row) = .empty;
    for (candidates.items) |row| {
        for (terms) |term| if (std.ascii.eqlIgnoreCase(row.eligibility.scope_name, term)) {
            try exact.append(arena, row);
            break;
        };
    }
    const preferred = if (exact.items.len > 0) exact.items else candidates.items;
    if (preferred.len == 1 or all) return .{ .targets = preferred };
    return .{ .ambiguous = preferred };
}

const testing = std.testing;

fn testRow(scope_name: []const u8, role_name: []const u8, state: rows_mod.State) Row {
    return .{
        .eligibility = .{ .schedule_id = "", .scope = "", .scope_name = scope_name, .role_definition_id = "", .role_name = role_name },
        .subscription_name = "Sub",
        .state = state,
    };
}

const fixture = [_]Row{
    testRow("rg-app-dev", "Contributor", .eligible),
    testRow("rg-app-dev-2", "Contributor", .eligible),
    testRow("rg-app-prod", "Owner", .active),
    testRow("rg-app-prod", "Contributor", .eligible),
};

test "select picks the single eligible match" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try select(arena_state.allocator(), &fixture, &.{ "prod", "contrib" }, .activate, false);
    try testing.expectEqual(@as(usize, 1), out.targets.len);
    try testing.expectEqualStrings("rg-app-prod", out.targets[0].eligibility.scope_name);
}

test "select prefers exact scope names over substring matches" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try select(arena_state.allocator(), &fixture, &.{"RG-APP-DEV"}, .activate, false);
    try testing.expectEqual(@as(usize, 1), out.targets.len);
    try testing.expectEqualStrings("rg-app-dev", out.targets[0].eligibility.scope_name);
}

test "select reports ambiguity unless all is requested" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 3), (try select(arena, &fixture, &.{"contrib"}, .activate, false)).ambiguous.len);
    try testing.expectEqual(@as(usize, 3), (try select(arena, &fixture, &.{"contrib"}, .activate, true)).targets.len);
}

test "select explains rows in the wrong state" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const out = try select(arena_state.allocator(), &fixture, &.{ "prod", "owner" }, .activate, false);
    try testing.expectEqual(@as(usize, 1), out.no_match.len);
    try testing.expectEqual(rows_mod.State.active, out.no_match[0].state);
}

test "deactivate without terms needs all" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqual(@as(usize, 1), (try select(arena, &fixture, &.{}, .deactivate, true)).targets.len);
    try testing.expect((try select(arena, &fixture, &.{}, .deactivate, false)) == .ambiguous);
}
