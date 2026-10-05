//! Top-level failure reporting: explains what went wrong and how to fix it.
//! Never prints secrets.
const std = @import("std");
const session_mod = @import("../app/session.zig");
const service = @import("../app/snapshot_service.zig");
const activation = @import("../app/activation.zig");
const text = @import("text.zig");

pub const Error = service.GetError || activation.Error || std.Io.Writer.Error || error{
    /// Nothing to act on; the reason was already shown.
    NothingSelected,
    /// Some requests failed; details were already shown.
    PartialFailure,
    JustificationRequired,
};

pub fn report(w: *std.Io.Writer, err: Error, diag: session_mod.Diagnostics) std.Io.Writer.Error!void {
    switch (err) {
        error.NothingSelected, error.PartialFailure, error.WriteFailed => {},
        error.JustificationRequired => try w.writeAll("pim: this role requires a justification. Pass -j \"reason\".\n"),
        error.AzCliNotFound => try w.writeAll(
            \\pim: the Azure CLI (az) was not found on PATH.
            \\     Install it from https://aka.ms/azure-cli, then run `az login`.
            \\
        ),
        error.AzCliFailed => {
            try w.writeAll("pim: could not get an Azure token. Run `az login` and try again.\n");
            if (firstLine(diag.az.stderr)) |line| {
                try w.writeAll("     az: ");
                try text.writeSanitized(w, line);
                try w.writeByte('\n');
            }
        },
        error.Timeout => try w.writeAll("pim: `az` did not respond within 30 seconds.\n"),
        error.TimedOut => try w.writeAll("pim: Azure did not respond in time. Check your connection and retry.\n"),
        error.HttpFailed => {
            const code = if (diag.arm.status) |s| @intFromEnum(s) else 0;
            try w.print("pim: Azure returned HTTP {d}", .{code});
            if (diag.arm.code.len > 0) {
                try w.writeByte(' ');
                try text.writeSanitized(w, diag.arm.code);
            }
            if (diag.arm.message.len > 0) {
                try w.writeAll(": ");
                try text.writeSanitized(w, diag.arm.message);
            }
            try w.writeByte('\n');
            if (code == 401) try w.writeAll("     Your session may have expired. Run `az login`.\n");
        },
        error.InvalidResponse => try w.writeAll("pim: unexpected response from Azure.\n"),
        error.UntrustedNextLink => try w.writeAll("pim: refused to follow a pagination link outside management.azure.com.\n"),
        error.NoCachedSnapshot => try w.writeAll("pim: no cached data yet. Run `pim ls` once to fetch it.\n"),
        error.OutOfMemory => try w.writeAll("pim: out of memory.\n"),
        else => |e| try w.print("pim: could not reach Azure ({t}).\n", .{e}),
    }
}

/// The first line of `report` without the `pim:` prefix or final period,
/// for one-line UI messages.
pub fn summaryAlloc(arena: std.mem.Allocator, err: Error, diag: session_mod.Diagnostics) std.mem.Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    report(&out.writer, err, diag) catch return error.OutOfMemory;
    const line = firstLine(out.written()) orelse return @errorName(err);
    const unprefixed = if (std.mem.startsWith(u8, line, "pim: ")) line["pim: ".len..] else line;
    return std.mem.trimEnd(u8, unprefixed, ".");
}

fn firstLine(s: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, s, "\r\n");
    return it.next();
}

const testing = std.testing;

test "report gives actionable messages" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try report(&out.writer, error.AzCliFailed, .{ .az = .{ .stderr = "ERROR: Please run 'az login'.\nmore" } });
    try testing.expectEqualStrings(
        "pim: could not get an Azure token. Run `az login` and try again.\n     az: ERROR: Please run 'az login'.\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try report(&out.writer, error.HttpFailed, .{ .arm = .{ .status = .unauthorized, .code = "ExpiredAuthenticationToken", .message = "Expired." } });
    try testing.expectEqualStrings(
        "pim: Azure returned HTTP 401 ExpiredAuthenticationToken: Expired.\n     Your session may have expired. Run `az login`.\n",
        out.written(),
    );

    out.clearRetainingCapacity();
    try report(&out.writer, error.PartialFailure, .{});
    try testing.expectEqualStrings("", out.written());
}

test "report sanitizes text that comes from Azure or az" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try report(&out.writer, error.HttpFailed, .{ .arm = .{ .status = .bad_request, .code = "Bad\x1b[31m", .message = "msg\x1b]0;x\x07" } });
    try testing.expectEqualStrings("pim: Azure returned HTTP 400 Bad?[31m: msg?]0;x?\n", out.written());

    out.clearRetainingCapacity();
    try report(&out.writer, error.AzCliFailed, .{ .az = .{ .stderr = "ERROR: \x1b[2Jboom" } });
    try testing.expect(std.mem.indexOf(u8, out.written(), "\x1b") == null);
}

test "summaryAlloc returns one line without prefix" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("unexpected response from Azure", try summaryAlloc(arena, error.InvalidResponse, .{}));
    try testing.expectEqualStrings(
        "could not get an Azure token. Run `az login` and try again",
        try summaryAlloc(arena, error.AzCliFailed, .{ .az = .{ .stderr = "second line" } }),
    );
    try testing.expectEqualStrings("PartialFailure", try summaryAlloc(arena, error.PartialFailure, .{}));
}
