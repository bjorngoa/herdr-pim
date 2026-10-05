//! PIM facts as fetched from Azure. All slices are borrowed; whoever builds a
//! `Snapshot` owns the backing memory (typically an arena).
const std = @import("std");

/// A role the user may activate through PIM (directly or via a group).
pub const Eligibility = struct {
    /// Full ARM id of the eligibility schedule; links activation requests to it.
    schedule_id: []const u8,
    scope: []const u8,
    scope_name: []const u8,
    role_definition_id: []const u8,
    role_name: []const u8,
    ends_at: ?i64 = null,
};

pub const AssignmentKind = enum {
    /// Time-bound assignment created by a PIM activation.
    activated,
    /// Standing assignment that does not need activation.
    assigned,
};

/// A role the user currently holds.
pub const Assignment = struct {
    scope: []const u8,
    role_definition_id: []const u8,
    kind: AssignmentKind,
    ends_at: ?i64 = null,
};

/// A self-activation request, possibly still being processed or awaiting approval.
pub const Request = struct {
    scope: []const u8,
    role_definition_id: []const u8,
    status: []const u8,
    created_at: i64,

    /// Requests older than this are never considered in flight.
    pub const max_in_flight_age_s: i64 = 24 * 3600;

    /// True when Azure has accepted the request but not yet provisioned or rejected it.
    pub fn isInFlight(self: Request, now: i64) bool {
        if (now - self.created_at > max_in_flight_age_s) return false;
        if (std.mem.startsWith(u8, self.status, "Pending")) return true;
        const in_flight = [_][]const u8{ "Accepted", "Granted", "AdminApproved", "ProvisioningStarted", "ScheduleCreated" };
        for (in_flight) |s| if (std.mem.eql(u8, self.status, s)) return true;
        return false;
    }

    /// True for statuses that wait on a human approver.
    pub fn awaitsApproval(status: []const u8) bool {
        return std.mem.startsWith(u8, status, "PendingApproval") or std.mem.eql(u8, status, "PendingAdminDecision");
    }
};

pub const Subscription = struct {
    id: []const u8,
    name: []const u8,
};

pub const Snapshot = struct {
    /// Bump when the serialized shape changes so stale caches are discarded.
    pub const schema_version: u32 = 1;

    version: u32 = schema_version,
    fetched_at: i64,
    eligibilities: []const Eligibility,
    assignments: []const Assignment,
    requests: []const Request,
    subscriptions: []const Subscription,
};

const testing = std.testing;

test "isInFlight recognises pending and transitional statuses" {
    const now: i64 = 1_000_000;
    const r = struct {
        fn make(status: []const u8, created_at: i64) Request {
            return .{ .scope = "/s", .role_definition_id = "r", .status = status, .created_at = created_at };
        }
    }.make;
    try testing.expect(r("PendingApproval", now - 60).isInFlight(now));
    try testing.expect(r("PendingProvisioning", now).isInFlight(now));
    try testing.expect(r("Granted", now).isInFlight(now));
    try testing.expect(!r("Provisioned", now).isInFlight(now));
    try testing.expect(!r("Denied", now).isInFlight(now));
    try testing.expect(!r("PendingApproval", now - Request.max_in_flight_age_s - 1).isInFlight(now));
}

test "awaitsApproval only for approver-bound statuses" {
    try testing.expect(Request.awaitsApproval("PendingApproval"));
    try testing.expect(Request.awaitsApproval("PendingApprovalProvisioning"));
    try testing.expect(Request.awaitsApproval("PendingAdminDecision"));
    try testing.expect(!Request.awaitsApproval("PendingProvisioning"));
    try testing.expect(!Request.awaitsApproval("Provisioned"));
}
