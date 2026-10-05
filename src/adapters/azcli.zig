//! Access tokens via the Azure CLI, reusing the user's `az login` session
//! (including MFA and conditional access). Tokens are never written to disk.
const std = @import("std");

pub const arm_resource = "https://management.azure.com/";

pub const Error = error{
    AzCliNotFound,
    /// `az` exited unsuccessfully (typically not logged in); see `Diagnostics`.
    AzCliFailed,
    InvalidResponse,
} || std.process.RunError || std.mem.Allocator.Error;

pub const Diagnostics = struct {
    stderr: []const u8 = "",
};

pub const Token = struct {
    /// Raw bearer token. Treat as secret: never log or persist.
    value: []const u8,
    expires_at: i64,
};

const timeout_s = 30;

/// Runs `az account get-access-token`. Azure CLI telemetry is disabled for
/// the child process. Result memory is owned by `arena`.
pub fn getToken(
    arena: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    resource: []const u8,
    diag: *Diagnostics,
) Error!Token {
    var child_env = try environ.clone(arena);
    try child_env.put("AZURE_CORE_COLLECT_TELEMETRY", "false");
    try child_env.put("AZURE_CORE_NO_COLOR", "true");

    const result = std.process.run(arena, io, .{
        .argv = &.{ "az", "account", "get-access-token", "--resource", resource, "--output", "json" },
        .environ_map = &child_env,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(timeout_s), .clock = .awake } },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.AzCliNotFound,
        else => |e| return e,
    };

    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        diag.stderr = std.mem.trim(u8, result.stderr, " \r\n");
        return error.AzCliFailed;
    }
    return parseToken(arena, result.stdout);
}

fn parseToken(arena: std.mem.Allocator, json: []const u8) Error!Token {
    const Response = struct {
        accessToken: []const u8,
        expires_on: i64,
    };
    const parsed = std.json.parseFromSliceLeaky(Response, arena, json, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    if (parsed.accessToken.len == 0) return error.InvalidResponse;
    return .{ .value = parsed.accessToken, .expires_at = parsed.expires_on };
}

/// Reads the `oid` (object id) claim from a JWT without verifying it. Only
/// used to address our own principal; ARM verifies the token itself.
pub fn objectId(arena: std.mem.Allocator, jwt: []const u8) error{ InvalidResponse, OutOfMemory }![]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next() orelse return error.InvalidResponse;
    const payload_b64 = parts.next() orelse return error.InvalidResponse;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidResponse;
    const payload = try arena.alloc(u8, len);
    decoder.decode(payload, payload_b64) catch return error.InvalidResponse;

    const Claims = struct { oid: []const u8 };
    const claims = std.json.parseFromSliceLeaky(Claims, arena, payload, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    return claims.oid;
}

const testing = std.testing;

test "parseToken reads token and epoch expiry" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const token = try parseToken(arena_state.allocator(),
        \\{"accessToken":"abc","expiresOn":"2026-10-03 22:00:00.000000","expires_on":1791057600,"tokenType":"Bearer"}
    );
    try testing.expectEqualStrings("abc", token.value);
    try testing.expectEqual(@as(i64, 1791057600), token.expires_at);
}

test "parseToken rejects incomplete output" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.InvalidResponse, parseToken(arena, "{\"accessToken\":\"\",\"expires_on\":1}"));
    try testing.expectError(error.InvalidResponse, parseToken(arena, "{\"expires_on\":1}"));
    try testing.expectError(error.InvalidResponse, parseToken(arena, "ERROR"));
}

test "objectId decodes the oid claim" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Built at runtime so no token-shaped literal trips secret scanners.
    const payload = "{\"oid\":\"11111111-2222-3333-4444-555555555555\",\"name\":\"x\"}";
    const encoder = std.base64.url_safe_no_pad.Encoder;
    var encoded: [encoder.calcSize(payload.len)]u8 = undefined;
    const jwt = try std.mem.concat(arena, u8, &.{ "header.", encoder.encode(&encoded, payload), ".signature" });
    try testing.expectEqualStrings("11111111-2222-3333-4444-555555555555", try objectId(arena, jwt));
    try testing.expectError(error.InvalidResponse, objectId(arena, "nodots"));
    try testing.expectError(error.InvalidResponse, objectId(arena, "a.!!!.c"));
}
