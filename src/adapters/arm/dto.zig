//! Wire formats of the ARM PIM and subscription APIs, and their conversion to
//! domain types. Results borrow from both `arena` and the response body.
const std = @import("std");
const role = @import("../../domain/role.zig");
const policy_mod = @import("../../domain/policy.zig");
const duration = @import("../../domain/duration.zig");
const scope_mod = @import("../../domain/scope.zig");
const time = @import("../../domain/time.zig");

pub const ParseError = error{InvalidResponse} || std.mem.Allocator.Error;

pub fn Page(comptime T: type) type {
    return struct {
        items: []T,
        next_link: ?[]const u8,
    };
}

const DisplayRef = struct { displayName: ?[]const u8 = null };

const Expanded = struct {
    roleDefinition: ?DisplayRef = null,
    scope: ?DisplayRef = null,
};

const EligibilityProps = struct {
    roleEligibilityScheduleId: []const u8,
    scope: []const u8,
    roleDefinitionId: []const u8,
    endDateTime: ?[]const u8 = null,
    expandedProperties: ?Expanded = null,
};

const AssignmentProps = struct {
    scope: []const u8,
    roleDefinitionId: []const u8,
    assignmentType: ?[]const u8 = null,
    endDateTime: ?[]const u8 = null,
};

const RequestProps = struct {
    scope: []const u8,
    roleDefinitionId: []const u8,
    requestType: []const u8,
    status: []const u8,
    createdOn: []const u8,
};

const SubscriptionDto = struct {
    subscriptionId: []const u8,
    displayName: []const u8,
};

fn ArmList(comptime Item: type) type {
    return struct {
        value: []const Item,
        nextLink: ?[]const u8 = null,
    };
}

fn WithProperties(comptime Props: type) type {
    return struct { properties: Props };
}

fn parseList(comptime Item: type, arena: std.mem.Allocator, body: []const u8) ParseError!ArmList(Item) {
    return std.json.parseFromSliceLeaky(ArmList(Item), arena, body, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidResponse,
    };
}

fn optionalTime(s: ?[]const u8) ParseError!?i64 {
    const value = s orelse return null;
    return time.parseRfc3339(value) catch error.InvalidResponse;
}

fn scopeDisplayName(scope: []const u8, expanded: ?Expanded) []const u8 {
    if (expanded) |e| if (e.scope) |s| if (s.displayName) |name| return name;
    const parsed = scope_mod.Scope.parse(scope) catch return scope;
    return parsed.leaf_name;
}

fn roleDisplayName(role_definition_id: []const u8, expanded: ?Expanded) []const u8 {
    if (expanded) |e| if (e.roleDefinition) |r| if (r.displayName) |name| return name;
    return scope_mod.lastSegment(role_definition_id);
}

pub fn parseEligibilities(arena: std.mem.Allocator, body: []const u8) ParseError!Page(role.Eligibility) {
    const list = try parseList(WithProperties(EligibilityProps), arena, body);
    const items = try arena.alloc(role.Eligibility, list.value.len);
    for (list.value, items) |src, *dst| {
        const p = src.properties;
        dst.* = .{
            .schedule_id = p.roleEligibilityScheduleId,
            .scope = p.scope,
            .scope_name = scopeDisplayName(p.scope, p.expandedProperties),
            .role_definition_id = p.roleDefinitionId,
            .role_name = roleDisplayName(p.roleDefinitionId, p.expandedProperties),
            .ends_at = try optionalTime(p.endDateTime),
        };
    }
    return .{ .items = items, .next_link = list.nextLink };
}

pub fn parseAssignments(arena: std.mem.Allocator, body: []const u8) ParseError!Page(role.Assignment) {
    const list = try parseList(WithProperties(AssignmentProps), arena, body);
    const items = try arena.alloc(role.Assignment, list.value.len);
    for (list.value, items) |src, *dst| {
        const p = src.properties;
        const activated = if (p.assignmentType) |t| std.ascii.eqlIgnoreCase(t, "Activated") else false;
        dst.* = .{
            .scope = p.scope,
            .role_definition_id = p.roleDefinitionId,
            .kind = if (activated) .activated else .assigned,
            .ends_at = try optionalTime(p.endDateTime),
        };
    }
    return .{ .items = items, .next_link = list.nextLink };
}

/// Only self-activation requests are kept; other request types do not affect row state.
pub fn parseRequests(arena: std.mem.Allocator, body: []const u8) ParseError!Page(role.Request) {
    const list = try parseList(WithProperties(RequestProps), arena, body);
    var items: std.ArrayList(role.Request) = .empty;
    for (list.value) |src| {
        const p = src.properties;
        if (!std.ascii.eqlIgnoreCase(p.requestType, "SelfActivate")) continue;
        try items.append(arena, .{
            .scope = p.scope,
            .role_definition_id = p.roleDefinitionId,
            .status = p.status,
            .created_at = time.parseRfc3339(p.createdOn) catch return error.InvalidResponse,
        });
    }
    return .{ .items = try items.toOwnedSlice(arena), .next_link = list.nextLink };
}

pub fn parseSubscriptions(arena: std.mem.Allocator, body: []const u8) ParseError!Page(role.Subscription) {
    const list = try parseList(SubscriptionDto, arena, body);
    const items = try arena.alloc(role.Subscription, list.value.len);
    for (list.value, items) |src, *dst| dst.* = .{ .id = src.subscriptionId, .name = src.displayName };
    return .{ .items = items, .next_link = list.nextLink };
}

pub const ErrorBody = struct {
    code: []const u8 = "",
    message: []const u8 = "",
};

/// Extracts `{"error":{"code","message"}}` from an ARM error response, if present.
pub fn parseError(arena: std.mem.Allocator, body: []const u8) ErrorBody {
    const Envelope = struct { @"error": ?ErrorBody = null };
    const env = std.json.parseFromSliceLeaky(Envelope, arena, body, .{ .ignore_unknown_fields = true }) catch return .{};
    return env.@"error" orelse .{};
}

const PolicyRule = struct {
    id: []const u8,
    maximumDuration: ?[]const u8 = null,
    enabledRules: ?[]const []const u8 = null,
    setting: ?struct { isApprovalRequired: ?bool = null } = null,
    isEnabled: ?bool = null,
    claimValue: ?[]const u8 = null,
};

const PolicyAssignmentProps = struct {
    effectiveRules: []const PolicyRule = &.{},
};

/// Reads the end-user activation rules from a `roleManagementPolicyAssignments`
/// list. Returns null when no policy is assigned. Unknown rules are ignored.
pub fn parsePolicy(arena: std.mem.Allocator, body: []const u8) ParseError!?policy_mod.Policy {
    const list = try parseList(WithProperties(PolicyAssignmentProps), arena, body);
    if (list.value.len == 0) return null;

    var p: policy_mod.Policy = .{};
    for (list.value[0].properties.effectiveRules) |rule| {
        if (std.mem.eql(u8, rule.id, "Expiration_EndUser_Assignment")) {
            if (rule.maximumDuration) |d| p.max_duration_min = duration.parse(d) catch null;
        } else if (std.mem.eql(u8, rule.id, "Enablement_EndUser_Assignment")) {
            for (rule.enabledRules orelse &.{}) |name| {
                if (std.mem.eql(u8, name, "Justification")) p.justification_required = true;
                if (std.mem.eql(u8, name, "Ticketing")) p.ticket_required = true;
                if (std.mem.eql(u8, name, "MultiFactorAuthentication")) p.mfa_required = true;
            }
        } else if (std.mem.eql(u8, rule.id, "Approval_EndUser_Assignment")) {
            if (rule.setting) |s| p.approval_required = s.isApprovalRequired orelse false;
        } else if (std.mem.eql(u8, rule.id, "AuthenticationContext_EndUser_Assignment")) {
            if (rule.isEnabled orelse false) if (rule.claimValue) |c| if (c.len > 0) {
                p.auth_context = c;
            };
        }
    }
    return p;
}

pub const RequestType = enum { SelfActivate, SelfDeactivate };

pub const ScheduleRequest = struct {
    principal_id: []const u8,
    role_definition_id: []const u8,
    eligibility_schedule_id: []const u8,
    request_type: RequestType,
    justification: []const u8 = "",
    /// Required for `SelfActivate`. Deactivation sends only principal, role
    /// and request type, as documented by Microsoft.
    start: ?[]const u8 = null,
    duration_iso: ?[]const u8 = null,
};

/// Serializes a `roleAssignmentScheduleRequests` PUT body.
pub fn writeScheduleRequest(w: *std.Io.Writer, req: ScheduleRequest) std.Io.Writer.Error!void {
    const Expiration = struct { type: []const u8, duration: []const u8 };
    const ScheduleInfo = struct { startDateTime: []const u8, expiration: Expiration };
    const Body = struct {
        properties: struct {
            principalId: []const u8,
            roleDefinitionId: []const u8,
            requestType: RequestType,
            linkedRoleEligibilityScheduleId: ?[]const u8,
            justification: ?[]const u8,
            scheduleInfo: ?ScheduleInfo,
        },
    };
    const activating = req.request_type == .SelfActivate;
    const schedule: ?ScheduleInfo = if (activating) .{
        .startDateTime = req.start.?,
        .expiration = .{ .type = "AfterDuration", .duration = req.duration_iso.? },
    } else null;
    const body: Body = .{ .properties = .{
        .principalId = req.principal_id,
        .roleDefinitionId = req.role_definition_id,
        .requestType = req.request_type,
        .linkedRoleEligibilityScheduleId = if (activating) req.eligibility_schedule_id else null,
        .justification = if (activating and req.justification.len > 0) req.justification else null,
        .scheduleInfo = schedule,
    } };
    try std.json.Stringify.value(body, .{ .emit_null_optional_fields = false }, w);
}

/// Returns `properties.status` of a schedule request response.
pub fn parseRequestStatus(arena: std.mem.Allocator, body: []const u8) ParseError![]const u8 {
    const Response = struct { properties: struct { status: []const u8 } };
    const parsed = std.json.parseFromSliceLeaky(Response, arena, body, .{ .ignore_unknown_fields = true }) catch |err|
        return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidResponse;
    return parsed.properties.status;
}

const testing = std.testing;

test "parseEligibilities maps fixture fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const page = try parseEligibilities(arena_state.allocator(), @embedFile("testdata/eligibility_instances.json"));

    try testing.expectEqual(@as(usize, 3), page.items.len);
    try testing.expect(page.next_link == null);
    const first = page.items[0];
    try testing.expectEqualStrings("rg-example-1", first.scope_name);
    try testing.expectEqualStrings("Contributor", first.role_name);
    try testing.expectEqualStrings("/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-example-1", first.scope);
    try testing.expect(std.mem.endsWith(u8, first.schedule_id, "/roleEligibilitySchedules/00000000-0000-0000-0000-000000000002"));
    try testing.expectEqual(@as(?i64, 1820386673), first.ends_at);
    try testing.expectEqualStrings("Example Subscription C", page.items[2].scope_name);
}

test "parseAssignments distinguishes activated from standing assignments" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const page = try parseAssignments(arena_state.allocator(), @embedFile("testdata/assignment_instances.json"));

    try testing.expectEqual(@as(usize, 2), page.items.len);
    try testing.expectEqual(role.AssignmentKind.assigned, page.items[0].kind);
    try testing.expect(page.items[0].ends_at == null);
    try testing.expectEqual(role.AssignmentKind.activated, page.items[1].kind);
    try testing.expectEqual(try time.parseRfc3339("2026-10-03T16:00:00Z"), page.items[1].ends_at.?);
}

test "parseRequests keeps self-activations with status" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const page = try parseRequests(arena_state.allocator(), @embedFile("testdata/assignment_requests.json"));

    try testing.expectEqual(@as(usize, 2), page.items.len);
    try testing.expectEqualStrings("Provisioned", page.items[0].status);
    try testing.expectEqualStrings("PendingApproval", page.items[1].status);
}

test "parseSubscriptions maps ids to names" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const page = try parseSubscriptions(arena_state.allocator(), @embedFile("testdata/subscriptions.json"));
    try testing.expectEqual(@as(usize, 3), page.items.len);
    try testing.expectEqualStrings("Example Subscription A", page.items[0].name);
}

test "parsers reject malformed bodies and follow nextLink" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidResponse, parseEligibilities(arena, "not json"));
    try testing.expectError(error.InvalidResponse, parseAssignments(arena, "{\"value\":[{\"properties\":{}}]}"));
    try testing.expectError(error.InvalidResponse, parseAssignments(arena,
        \\{"value":[{"properties":{"scope":"/subscriptions/s","roleDefinitionId":"r","endDateTime":"soon"}}]}
    ));
    const page = try parseSubscriptions(arena,
        \\{"value":[],"nextLink":"https://management.azure.com/subscriptions?page=2"}
    );
    try testing.expectEqualStrings("https://management.azure.com/subscriptions?page=2", page.next_link.?);
}

test "fallback names come from the scope and role definition ids" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const page = try parseEligibilities(arena_state.allocator(),
        \\{"value":[{"properties":{"roleEligibilityScheduleId":"x","scope":"/subscriptions/s/resourceGroups/rg-x",
        \\"roleDefinitionId":"/providers/Microsoft.Authorization/roleDefinitions/abc","expandedProperties":null}}]}
    );
    try testing.expectEqualStrings("rg-x", page.items[0].scope_name);
    try testing.expectEqualStrings("abc", page.items[0].role_name);
    try testing.expect(page.items[0].ends_at == null);
}

test "parseError extracts ARM error details" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const e = parseError(arena,
        \\{"error":{"code":"InvalidAuthenticationToken","message":"The access token is invalid."}}
    );
    try testing.expectEqualStrings("InvalidAuthenticationToken", e.code);
    try testing.expectEqualStrings("The access token is invalid.", e.message);
    try testing.expectEqualStrings("", parseError(arena, "<html>").code);
}

test "parsePolicy reads end-user activation rules only" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = (try parsePolicy(arena, @embedFile("testdata/policy_assignments.json"))).?;
    try testing.expectEqual(@as(?u32, 240), p.max_duration_min);
    try testing.expect(p.justification_required);
    try testing.expect(p.mfa_required);
    try testing.expect(!p.ticket_required);
    try testing.expect(!p.approval_required);
    try testing.expect(p.auth_context == null);
    try testing.expect((try parsePolicy(arena, "{\"value\":[]}")) == null);
}

test "parsePolicy captures approval and authentication context" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const p = (try parsePolicy(arena_state.allocator(),
        \\{"value":[{"properties":{"effectiveRules":[
        \\{"id":"Approval_EndUser_Assignment","setting":{"isApprovalRequired":true}},
        \\{"id":"AuthenticationContext_EndUser_Assignment","isEnabled":true,"claimValue":"c1"},
        \\{"id":"Expiration_EndUser_Assignment","maximumDuration":"P1D"}]}}]}
    )).?;
    try testing.expect(p.approval_required);
    try testing.expectEqualStrings("c1", p.auth_context.?);
    try testing.expect(p.max_duration_min == null);
}

test "writeScheduleRequest builds activation and deactivation bodies" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeScheduleRequest(&out.writer, .{
        .principal_id = "p",
        .role_definition_id = "r",
        .eligibility_schedule_id = "e",
        .request_type = .SelfActivate,
        .justification = "fix \"prod\"",
        .start = "2026-10-03T20:00:00Z",
        .duration_iso = "PT8H",
    });
    try testing.expectEqualStrings(
        \\{"properties":{"principalId":"p","roleDefinitionId":"r","requestType":"SelfActivate","linkedRoleEligibilityScheduleId":"e","justification":"fix \"prod\"","scheduleInfo":{"startDateTime":"2026-10-03T20:00:00Z","expiration":{"type":"AfterDuration","duration":"PT8H"}}}}
    , out.written());

    out.clearRetainingCapacity();
    try writeScheduleRequest(&out.writer, .{ .principal_id = "p", .role_definition_id = "r", .eligibility_schedule_id = "e", .request_type = .SelfDeactivate });
    try testing.expectEqualStrings(
        \\{"properties":{"principalId":"p","roleDefinitionId":"r","requestType":"SelfDeactivate"}}
    , out.written());
}

test "parseRequestStatus reads the request state" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("PendingApproval", try parseRequestStatus(arena, "{\"properties\":{\"status\":\"PendingApproval\",\"x\":1}}"));
    try testing.expectError(error.InvalidResponse, parseRequestStatus(arena, "{}"));
}
