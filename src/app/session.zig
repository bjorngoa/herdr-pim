//! An authenticated ARM session. The token is fetched lazily so commands that
//! are served from cache never spawn `az`, and fetched at most once otherwise.
const std = @import("std");
const azcli = @import("../adapters/azcli.zig");
const arm = @import("../adapters/arm/client.zig");

pub const Env = struct {
    io: std.Io,
    /// Must be thread-safe; HTTP requests run concurrently.
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    state_dir: []const u8,
};

/// Details for the most recent failure, for user-facing messages.
pub const Diagnostics = struct {
    az: azcli.Diagnostics = .{},
    arm: arm.Diagnostics = .{},
};

/// Safe to share between threads: the token is fetched once under a mutex and
/// `std.http.Client` is thread-safe.
pub const Session = struct {
    /// Thread-safe allocator owning the token for the session's lifetime.
    arena: std.mem.Allocator,
    env: Env,
    http: std.http.Client,
    mutex: std.Io.Mutex = .init,
    token: ?azcli.Token = null,
    authorization: []const u8 = "",

    /// The session must not be moved after `client()` has been called.
    pub fn init(arena: std.mem.Allocator, env: Env) Session {
        return .{ .arena = arena, .env = env, .http = .{ .allocator = env.gpa, .io = env.io } };
    }

    pub fn deinit(self: *Session) void {
        self.http.deinit();
    }

    /// Returns a client with a valid token, fetching a new one from `az` on
    /// first use and shortly before the current one expires.
    pub fn client(self: *Session, diag: *Diagnostics) azcli.Error!arm.Client {
        self.mutex.lockUncancelable(self.env.io);
        defer self.mutex.unlock(self.env.io);
        if (needsToken(self.token, std.Io.Clock.real.now(self.env.io).toSeconds())) {
            const token = try azcli.getToken(self.arena, self.env.io, self.env.environ, azcli.arm_resource, &diag.az);
            self.authorization = try std.fmt.allocPrint(self.arena, "Bearer {s}", .{token.value});
            self.token = token;
        }
        return .{ .http = &self.http, .authorization = self.authorization };
    }

    /// Object id of the signed-in user, needed for self-activation requests.
    pub fn principalId(self: *Session, diag: *Diagnostics) azcli.Error![]const u8 {
        _ = try self.client(diag);
        return azcli.objectId(self.arena, self.token.?.value);
    }
};

/// Tokens are replaced this long before they expire, so a request never
/// starts with a token that lapses mid-flight.
const refresh_margin_s = 2 * 60;

fn needsToken(token: ?azcli.Token, now: i64) bool {
    const current = token orelse return true;
    return now >= current.expires_at - refresh_margin_s;
}

const testing = std.testing;

test "needsToken fetches on first use and shortly before expiry" {
    try testing.expect(needsToken(null, 0));
    const token: azcli.Token = .{ .value = "t", .expires_at = 10_000 };
    try testing.expect(!needsToken(token, 10_000 - refresh_margin_s - 1));
    try testing.expect(needsToken(token, 10_000 - refresh_margin_s));
    try testing.expect(needsToken(token, 20_000));
}
