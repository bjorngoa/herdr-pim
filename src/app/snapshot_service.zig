//! Obtains a PIM `Snapshot`: from the cache when fresh enough, otherwise from
//! Azure, fetching the four ARM collections concurrently.
const std = @import("std");
const role = @import("../domain/role.zig");
const azcli = @import("../adapters/azcli.zig");
const arm = @import("../adapters/arm/client.zig");
const cache = @import("../adapters/snapshot_cache.zig");
const session_mod = @import("session.zig");

const Session = session_mod.Session;
const Diagnostics = session_mod.Diagnostics;

const log = std.log.scoped(.snapshot);

pub const FetchError = azcli.Error || arm.Error || std.Io.Cancelable;
pub const GetError = FetchError || error{NoCachedSnapshot};

pub const Policy = struct {
    /// Cached snapshots younger than this are used without a network call.
    max_age_s: i64,
    /// Always fetch, ignoring the cache age.
    force: bool = false,
    /// Never fetch; any cached snapshot is used regardless of age.
    offline: bool = false,
    /// Return a stale cached snapshot when fetching fails.
    stale_on_error: bool = false,
};

pub const Source = enum { cache, network, stale_cache };

pub const Result = struct {
    snapshot: role.Snapshot,
    source: Source,
};

/// Results are owned by `arena`, which must be thread-safe.
pub fn get(session: *Session, arena: std.mem.Allocator, now: i64, policy: Policy, diag: *Diagnostics) GetError!Result {
    const cached = cache.load(arena, session.env.io, session.env.state_dir);
    if (policy.offline) {
        const snapshot = cached orelse return error.NoCachedSnapshot;
        return .{ .snapshot = snapshot, .source = .cache };
    }
    if (isFresh(cached, now, policy)) return .{ .snapshot = cached.?, .source = .cache };

    const fresh = refresh(session, arena, now, diag) catch |err| {
        if (policy.stale_on_error) if (cached) |snapshot| {
            log.warn("refresh failed ({t}); using cached data", .{err});
            return .{ .snapshot = snapshot, .source = .stale_cache };
        };
        return err;
    };
    return .{ .snapshot = fresh, .source = .network };
}

/// Fetches from Azure and updates the cache. Results are owned by `arena`,
/// which must be thread-safe.
pub fn refresh(session: *Session, arena: std.mem.Allocator, now: i64, diag: *Diagnostics) FetchError!role.Snapshot {
    const snapshot = try fetch(session, arena, now, diag);
    cache.save(session.env.io, session.env.state_dir, snapshot) catch |err| log.warn("cannot write cache: {t}", .{err});
    return snapshot;
}

/// Loads the cached snapshot without any network access.
pub fn loadCached(session: *Session, arena: std.mem.Allocator) ?role.Snapshot {
    return cache.load(arena, session.env.io, session.env.state_dir);
}

fn fetch(session: *Session, arena: std.mem.Allocator, now: i64, diag: *Diagnostics) FetchError!role.Snapshot {
    const client = try session.client(diag);
    const io = session.env.io;

    var diags: [4]arm.Diagnostics = @splat(.{});
    var eligibilities = io.async(arm.Client.listEligibilities, .{ &client, arena, &diags[0] });
    defer discard(&eligibilities, io);
    var assignments = io.async(arm.Client.listAssignments, .{ &client, arena, &diags[1] });
    defer discard(&assignments, io);
    var requests = io.async(arm.Client.listRequests, .{ &client, arena, &diags[2] });
    defer discard(&requests, io);
    var subscriptions = io.async(arm.Client.listSubscriptions, .{ &client, arena, &diags[3] });
    defer discard(&subscriptions, io);

    return .{
        .fetched_at = now,
        .eligibilities = try awaitInto(&eligibilities, io, &diags[0], diag),
        .assignments = try awaitInto(&assignments, io, &diags[1], diag),
        .requests = try awaitInto(&requests, io, &diags[2], diag),
        .subscriptions = try awaitInto(&subscriptions, io, &diags[3], diag),
    };
}

fn isFresh(cached: ?role.Snapshot, now: i64, policy: Policy) bool {
    if (policy.force) return false;
    const snapshot = cached orelse return false;
    const age = now - snapshot.fetched_at;
    return age >= 0 and age < policy.max_age_s;
}

fn awaitInto(future: anytype, io: std.Io, task_diag: *const arm.Diagnostics, diag: *Diagnostics) @TypeOf(future.result) {
    return future.await(io) catch |err| {
        diag.arm = task_diag.*;
        return err;
    };
}

fn discard(future: anytype, io: std.Io) void {
    if (future.cancel(io)) |_| {} else |_| {}
}

const testing = std.testing;

test "isFresh honours age, clock skew and force" {
    const snapshot: role.Snapshot = .{
        .fetched_at = 1000,
        .eligibilities = &.{},
        .assignments = &.{},
        .requests = &.{},
        .subscriptions = &.{},
    };
    try testing.expect(isFresh(snapshot, 1059, .{ .max_age_s = 60 }));
    try testing.expect(!isFresh(snapshot, 1060, .{ .max_age_s = 60 }));
    try testing.expect(!isFresh(snapshot, 999, .{ .max_age_s = 60 }));
    try testing.expect(!isFresh(snapshot, 1001, .{ .max_age_s = 60, .force = true }));
    try testing.expect(!isFresh(null, 1000, .{ .max_age_s = 60 }));
}
