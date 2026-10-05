//! Human-readable outcome and failure messages shared by the CLI and the TUI.
const std = @import("std");
const role = @import("../domain/role.zig");
const rows_mod = @import("../domain/rows.zig");
const selection = @import("../domain/selection.zig");
const time = @import("../domain/time.zig");
const activation = @import("../app/activation.zig");
const alerts = @import("../domain/alerts.zig");
const text = @import("text.zig");

const Row = rows_mod.Row;

pub const Kind = enum { ok, pending, failed, info };

pub const Line = struct {
    kind: Kind,
    glyph: []const u8,
    text: []const u8,
};

/// `Contributor on rg-x (Subscription)`, sanitized for terminal output.
pub fn label(arena: std.mem.Allocator, row: Row) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s} on {s} ({s})", .{
        try text.sanitize(arena, row.eligibility.role_name),
        try text.sanitize(arena, row.eligibility.scope_name),
        try text.sanitize(arena, row.subscription_name),
    });
}

/// Describes what happened to one submission, using `final` (the row after a
/// refresh, if available) to tell whether the change has taken effect.
pub fn describeOutcome(
    arena: std.mem.Allocator,
    s: activation.Submission,
    intent: selection.Intent,
    final: ?Row,
    now: i64,
) std.mem.Allocator.Error!Line {
    const name = try label(arena, s.row);
    switch (s.outcome) {
        .failed => |f| return .{
            .kind = .failed,
            .glyph = "✗",
            .text = try std.fmt.allocPrint(arena, "{s}: {s}", .{ name, try describeFailure(arena, f) }),
        },
        .accepted => |azure_status| {
            if (role.Request.awaitsApproval(azure_status)) return .{
                .kind = .pending,
                .glyph = "◐",
                .text = try std.fmt.allocPrint(arena, "{s}: awaiting approval", .{name}),
            };
            const is_active: ?bool = if (final) |r| r.state == .active else null;
            if (intent == .activate and is_active == true) {
                var buf: [16]u8 = undefined;
                const msg = if (final.?.active_until) |end|
                    try std.fmt.allocPrint(arena, "{s}: active, {s} left", .{ name, time.formatRemaining(end - now, &buf) })
                else
                    try std.fmt.allocPrint(arena, "{s}: active", .{name});
                return .{ .kind = .ok, .glyph = "●", .text = msg };
            }
            if (intent == .deactivate and is_active == false) return .{
                .kind = .ok,
                .glyph = "○",
                .text = try std.fmt.allocPrint(arena, "{s}: deactivated", .{name}),
            };
            return .{
                .kind = .pending,
                .glyph = "◐",
                .text = try std.fmt.allocPrint(arena, "{s}: requested ({s}), not applied yet", .{ name, try text.sanitize(arena, azure_status) }),
            };
        },
    }
}

pub fn describeFailure(arena: std.mem.Allocator, f: activation.Failure) std.mem.Allocator.Error![]const u8 {
    switch (f.reason) {
        .justification_required => return "a justification is required",
        .ticket_required => return "the policy requires a ticket number, which pim does not support yet; use the Azure portal",
        .transport => return std.fmt.allocPrint(arena, "could not reach Azure ({s})", .{f.detail}),
        .rejected => {},
    }
    const code = f.arm.code;
    const message = try text.sanitize(arena, f.arm.message);
    const known = [_]struct { []const u8, []const u8 }{
        .{ "RoleAssignmentExists", "already active" },
        .{ "RoleAssignmentDoesNotExist", "not active" },
        .{ "ActiveDurationTooShort", "Azure only allows deactivation 5 minutes after activation" },
        .{ "RoleAssignmentRequestAcrsValidationFailed", "needs a stronger sign-in (MFA / Conditional Access); run `az logout`, `az login`, then retry" },
    };
    for (known) |k| if (std.mem.eql(u8, code, k[0])) return k[1];
    if (std.mem.eql(u8, code, "RoleAssignmentRequestPolicyValidationFailed"))
        return std.fmt.allocPrint(arena, "rejected by the PIM policy: {s}", .{message});
    const http_status: u16 = if (f.arm.status) |st| @intFromEnum(st) else 0;
    const safe_code = try text.sanitize(arena, code);
    if (message.len == 0) return std.fmt.allocPrint(arena, "Azure returned HTTP {d} {s}", .{ http_status, safe_code });
    return std.fmt.allocPrint(arena, "Azure returned HTTP {d} {s}: {s}", .{ http_status, safe_code, message });
}

pub const Notification = struct {
    title: []const u8,
    body: []const u8,
};

pub fn describeAlert(arena: std.mem.Allocator, alert: alerts.Alert, now: i64) std.mem.Allocator.Error!Notification {
    const name = try label(arena, alert.row);
    var buf: [16]u8 = undefined;
    const left = if (alert.row.active_until) |until| time.formatRemaining(until - now, &buf) else "";
    return switch (alert.kind) {
        .expiring => .{ .title = "PIM role expiring", .body = try std.fmt.allocPrint(arena, "{s} expires in {s}", .{ name, left }) },
        .expired => .{ .title = "PIM role expired", .body = name },
        .activated => .{
            .title = "PIM role active",
            .body = if (left.len > 0) try std.fmt.allocPrint(arena, "{s}, {s} left", .{ name, left }) else name,
        },
    };
}

/// The row for the same eligibility in `rows`, if present.
pub fn findRow(rows: []const Row, target: Row) ?Row {
    for (rows) |r| if (std.ascii.eqlIgnoreCase(r.eligibility.schedule_id, target.eligibility.schedule_id)) return r;
    return null;
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

test "describeOutcome reflects the refreshed state" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const submitted: activation.Submission = .{ .row = testRow("/a", .eligible, null), .outcome = .{ .accepted = "Provisioned" } };

    const active = try describeOutcome(arena, submitted, .activate, testRow("/a", .active, 3600), 0);
    try testing.expectEqual(Kind.ok, active.kind);
    try testing.expectEqualStrings("Owner on rg (Sub): active, 1h00m left", active.text);

    const not_yet = try describeOutcome(arena, submitted, .activate, testRow("/a", .eligible, null), 0);
    try testing.expectEqual(Kind.pending, not_yet.kind);

    const gone = try describeOutcome(arena, submitted, .deactivate, testRow("/a", .eligible, null), 0);
    try testing.expectEqualStrings("○", gone.glyph);

    const approval: activation.Submission = .{ .row = testRow("/a", .eligible, null), .outcome = .{ .accepted = "PendingApproval" } };
    try testing.expectEqualStrings("Owner on rg (Sub): awaiting approval", (try describeOutcome(arena, approval, .activate, null, 0)).text);
}

test "describeFailure translates known ARM codes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("already active", try describeFailure(arena, .{ .reason = .rejected, .arm = .{ .code = "RoleAssignmentExists" } }));
    try testing.expectEqualStrings(
        "rejected by the PIM policy: The following policy rules failed: [\"ExpirationRule\"]",
        try describeFailure(arena, .{ .reason = .rejected, .arm = .{ .code = "RoleAssignmentRequestPolicyValidationFailed", .message = "The following policy rules failed: [\"ExpirationRule\"]" } }),
    );
    try testing.expectEqualStrings(
        "Azure returned HTTP 403 AuthorizationFailed: nope",
        try describeFailure(arena, .{ .reason = .rejected, .arm = .{ .status = .forbidden, .code = "AuthorizationFailed", .message = "nope" } }),
    );
}

test "describeAlert words each alert kind" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const row = testRow("/a", .active, 600);
    try testing.expectEqualStrings("Owner on rg (Sub) expires in 10m", (try describeAlert(arena, .{ .kind = .expiring, .row = row }, 0)).body);
    try testing.expectEqualStrings("PIM role expired", (try describeAlert(arena, .{ .kind = .expired, .row = testRow("/a", .eligible, null) }, 0)).title);
    try testing.expectEqualStrings("Owner on rg (Sub), 10m left", (try describeAlert(arena, .{ .kind = .activated, .row = row }, 0)).body);
}

test "findRow matches by eligibility schedule id" {
    const rows = [_]Row{ testRow("/A", .eligible, null), testRow("/b", .active, null) };
    try testing.expectEqual(rows_mod.State.active, findRow(&rows, testRow("/B", .eligible, null)).?.state);
    try testing.expect(findRow(&rows, testRow("/c", .eligible, null)) == null);
}
