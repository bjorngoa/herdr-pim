//! Command handlers and user-facing messages.
const std = @import("std");
const args = @import("args.zig");
const render = @import("render.zig");
const rows_mod = @import("../domain/rows.zig");
const selection = @import("../domain/selection.zig");
const status_mod = @import("../domain/status.zig");
const duration = @import("../domain/duration.zig");
const time = @import("../domain/time.zig");
const session_mod = @import("../app/session.zig");
const service = @import("../app/snapshot_service.zig");
const activation = @import("../app/activation.zig");
const alerts_service = @import("../app/alerts_service.zig");
const herdr = @import("../adapters/herdr.zig");
const messages = @import("../present/messages.zig");
const errors = @import("../present/errors.zig");

const Row = rows_mod.Row;
const Diagnostics = session_mod.Diagnostics;

pub const help_text =
    \\pim - Azure PIM roles from the terminal
    \\
    \\Usage:
    \\  pim [pick] [FILTER...] [-d DURATION]
    \\  pim ls [FILTER...] [--json] [--refresh | --cached]
    \\  pim up FILTER... [-d DURATION] [-j JUSTIFICATION] [--all] [--no-wait]
    \\  pim down (FILTER... | --all) [--no-wait]
    \\  pim status [--notify] [--max-age SECONDS] [--refresh | --cached]
    \\  pim help | version
    \\
    \\Commands:
    \\  pick     Interactive picker (default in a terminal; alias: ui).
    \\           Type to filter, tab to select, enter to activate,
    \\           ctrl-d to deactivate, ctrl-r to refresh, esc to quit.
    \\  ls       List eligible roles and their activation state
    \\           (default when output is not a terminal).
    \\  up       Activate eligible roles (alias: activate).
    \\  down     Deactivate active roles (alias: deactivate).
    \\  status   One line for status bars, e.g. "PIM 2 · 3h05m".
    \\           Prints nothing when no role is active or pending.
    \\
    \\FILTER terms match scope, subscription or role name, case-insensitively;
    \\all terms must match. An exact scope name wins over partial matches. When
    \\several roles still match, `up`/`down` need --all.
    \\
    \\Options:
    \\  -d, --duration D       Activation length, e.g. 8h, 90m, 1h30m (default 8h).
    \\                         Shortened to the role's policy maximum if needed.
    \\  -j, --justification T  Reason for activation. Prompted for when required.
    \\  --all                  Act on every matching role.
    \\  --no-wait              Return once Azure accepted the request.
    \\  --json                 Machine-readable output.
    \\  --refresh              Always fetch from Azure.
    \\  --cached               Never fetch; use the last cached data.
    \\  --max-age S            Refresh when cached data is older than S seconds (default 300).
    \\  --notify               (status) herdr notifications 15 min before an activation
    \\                         expires, when it expired, and when a pending one is active.
    \\
    \\Authentication uses your Azure CLI session (`az login`). Azure CLI telemetry
    \\is disabled for the calls pim makes. Cached role data (no tokens) is stored in
    \\$PIM_STATE_DIR, $XDG_STATE_HOME/pim or ~/.local/state/pim.
    \\
    \\Set PIM_PROGRESS_WINDOW=1 to show a progress window in the picker while
    \\roles are being activated or deactivated (off by default).
    \\
;

/// Interactive commands use the cache only briefly so they act on current state.
const interactive_max_age_s = 60;
const settle_timeout_s = 120;

pub const Context = struct {
    session: *session_mod.Session,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    /// Present only when stdin is a terminal, for prompts.
    stdin: ?*std.Io.Reader,
    now: i64,
    color: bool,

    fn arena(ctx: Context) std.mem.Allocator {
        return ctx.session.arena;
    }

    fn clock(ctx: Context) i64 {
        return std.Io.Clock.real.now(ctx.session.env.io).toSeconds();
    }
};

pub const Error = errors.Error;
pub const reportError = errors.report;

pub fn list(ctx: Context, opts: args.List, diag: *Diagnostics) Error!void {
    const result = try service.get(ctx.session, ctx.arena(), ctx.now, policyFor(opts.cache, interactive_max_age_s, false), diag);
    const all = try rows_mod.build(ctx.arena(), result.snapshot, ctx.now);

    var selected: std.ArrayList(Row) = .empty;
    for (all) |row| if (rows_mod.matches(row, opts.terms)) try selected.append(ctx.arena(), row);

    if (opts.json) {
        try render.writeJson(ctx.arena(), ctx.stdout, selected.items, ctx.now);
    } else if (selected.items.len == 0) {
        try ctx.stderr.writeAll(if (all.len == 0) "No eligible PIM roles found.\n" else "No roles match the filter.\n");
    } else {
        try render.writeTable(ctx.arena(), ctx.stdout, selected.items, ctx.now, .{ .color = ctx.color });
    }
    if (result.source == .stale_cache) try noteStale(ctx, result.snapshot.fetched_at);
}

pub fn status(ctx: Context, opts: args.Status, diag: *Diagnostics) Error!void {
    const result = try service.get(ctx.session, ctx.arena(), ctx.now, policyFor(opts.cache, opts.max_age_s, true), diag);
    const rows = try rows_mod.build(ctx.arena(), result.snapshot, ctx.now);
    var buf: [64]u8 = undefined;
    const line = status_mod.formatLine(status_mod.summarize(rows), ctx.now, &buf);
    if (line.len > 0) try ctx.stdout.print("{s}\n", .{line});
    if (opts.notify) {
        const env = ctx.session.env;
        alerts_service.process(ctx.arena(), env, herdr.Notifier.fromEnv(env.environ), rows, ctx.now) catch |err|
            std.log.warn("cannot process notifications: {t}", .{err});
    }
}

pub fn up(ctx: Context, opts: args.Up, diag: *Diagnostics) Error!void {
    const targets = try chooseTargets(ctx, opts.terms, .activate, opts.all, diag);
    const plans = try activation.plan(ctx.session, ctx.arena(), targets, opts.duration_min, diag);
    const justification = try resolveJustification(ctx, opts.justification, plans);

    for (plans) |p| {
        var buf: [16]u8 = undefined;
        try ctx.stderr.print("Activating {s} for {s}", .{ try label(ctx, p.row), duration.formatHuman(p.duration.minutes, &buf) });
        if (p.duration.clamped) try ctx.stderr.writeAll(" (policy maximum)");
        if (p.policy) |pol| if (pol.approval_required) try ctx.stderr.writeAll(", needs approval");
        try ctx.stderr.writeAll("\n");
    }
    try ctx.stderr.flush();

    const submissions = try activation.activate(ctx.session, ctx.arena(), plans, justification, ctx.clock(), diag);
    try finish(ctx, submissions, .activate, opts.wait, diag);
}

pub fn down(ctx: Context, opts: args.Down, diag: *Diagnostics) Error!void {
    const targets = try chooseTargets(ctx, opts.terms, .deactivate, opts.all, diag);
    for (targets) |row| try ctx.stderr.print("Deactivating {s}\n", .{try label(ctx, row)});
    try ctx.stderr.flush();

    const submissions = try activation.deactivate(ctx.session, ctx.arena(), targets, diag);
    try finish(ctx, submissions, .deactivate, opts.wait, diag);
}

/// Selects rows to act on, refetching once when cached data finds nothing.
fn chooseTargets(ctx: Context, terms: []const []const u8, intent: selection.Intent, all: bool, diag: *Diagnostics) Error![]const Row {
    var result = try service.get(ctx.session, ctx.arena(), ctx.now, .{ .max_age_s = interactive_max_age_s }, diag);
    while (true) {
        const rows = try rows_mod.build(ctx.arena(), result.snapshot, ctx.now);
        const outcome = try selection.select(ctx.arena(), rows, terms, intent, all);
        if (outcome == .no_match and result.source == .cache) {
            result = .{ .snapshot = try service.refresh(ctx.session, ctx.arena(), ctx.clock(), diag), .source = .network };
            continue;
        }
        switch (outcome) {
            .targets => |targets| return targets,
            .no_match => |others| {
                const wanted = if (intent == .activate) "eligible" else "active";
                if (others.len == 0) {
                    try ctx.stderr.writeAll("No role matches the filter.\n");
                } else {
                    try ctx.stderr.print("No {s} role matches the filter. Matching roles:\n", .{wanted});
                    try render.writeTable(ctx.arena(), ctx.stderr, others, ctx.now, .{});
                }
            },
            .ambiguous => |candidates| {
                try ctx.stderr.writeAll("Several roles match. Narrow the filter or pass --all:\n");
                try render.writeTable(ctx.arena(), ctx.stderr, candidates, ctx.now, .{});
            },
        }
        return error.NothingSelected;
    }
}

fn resolveJustification(ctx: Context, given: ?[]const u8, plans: []const activation.Plan) Error![]const u8 {
    if (given) |text| return std.mem.trim(u8, text, " \t\r\n");
    const needed = for (plans) |p| {
        if (p.needsJustification()) break true;
    } else false;
    if (!needed) return "";

    const stdin = ctx.stdin orelse return error.JustificationRequired;
    try ctx.stderr.writeAll("Justification: ");
    try ctx.stderr.flush();
    const line = stdin.takeDelimiter('\n') catch return error.JustificationRequired;
    const text = std.mem.trim(u8, line orelse "", " \t\r");
    if (text.len == 0) return error.JustificationRequired;
    return ctx.arena().dupe(u8, text);
}

fn finish(ctx: Context, submissions: []const activation.Submission, intent: selection.Intent, wait: bool, diag: *Diagnostics) Error!void {
    const any_settling = for (submissions) |s| {
        if (s.settlesAutomatically()) break true;
    } else false;

    var settled = true;
    if (wait and any_settling) {
        try ctx.stderr.writeAll("Waiting for Azure to apply the change...\n");
        try ctx.stderr.flush();
        settled = activation.awaitSettled(ctx.session, ctx.arena(), submissions, intent, settle_timeout_s, diag) catch |err| blk: {
            try ctx.stderr.print("pim: stopped waiting ({t}).\n", .{err});
            break :blk false;
        };
    }

    // Refresh so `pim ls` and status bars reflect the change immediately.
    const now = ctx.clock();
    const rows: []const Row = if (service.refresh(ctx.session, ctx.arena(), now, diag)) |snapshot|
        try rows_mod.build(ctx.arena(), snapshot, now)
    else |err| blk: {
        try ctx.stderr.print("pim: could not refresh role state ({t}).\n", .{err});
        break :blk &.{};
    };

    var failed = false;
    for (submissions) |s| {
        try writeOutcome(ctx, try messages.describeOutcome(ctx.arena(), s, intent, messages.findRow(rows, s.row), now));
        if (s.outcome == .failed) failed = true;
    }
    if (!settled and wait) try ctx.stderr.writeAll("Azure is still applying some changes; check `pim ls` shortly.\n");
    if (failed) return error.PartialFailure;
}

fn writeOutcome(ctx: Context, line: messages.Line) Error!void {
    const color = switch (line.kind) {
        .ok => "\x1b[32m",
        .pending => "\x1b[33m",
        .failed => "\x1b[31m",
        .info => "",
    };
    if (ctx.color and color.len > 0) {
        try ctx.stdout.print("{s}{s}\x1b[0m {s}\n", .{ color, line.glyph, line.text });
    } else {
        try ctx.stdout.print("{s} {s}\n", .{ line.glyph, line.text });
    }
}

fn label(ctx: Context, row: Row) std.mem.Allocator.Error![]const u8 {
    return messages.label(ctx.arena(), row);
}

fn policyFor(cache: args.CachePolicy, max_age_s: i64, stale_on_error: bool) service.Policy {
    return switch (cache) {
        .auto => .{ .max_age_s = max_age_s, .stale_on_error = stale_on_error },
        .refresh => .{ .max_age_s = 0, .force = true, .stale_on_error = stale_on_error },
        .cached => .{ .max_age_s = 0, .offline = true },
    };
}

fn noteStale(ctx: Context, fetched_at: i64) !void {
    var buf: [16]u8 = undefined;
    const age = time.formatRemaining(ctx.now - fetched_at, &buf);
    try ctx.stderr.print("pim: Azure unreachable; showing data cached {s} ago.\n", .{age});
}

const testing = std.testing;

test "policyFor maps cache options" {
    try testing.expect(policyFor(.refresh, 60, false).force);
    try testing.expect(policyFor(.cached, 60, true).offline);
    const auto = policyFor(.auto, 42, true);
    try testing.expectEqual(@as(i64, 42), auto.max_age_s);
    try testing.expect(auto.stale_on_error and !auto.force and !auto.offline);
}
