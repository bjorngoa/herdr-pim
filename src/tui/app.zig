//! Runs the picker: terminal setup, the event loop, and background tasks that
//! talk to Azure without blocking input.
//!
//! Memory: each background task allocates its results in a `Batch` (an arena).
//! The model borrows from batches, so replaced batches are retired and only
//! freed once no form is open and no task that may reference them is running.
const std = @import("std");
const vaxis = @import("vaxis");
const rows_mod = @import("../domain/rows.zig");
const selection = @import("../domain/selection.zig");
const session_mod = @import("../app/session.zig");
const service = @import("../app/snapshot_service.zig");
const activation = @import("../app/activation.zig");
const messages = @import("../present/messages.zig");
const errors = @import("../present/errors.zig");
const log = @import("../platform/log.zig");
const model_mod = @import("model.zig");
const keymap = @import("keymap.zig");
const view = @import("view.zig");

const Row = rows_mod.Row;
const Model = model_mod.Model;
const Session = session_mod.Session;
const Allocator = std.mem.Allocator;

pub const Options = struct {
    default_duration_min: u32,
    initial_filter: []const u8 = "",
};

const settle_timeout_s = 120;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    tick,
    rows_loaded: *Batch,
    policies_loaded: *Batch,
    operation_done: *Batch,
};

/// Results of one background task, owned by its arena.
const Batch = struct {
    arena: std.heap.ArenaAllocator,
    refs: u8 = 1,
    rows: ?[]const Row = null,
    fetched_at: i64 = 0,
    plans: []const activation.Plan = &.{},
    lines: []const messages.Line = &.{},
    failure: ?[]const u8 = null,

    fn create(gpa: Allocator) Allocator.Error!*Batch {
        const b = try gpa.create(Batch);
        b.* = .{ .arena = .init(gpa) };
        return b;
    }

    fn allocator(b: *Batch) Allocator {
        return b.arena.allocator();
    }

    fn retain(b: *Batch) *Batch {
        b.refs += 1;
        return b;
    }

    fn release(b: *Batch, gpa: Allocator) void {
        b.refs -= 1;
        if (b.refs > 0) return;
        b.arena.deinit();
        gpa.destroy(b);
    }
};

const App = struct {
    gpa: Allocator,
    io: std.Io,
    session: *Session,
    loop: *vaxis.Loop(Event),
    group: std.Io.Group = .init,
    /// Background tasks whose result has not been handled yet.
    inflight: usize = 0,

    rows_batch: ?*Batch = null,
    policies_batch: ?*Batch = null,
    results_batch: ?*Batch = null,
    retired: std.ArrayList(*Batch) = .empty,

    fn deinit(app: *App) void {
        app.group.cancel(app.io);
        while (app.loop.tryEvent() catch null) |event| switch (event) {
            .rows_loaded, .policies_loaded, .operation_done => |b| b.release(app.gpa),
            else => {},
        };
        for ([_]?*Batch{ app.rows_batch, app.policies_batch, app.results_batch }) |b| if (b) |batch| batch.release(app.gpa);
        for (app.retired.items) |b| b.release(app.gpa);
        app.retired.deinit(app.gpa);
    }

    fn now(app: *const App) i64 {
        return std.Io.Clock.real.now(app.io).toSeconds();
    }

    /// Hands a finished task's batch to the UI thread, or frees it if the
    /// loop has already stopped.
    fn post(app: *App, event: Event) void {
        app.loop.postEvent(event) catch switch (event) {
            .rows_loaded, .policies_loaded, .operation_done => |b| b.release(app.gpa),
            else => {},
        };
    }

    /// Starts a task; returns false (and tells the user) if that failed, in
    /// which case the caller still owns the arguments.
    fn spawn(app: *App, m: *Model, comptime function: anytype, args: anytype) bool {
        app.group.concurrent(app.io, function, args) catch {
            m.busy = null;
            m.refreshing = false;
            m.setNotice(.failed, "Could not start a background task.");
            return false;
        };
        app.inflight += 1;
        return true;
    }

    /// Performs an effect. Returns true when the UI should exit.
    fn perform(app: *App, m: *Model, effect: model_mod.Effect) bool {
        switch (effect) {
            .none => {},
            .quit => return true,
            .refresh => _ = app.spawn(m, refreshTask, .{app}),
            .load_policies => |targets| if (!app.spawn(m, policiesTask, .{ app, targets, m.default_duration_min })) app.gpa.free(targets),
            .activate => |job| if (!app.spawn(m, activateTask, .{ app, job })) {
                app.gpa.free(job.targets);
                app.gpa.free(job.justification);
            },
            .deactivate => |targets| if (!app.spawn(m, deactivateTask, .{ app, targets })) app.gpa.free(targets),
        }
        return false;
    }

    fn handle(app: *App, m: *Model, event: Event) Allocator.Error!void {
        switch (event) {
            .rows_loaded => |b| {
                app.inflight -= 1;
                if (b.failure) |msg| {
                    m.setRefreshFailed(msg);
                    try app.retire(b);
                } else try app.adoptRows(m, b);
            },
            .policies_loaded => |b| {
                app.inflight -= 1;
                if (app.policies_batch) |old| try app.retire(old);
                app.policies_batch = b;
                if (b.failure) |msg| {
                    m.setNotice(.failed, msg);
                } else m.setPolicies(b.plans);
            },
            .operation_done => |b| {
                app.inflight -= 1;
                if (b.rows != null) try app.adoptRows(m, b.retain());
                if (app.results_batch) |old| try app.retire(old);
                app.results_batch = b;
                m.setResults(b.lines);
                if (b.failure) |msg| m.setNotice(.failed, msg);
            },
            else => unreachable,
        }
    }

    fn adoptRows(app: *App, m: *Model, b: *Batch) Allocator.Error!void {
        try m.setRows(b.rows.?, b.fetched_at);
        if (app.rows_batch) |old| try app.retire(old);
        app.rows_batch = b;
    }

    fn retire(app: *App, b: *Batch) Allocator.Error!void {
        try app.retired.append(app.gpa, b);
    }

    /// Frees retired batches once nothing can still point into them.
    fn collect(app: *App, m: *const Model) void {
        if (app.inflight > 0 or m.mode != .browse) return;
        if (app.policies_batch) |b| {
            app.policies_batch = null;
            b.release(app.gpa);
        }
        for (app.retired.items) |b| b.release(app.gpa);
        app.retired.clearRetainingCapacity();
    }
};

// ---- background tasks --------------------------------------------------------

fn refreshTask(app: *App) void {
    const b = Batch.create(app.gpa) catch return;
    var diag: session_mod.Diagnostics = .{};
    loadRows(app, b, &diag) catch |err| {
        b.failure = errors.summaryAlloc(b.allocator(), err, diag) catch "Refresh failed";
    };
    app.post(.{ .rows_loaded = b });
}

fn loadRows(app: *App, b: *Batch, diag: *session_mod.Diagnostics) errors.Error!void {
    const now = app.now();
    const snapshot = try service.refresh(app.session, b.allocator(), now, diag);
    b.rows = try rows_mod.build(b.allocator(), snapshot, now);
    b.fetched_at = snapshot.fetched_at;
}

fn policiesTask(app: *App, targets: []Row, requested_min: u32) void {
    defer app.gpa.free(targets);
    const b = Batch.create(app.gpa) catch return;
    var diag: session_mod.Diagnostics = .{};
    b.plans = activation.plan(app.session, b.allocator(), targets, requested_min, &diag) catch |err| blk: {
        b.failure = errors.summaryAlloc(b.allocator(), err, diag) catch "Could not read policies";
        break :blk &.{};
    };
    app.post(.{ .policies_loaded = b });
}

fn activateTask(app: *App, job: model_mod.ActivateJob) void {
    defer app.gpa.free(job.targets);
    defer app.gpa.free(job.justification);
    const b = Batch.create(app.gpa) catch return;
    var diag: session_mod.Diagnostics = .{};
    runOperation(app, b, .activate, job, &diag) catch |err| {
        b.failure = errors.summaryAlloc(b.allocator(), err, diag) catch "Activation failed";
    };
    app.post(.{ .operation_done = b });
}

fn deactivateTask(app: *App, targets: []Row) void {
    defer app.gpa.free(targets);
    const b = Batch.create(app.gpa) catch return;
    var diag: session_mod.Diagnostics = .{};
    const job: model_mod.ActivateJob = .{ .targets = targets, .duration_min = 0, .justification = "" };
    runOperation(app, b, .deactivate, job, &diag) catch |err| {
        b.failure = errors.summaryAlloc(b.allocator(), err, diag) catch "Deactivation failed";
    };
    app.post(.{ .operation_done = b });
}

/// Submits the requests, waits for Azure to apply them, refreshes the rows
/// and describes each outcome.
fn runOperation(app: *App, b: *Batch, intent: selection.Intent, job: model_mod.ActivateJob, diag: *session_mod.Diagnostics) errors.Error!void {
    const arena = b.allocator();
    const submissions = switch (intent) {
        .activate => blk: {
            const plans = try activation.plan(app.session, arena, job.targets, job.duration_min, diag);
            break :blk try activation.activate(app.session, arena, plans, job.justification, app.now(), diag);
        },
        .deactivate => try activation.deactivate(app.session, arena, job.targets, diag),
    };

    const settling = for (submissions) |s| {
        if (s.settlesAutomatically()) break true;
    } else false;

    // Requests were already submitted, so later failures are reported next to
    // the outcomes rather than replacing them.
    var problems: std.ArrayList(messages.Line) = .empty;
    var still_applying = false;
    if (settling) {
        if (activation.awaitSettled(app.session, arena, submissions, intent, settle_timeout_s, diag)) |settled| {
            still_applying = !settled;
        } else |err| {
            try problems.append(arena, try problemLine(arena, "Could not confirm the change", err, diag.*));
        }
    }
    loadRows(app, b, diag) catch |err|
        try problems.append(arena, try problemLine(arena, "Could not refresh roles", err, diag.*));

    const now = app.now();
    var lines: std.ArrayList(messages.Line) = .empty;
    for (submissions) |s| {
        const final = if (b.rows) |rows| messages.findRow(rows, s.row) else null;
        try lines.append(arena, try messages.describeOutcome(arena, s, intent, final, now));
    }
    try lines.appendSlice(arena, problems.items);
    if (still_applying) try lines.append(arena, .{ .kind = .info, .glyph = "…", .text = "Azure is still applying some changes; press ^r to refresh." });
    b.lines = lines.items;
}

fn problemLine(arena: Allocator, what: []const u8, err: errors.Error, diag: session_mod.Diagnostics) Allocator.Error!messages.Line {
    const reason = try errors.summaryAlloc(arena, err, diag);
    return .{
        .kind = .info,
        .glyph = "!",
        .text = try std.fmt.allocPrint(arena, "{s}: {s}. Press ^r to refresh.", .{ what, reason }),
    };
}

fn tickTask(app: *App) std.Io.Cancelable!void {
    while (true) {
        try app.io.sleep(.fromSeconds(1), .awake);
        app.loop.postEvent(.tick) catch return;
    }
}

// ---- entry point -------------------------------------------------------------

pub fn run(gpa: Allocator, io: std.Io, environ: *std.process.Environ.Map, session: *Session, opts: Options) !void {
    var tty_buffer: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buffer);
    defer tty.deinit();
    const out = tty.writer();

    var vx = try vaxis.init(io, gpa, environ, .{});
    defer vx.deinit(gpa, out);

    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    defer loop.uninstallResizeHandler();
    try loop.start();
    defer loop.stop();

    log.setMuted(true);
    defer log.setMuted(false);
    try vx.enterAltScreen(out);
    defer vx.exitAltScreen(out) catch {};
    try vx.queryTerminal(out, .fromSeconds(1));

    var model: Model = .init(gpa, opts.default_duration_min);
    defer model.deinit();
    model.filter.set(opts.initial_filter);

    var app: App = .{ .gpa = gpa, .io = io, .session = session, .loop = &loop };
    defer app.deinit();

    if (try loadCachedRows(&app)) |b| {
        try app.adoptRows(&model, b);
    } else {
        try model.setRows(&.{}, 0);
        model.fetched_at = null;
    }
    model.refreshing = true;
    _ = app.spawn(&model, refreshTask, .{&app});
    app.group.concurrent(io, tickTask, .{&app}) catch {};

    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| if (keymap.translate(key)) |input| {
                if (app.perform(&model, try model.update(input))) break;
            },
            .winsize => |ws| try vx.resize(gpa, out, ws),
            .tick => model.tick(),
            else => try app.handle(&model, event),
        }
        app.collect(&model);

        _ = frame.reset(.retain_capacity);
        try view.draw(frame.allocator(), vx.window(), &model, app.now());
        try vx.render(out);
        try out.flush();
    }
}

/// Shows cached data instantly; a background refresh replaces it.
fn loadCachedRows(app: *App) Allocator.Error!?*Batch {
    const b = try Batch.create(app.gpa);
    const snapshot = service.loadCached(app.session, b.allocator()) orelse {
        b.release(app.gpa);
        return null;
    };
    b.rows = try rows_mod.build(b.allocator(), snapshot, app.now());
    b.fetched_at = snapshot.fetched_at;
    return b;
}
