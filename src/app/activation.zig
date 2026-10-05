//! Self-activation and deactivation of eligible roles.
const std = @import("std");
const role = @import("../domain/role.zig");
const rows_mod = @import("../domain/rows.zig");
const policy_mod = @import("../domain/policy.zig");
const duration = @import("../domain/duration.zig");
const selection = @import("../domain/selection.zig");
const time = @import("../domain/time.zig");
const azcli = @import("../adapters/azcli.zig");
const arm = @import("../adapters/arm/client.zig");
const dto = @import("../adapters/arm/dto.zig");
const session_mod = @import("session.zig");

const Row = rows_mod.Row;
const Session = session_mod.Session;
const Diagnostics = session_mod.Diagnostics;

const log = std.log.scoped(.activation);

pub const Error = azcli.Error || std.Io.Cancelable;

pub const Plan = struct {
    row: Row,
    /// Null when the policy could not be read; Azure still validates the request.
    policy: ?policy_mod.Policy,
    duration: duration.Clamped,

    /// Unknown policies are assumed to require a justification, as most do.
    pub fn needsJustification(self: Plan) bool {
        const p = self.policy orelse return true;
        return p.justification_required;
    }
};

pub const Failure = struct {
    reason: Reason,
    arm: arm.Diagnostics = .{},
    /// Error name for `transport` failures.
    detail: []const u8 = "",

    pub const Reason = enum { justification_required, ticket_required, rejected, transport };
};

pub const Outcome = union(enum) {
    /// Azure accepted the request; the value is its status, e.g. `Provisioned`.
    accepted: []const u8,
    failed: Failure,
};

pub const Submission = struct {
    row: Row,
    outcome: Outcome,

    /// Accepted and expected to take effect without a human approver.
    pub fn settlesAutomatically(self: Submission) bool {
        return switch (self.outcome) {
            .accepted => |status| !role.Request.awaitsApproval(status),
            .failed => false,
        };
    }
};

/// Reads each role's policy (concurrently) and fits `requested_min` to it.
/// Results are owned by `arena`, which must be thread-safe (as for all functions here).
pub fn plan(session: *Session, arena: std.mem.Allocator, rows: []const Row, requested_min: u32, diag: *Diagnostics) Error![]Plan {
    const client = try session.client(diag);
    const io = session.env.io;
    const plans = try arena.alloc(Plan, rows.len);

    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (rows, plans) |row, *p| {
        p.* = .{ .row = row, .policy = null, .duration = .{ .minutes = requested_min, .clamped = false } };
        group.async(io, loadPolicy, .{ &client, arena, p, requested_min });
    }
    try group.await(io);
    return plans;
}

fn loadPolicy(client: *const arm.Client, arena: std.mem.Allocator, p: *Plan, requested_min: u32) void {
    var d: arm.Diagnostics = .{};
    const e = p.row.eligibility;
    const found = client.getPolicy(arena, e.scope, e.role_definition_id, &d) catch |err| {
        log.warn("cannot read PIM policy ({t}); Azure will validate the request", .{err});
        return;
    };
    const policy = found orelse policy_mod.Policy{};
    p.policy = policy;
    p.duration = duration.clamp(requested_min, policy.max_duration_min);
}

pub fn activate(session: *Session, arena: std.mem.Allocator, plans: []const Plan, justification: []const u8, now: i64, diag: *Diagnostics) Error![]Submission {
    const principal_id = try session.principalId(diag);
    const client = try session.client(diag);
    const io = session.env.io;

    var start_buf: [20]u8 = undefined;
    const start = try arena.dupe(u8, time.formatRfc3339(now, &start_buf));

    const submissions = try arena.alloc(Submission, plans.len);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (plans, submissions) |p, *s| {
        s.* = .{ .row = p.row, .outcome = .{ .failed = .{ .reason = .transport } } };
        if (p.policy) |pol| {
            if (pol.ticket_required) {
                s.outcome = .{ .failed = .{ .reason = .ticket_required } };
                continue;
            }
            if (pol.justification_required and justification.len == 0) {
                s.outcome = .{ .failed = .{ .reason = .justification_required } };
                continue;
            }
        }
        const iso = try arena.create([16]u8);
        group.async(io, submitOne, .{ &client, arena, io, s, dto.ScheduleRequest{
            .principal_id = principal_id,
            .role_definition_id = p.row.eligibility.role_definition_id,
            .eligibility_schedule_id = p.row.eligibility.schedule_id,
            .request_type = .SelfActivate,
            .justification = justification,
            .start = start,
            .duration_iso = duration.formatIso(p.duration.minutes, iso),
        } });
    }
    try group.await(io);
    return submissions;
}

pub fn deactivate(session: *Session, arena: std.mem.Allocator, rows: []const Row, diag: *Diagnostics) Error![]Submission {
    const principal_id = try session.principalId(diag);
    const client = try session.client(diag);
    const io = session.env.io;

    const submissions = try arena.alloc(Submission, rows.len);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (rows, submissions) |row, *s| {
        s.* = .{ .row = row, .outcome = .{ .failed = .{ .reason = .transport } } };
        group.async(io, submitOne, .{ &client, arena, io, s, dto.ScheduleRequest{
            .principal_id = principal_id,
            .role_definition_id = row.eligibility.role_definition_id,
            .eligibility_schedule_id = row.eligibility.schedule_id,
            .request_type = .SelfDeactivate,
        } });
    }
    try group.await(io);
    return submissions;
}

fn submitOne(client: *const arm.Client, arena: std.mem.Allocator, io: std.Io, s: *Submission, request: dto.ScheduleRequest) void {
    var d: arm.Diagnostics = .{};
    const status = client.submitRequest(arena, io, s.row.eligibility.scope, request, &d) catch |err| {
        s.outcome = .{ .failed = if (err == error.HttpFailed)
            .{ .reason = .rejected, .arm = d }
        else
            .{ .reason = .transport, .detail = @errorName(err) } };
        return;
    };
    s.outcome = .{ .accepted = status };
}

pub const poll_interval_s = 3;

/// Polls current assignments until every automatically settling submission
/// reached the state `intent` aims for. Returns false on timeout.
pub fn awaitSettled(
    session: *Session,
    arena: std.mem.Allocator,
    submissions: []const Submission,
    intent: selection.Intent,
    timeout_s: i64,
    diag: *Diagnostics,
) (Error || arm.Error)!bool {
    const client = try session.client(diag);
    const io = session.env.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromSeconds(timeout_s));

    while (true) {
        const now = std.Io.Clock.real.now(io).toSeconds();
        const assignments = try client.listAssignments(arena, &diag.arm);
        if (try allSettled(arena, submissions, assignments, intent, now)) return true;
        if (std.Io.Clock.awake.now(io).toNanoseconds() >= deadline.toNanoseconds()) return false;
        try io.sleep(.fromSeconds(poll_interval_s), .awake);
    }
}

fn allSettled(
    arena: std.mem.Allocator,
    submissions: []const Submission,
    assignments: []const role.Assignment,
    intent: selection.Intent,
    now: i64,
) std.mem.Allocator.Error!bool {
    var active: std.StringHashMapUnmanaged(void) = .empty;
    for (assignments) |a| {
        if (a.kind != .activated) continue;
        if (a.ends_at) |end| if (end <= now) continue;
        try active.put(arena, try rows_mod.roleKey(arena, a.scope, a.role_definition_id), {});
    }
    for (submissions) |s| {
        if (!s.settlesAutomatically()) continue;
        const e = s.row.eligibility;
        const is_active = active.contains(try rows_mod.roleKey(arena, e.scope, e.role_definition_id));
        if (is_active != (intent == .activate)) return false;
    }
    return true;
}

const testing = std.testing;

fn testRow(scope: []const u8) Row {
    return .{
        .eligibility = .{ .schedule_id = "s", .scope = scope, .scope_name = "rg", .role_definition_id = "/x/roleDefinitions/R1", .role_name = "Owner" },
        .subscription_name = "Sub",
        .state = .eligible,
    };
}

test "allSettled waits for activations to appear" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const subs = [_]Submission{
        .{ .row = testRow("/subscriptions/s/resourceGroups/a"), .outcome = .{ .accepted = "Provisioned" } },
        .{ .row = testRow("/subscriptions/s/resourceGroups/b"), .outcome = .{ .accepted = "PendingApproval" } },
        .{ .row = testRow("/subscriptions/s/resourceGroups/c"), .outcome = .{ .failed = .{ .reason = .rejected } } },
    };
    const none = [_]role.Assignment{};
    const done = [_]role.Assignment{.{ .scope = "/SUBSCRIPTIONS/S/RESOURCEGROUPS/A", .role_definition_id = "r1", .kind = .activated, .ends_at = 2000 }};
    try testing.expect(!try allSettled(arena, &subs, &none, .activate, 1000));
    try testing.expect(try allSettled(arena, &subs, &done, .activate, 1000));
    try testing.expect(!try allSettled(arena, &subs, &done, .activate, 2000));
}

test "allSettled waits for deactivations to disappear" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const subs = [_]Submission{.{ .row = testRow("/subscriptions/s/resourceGroups/a"), .outcome = .{ .accepted = "Revoked" } }};
    const still = [_]role.Assignment{.{ .scope = "/subscriptions/s/resourceGroups/a", .role_definition_id = "r1", .kind = .activated }};
    try testing.expect(!try allSettled(arena, &subs, &still, .deactivate, 1000));
    try testing.expect(try allSettled(arena, &subs, &.{}, .deactivate, 1000));
}

test "plans without a readable policy ask for a justification" {
    const p: Plan = .{ .row = testRow("/s"), .policy = null, .duration = .{ .minutes = 60, .clamped = false } };
    try testing.expect(p.needsJustification());
    const relaxed: Plan = .{ .row = testRow("/s"), .policy = .{}, .duration = .{ .minutes = 60, .clamped = false } };
    try testing.expect(!relaxed.needsJustification());
}
