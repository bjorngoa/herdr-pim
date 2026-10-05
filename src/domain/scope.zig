//! Azure Resource Manager scopes, e.g.
//! `/subscriptions/{id}/resourceGroups/{name}/providers/{ns}/{type}/{name}`.
//! ARM treats scope paths case-insensitively, so all comparisons here do too.
const std = @import("std");

pub const Kind = enum { management_group, subscription, resource_group, resource };

pub const ParseError = error{InvalidScope};

pub const Scope = struct {
    kind: Kind,
    /// Empty for management-group scopes.
    subscription_id: []const u8,
    /// Empty unless `kind` is `resource_group` or `resource`.
    resource_group: []const u8,
    /// Last path segment: management group, subscription, resource group or resource name.
    leaf_name: []const u8,

    /// Parses an ARM scope path. Returned slices borrow from `path`.
    pub fn parse(path: []const u8) ParseError!Scope {
        var it = std.mem.tokenizeScalar(u8, path, '/');
        const first = it.next() orelse return error.InvalidScope;

        if (std.ascii.eqlIgnoreCase(first, "providers")) {
            const ns = it.next() orelse return error.InvalidScope;
            const kind = it.next() orelse return error.InvalidScope;
            const name = it.next() orelse return error.InvalidScope;
            if (!std.ascii.eqlIgnoreCase(ns, "Microsoft.Management") or
                !std.ascii.eqlIgnoreCase(kind, "managementGroups") or it.next() != null)
                return error.InvalidScope;
            return .{ .kind = .management_group, .subscription_id = "", .resource_group = "", .leaf_name = name };
        }

        if (!std.ascii.eqlIgnoreCase(first, "subscriptions")) return error.InvalidScope;
        const subscription_id = it.next() orelse return error.InvalidScope;
        const rg_keyword = it.next() orelse
            return .{ .kind = .subscription, .subscription_id = subscription_id, .resource_group = "", .leaf_name = subscription_id };
        if (!std.ascii.eqlIgnoreCase(rg_keyword, "resourceGroups")) return error.InvalidScope;
        const resource_group = it.next() orelse return error.InvalidScope;

        var leaf = resource_group;
        var kind: Kind = .resource_group;
        if (it.next()) |providers| {
            if (!std.ascii.eqlIgnoreCase(providers, "providers")) return error.InvalidScope;
            var segments: usize = 0;
            while (it.next()) |segment| : (segments += 1) leaf = segment;
            // Namespace + at least one type/name pair.
            if (segments < 3 or segments % 2 == 0) return error.InvalidScope;
            kind = .resource;
        }
        return .{ .kind = kind, .subscription_id = subscription_id, .resource_group = resource_group, .leaf_name = leaf };
    }
};

/// Returns the final segment of an ARM id, e.g. the GUID of a role definition id.
pub fn lastSegment(id: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, id, "/");
    const idx = std.mem.findScalarLast(u8, trimmed, '/') orelse return trimmed;
    return trimmed[idx + 1 ..];
}

const testing = std.testing;

test "parse subscription and resource group scopes" {
    const sub = try Scope.parse("/subscriptions/abc");
    try testing.expectEqual(Kind.subscription, sub.kind);
    try testing.expectEqualStrings("abc", sub.subscription_id);
    try testing.expectEqualStrings("abc", sub.leaf_name);

    const rg = try Scope.parse("/SUBSCRIPTIONS/abc/RESOURCEGROUPS/RG-One");
    try testing.expectEqual(Kind.resource_group, rg.kind);
    try testing.expectEqualStrings("abc", rg.subscription_id);
    try testing.expectEqualStrings("RG-One", rg.resource_group);
    try testing.expectEqualStrings("RG-One", rg.leaf_name);
}

test "parse resource and management group scopes" {
    const res = try Scope.parse("/subscriptions/abc/resourceGroups/rg/providers/microsoft.insights/components/appi");
    try testing.expectEqual(Kind.resource, res.kind);
    try testing.expectEqualStrings("rg", res.resource_group);
    try testing.expectEqualStrings("appi", res.leaf_name);

    const mg = try Scope.parse("/providers/Microsoft.Management/managementGroups/root");
    try testing.expectEqual(Kind.management_group, mg.kind);
    try testing.expectEqualStrings("root", mg.leaf_name);
}

test "parse rejects malformed scopes" {
    const bad = [_][]const u8{
        "",
        "/",
        "/subscriptions",
        "/subscriptions/abc/resourceGroups",
        "/subscriptions/abc/locks/x",
        "/subscriptions/abc/resourceGroups/rg/providers/ns",
        "/subscriptions/abc/resourceGroups/rg/providers/ns/type",
        "/providers/Microsoft.Management/managementGroups",
        "/tenants/abc",
    };
    for (bad) |s| try testing.expectError(error.InvalidScope, Scope.parse(s));
}

test "lastSegment returns the trailing id" {
    try testing.expectEqualStrings("b24988ac", lastSegment("/subscriptions/x/providers/Microsoft.Authorization/roleDefinitions/b24988ac"));
    try testing.expectEqualStrings("id", lastSegment("/a/id/"));
    try testing.expectEqualStrings("plain", lastSegment("plain"));
}
