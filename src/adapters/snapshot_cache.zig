//! Persists the last fetched `Snapshot` so status bars render instantly
//! without network calls. Contains no credentials.
const std = @import("std");
const role = @import("../domain/role.zig");
const store = @import("json_store.zig");

const file_name = "snapshot.json";

/// The cached snapshot, or null when missing, unreadable or outdated.
pub fn load(arena: std.mem.Allocator, io: std.Io, dir_path: []const u8) ?role.Snapshot {
    return store.load(role.Snapshot, arena, io, dir_path, file_name);
}

pub fn save(io: std.Io, dir_path: []const u8, snapshot: role.Snapshot) !void {
    try store.save(role.Snapshot, io, dir_path, file_name, snapshot);
}

const testing = std.testing;

test "snapshots round-trip with optional fields and enums" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const eligibilities = [_]role.Eligibility{.{
        .schedule_id = "sched",
        .scope = "/subscriptions/s/resourceGroups/rg",
        .scope_name = "rg",
        .role_definition_id = "r",
        .role_name = "Owner",
        .ends_at = 1_800_000_000,
    }};
    const assignments = [_]role.Assignment{.{ .scope = "/subscriptions/s", .role_definition_id = "r", .kind = .activated }};
    const snapshot: role.Snapshot = .{
        .fetched_at = 1_700_000_000,
        .eligibilities = &eligibilities,
        .assignments = &assignments,
        .requests = &.{},
        .subscriptions = &.{},
    };

    var out: std.Io.Writer.Allocating = .init(arena);
    try store.encode(role.Snapshot, snapshot, &out.writer);
    const decoded = try store.decode(role.Snapshot, arena, out.written());
    try testing.expectEqual(@as(?i64, 1_800_000_000), decoded.eligibilities[0].ends_at);
    try testing.expectEqual(role.AssignmentKind.activated, decoded.assignments[0].kind);
    try testing.expect(decoded.assignments[0].ends_at == null);
}
