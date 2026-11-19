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
const background_job = @import("../app/background_job.zig");
const azure_login = @import("../adapters/azure_login.zig");
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
    progress_window: bool = false,
    sign_in: bool = false,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    tick,
    rows_loaded: *Batch,
    policies_loaded: *Batch,
    login_code: struct { generation: u64, code: azure_login.DeviceCode },
    login_refreshing: u64,
    login_done: *Batch,
};

/// Results of one background task, owned by its arena.
const Batch = struct {
    arena: std.heap.ArenaAllocator,
    rows: ?[]const Row = null,
    fetched_at: i64 = 0,
    plans: []const activation.Plan = &.{},
    failure: ?[]const u8 = null,
    job: ?background_job.Job = null,
    generation: u64 = 0,
    authentication_required: bool = false,

    fn create(gpa: Allocator) Allocator.Error!*Batch {
        const b = try gpa.create(Batch);
        b.* = .{ .arena = .init(gpa) };
        return b;
    }

    fn allocator(b: *Batch) Allocator {
        return b.arena.allocator();
    }

    fn release(b: *Batch, gpa: Allocator) void {
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
    login_group: std.Io.Group = .init,
    login_generation: u64 = 0,
    generation: u64 = 0,
    /// Background tasks whose result has not been handled yet.
    inflight: usize = 0,

    rows_batch: ?*Batch = null,
    policies_batch: ?*Batch = null,
    job_batch: ?*Batch = null,
    retired: std.ArrayList(*Batch) = .empty,

    fn deinit(app: *App) void {
        app.login_group.cancel(app.io);
        app.group.cancel(app.io);
        while (app.loop.tryEvent() catch null) |event| switch (event) {
            .rows_loaded, .policies_loaded, .login_done => |b| b.release(app.gpa),
            else => {},
        };
        for ([_]?*Batch{ app.rows_batch, app.policies_batch, app.job_batch }) |b| if (b) |batch| batch.release(app.gpa);
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
            .rows_loaded, .policies_loaded, .login_done => |b| b.release(app.gpa),
            else => {},
        };
    }

    /// Starts a task; returns false (and tells the user) if that failed, in
    /// which case the caller still owns the arguments.
    fn spawn(app: *App, m: *Model, comptime function: anytype, args: anytype) bool {
        app.group.concurrent(app.io, function, args) catch {
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
            .refresh => _ = app.spawn(m, refreshTask, .{ app, app.generation }),
            .load_policies => |targets| if (!app.spawn(m, policiesTask, .{ app, targets, m.default_duration_min, app.generation })) app.gpa.free(targets),
            .sign_in => |method| app.startSignIn(m, method),
            .cancel_sign_in => {
                app.login_generation +%= 1;
                app.generation +%= 1;
                app.login_group.cancel(app.io);
                m.refreshing = false;
                m.setNotice(.info, "Sign-in cancelled. No roles were retried.");
            },
            .activate => |job| {
                app.startOperation(m, .activate, job.targets, job.duration_min, job.justification);
                app.gpa.free(job.targets);
                app.gpa.free(job.justification);
            },
            .deactivate => |targets| {
                app.startOperation(m, .deactivate, targets, 0, "");
                app.gpa.free(targets);
            },
        }
        return false;
    }

    fn handle(app: *App, m: *Model, event: Event) Allocator.Error!void {
        switch (event) {
            .rows_loaded => |b| {
                app.inflight -= 1;
                if (b.generation != app.generation) return app.retire(b);
                if (b.failure) |msg| {
                    m.setRefreshFailed(msg);
                    if (b.authentication_required) try m.requireSignIn();
                    try app.retire(b);
                } else try app.adoptRows(m, b);
            },
            .policies_loaded => |b| {
                app.inflight -= 1;
                if (b.generation != app.generation) return app.retire(b);
                if (app.policies_batch) |old| try app.retire(old);
                app.policies_batch = b;
                if (b.failure) |msg| {
                    m.setNotice(.failed, msg);
                    if (b.authentication_required) try m.requireSignIn();
                } else m.setPolicies(b.plans);
            },
            .login_code => |update| {
                if (update.generation == app.login_generation and m.sign_in_state == .running)
                    m.sign_in_code = update.code;
            },
            .login_refreshing => |generation| {
                if (generation == app.login_generation) {
                    m.sign_in_state = .refreshing;
                    m.sign_in_code = null;
                    m.refreshing = true;
                }
            },
            .login_done => |b| {
                if (b.generation != app.login_generation) return app.retire(b);
                if (b.failure) |msg| {
                    m.signInFailed(msg);
                    try app.retire(b);
                } else {
                    try app.adoptRows(m, b);
                    m.signInComplete();
                }
            },
            else => unreachable,
        }
    }

    fn startSignIn(app: *App, m: *Model, method: azure_login.Method) void {
        app.login_generation +%= 1;
        app.generation +%= 1;
        app.login_group.cancel(app.io);
        m.refreshing = false;
        app.login_group.concurrent(app.io, loginTask, .{ app, app.login_generation, method }) catch
            m.signInFailed("Could not start Azure sign-in. Press enter to try again.");
    }

    fn startOperation(app: *App, m: *Model, intent: selection.Intent, targets: []const Row, duration_min: u32, justification: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(app.gpa);
        defer arena.deinit();
        const child = background_job.start(app.session, arena.allocator(), intent, targets, duration_min, justification) catch |err| {
            m.endOperation();
            m.setNotice(.failed, if (err == error.OperationInProgress)
                "Another PIM operation is already running. Reopen the picker to see its progress."
            else
                "Could not start the background operation; no requests were submitted.");
            return;
        };
        // Cancellation stops waiting, not the independent worker.
        app.group.concurrent(app.io, reapWorker, .{ app.io, child }) catch {};
        m.busy_since = app.now();
        app.syncJob(m) catch m.setNotice(.failed, "Could not read background progress. The operation may still be running.");
    }

    fn syncJob(app: *App, m: *Model) !void {
        const b = try Batch.create(app.gpa);
        errdefer b.release(app.gpa);
        b.job = try background_job.load(b.allocator(), app.session.env);
        const job = b.job orelse {
            b.release(app.gpa);
            return;
        };
        if (app.job_batch) |old| {
            const previous = old.job.?;
            if (std.mem.eql(u8, previous.id, job.id) and previous.done == job.done) {
                b.release(app.gpa);
                return;
            }
        }
        try app.retired.ensureUnusedCapacity(app.gpa, 1);
        if (job.done) {
            const was_running = m.busy != null;
            m.setResults(job.lines);
            if (job.failure) |msg| m.setNotice(.failed, msg);
            if (job.authentication_required and m.sign_in_enabled) {
                try m.rememberRetry(job.targets, job.intent, job.duration_min);
                if (was_running or m.authentication_required) try m.requireSignIn();
            }
            if (!m.refreshing and (!job.authentication_required or !m.sign_in_enabled)) {
                m.refreshing = true;
                _ = app.spawn(m, refreshTask, .{ app, app.generation });
            }
        } else {
            try m.restoreOperation(if (job.intent == .activate) "Activating" else "Deactivating", job.targets, job.started_at);
            m.setNotice(.info, "You can close the picker. This operation will continue in the background.");
        }
        if (app.job_batch) |old| app.retired.appendAssumeCapacity(old);
        app.job_batch = b;
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
        if (app.inflight > 0 or m.mode != .browse or m.busy != null) return;
        if (app.policies_batch) |b| {
            app.policies_batch = null;
            b.release(app.gpa);
        }
        for (app.retired.items) |b| b.release(app.gpa);
        app.retired.clearRetainingCapacity();
    }
};

// ---- background tasks --------------------------------------------------------

fn refreshTask(app: *App, generation: u64) void {
    const b = Batch.create(app.gpa) catch return;
    b.generation = generation;
    var diag: session_mod.Diagnostics = .{};
    loadRows(app, b, &diag) catch |err| {
        b.authentication_required = errors.needsSignIn(err, diag);
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

fn policiesTask(app: *App, targets: []Row, requested_min: u32, generation: u64) void {
    defer app.gpa.free(targets);
    const b = Batch.create(app.gpa) catch return;
    b.generation = generation;
    var diag: session_mod.Diagnostics = .{};
    b.plans = activation.plan(app.session, b.allocator(), targets, requested_min, &diag) catch |err| blk: {
        b.authentication_required = errors.needsSignIn(err, diag);
        b.failure = errors.summaryAlloc(b.allocator(), err, diag) catch "Could not read policies";
        break :blk &.{};
    };
    app.post(.{ .policies_loaded = b });
}

const LoginProgress = struct {
    app: *App,
    generation: u64,

    fn update(context: *anyopaque, code: azure_login.DeviceCode) void {
        const progress: *LoginProgress = @ptrCast(@alignCast(context));
        progress.app.post(.{ .login_code = .{ .generation = progress.generation, .code = code } });
    }
};

fn loginTask(app: *App, generation: u64, method: azure_login.Method) void {
    const b = Batch.create(app.gpa) catch return;
    b.generation = generation;
    var progress: LoginProgress = .{ .app = app, .generation = generation };
    const env = app.session.env;
    azure_login.login(b.allocator(), app.io, env.environ, method, .{ .context = &progress, .update = LoginProgress.update }) catch |err| {
        b.failure = switch (err) {
            error.AzCliNotFound => "Azure CLI was not found. Install az, then try again.",
            error.TimedOut => "Azure sign-in timed out. Press enter to retry or d for a device code.",
            else => "Azure sign-in failed or was cancelled. Press enter to retry or d for a device code.",
        };
        app.post(.{ .login_done = b });
        return;
    };
    app.post(.{ .login_refreshing = generation });
    var diag: session_mod.Diagnostics = .{};
    app.session.invalidateToken() catch {
        b.failure = "Sign-in was cancelled before roles could be refreshed.";
        app.post(.{ .login_done = b });
        return;
    };
    loadRows(app, b, &diag) catch |err| {
        b.failure = std.fmt.allocPrint(b.allocator(), "Signed in, but role refresh failed: {s}", .{
            errors.summaryAlloc(b.allocator(), err, diag) catch "could not contact Azure",
        }) catch "Signed in, but role refresh failed. Dismiss and press Ctrl-R to refresh.";
    };
    app.post(.{ .login_done = b });
}

fn reapWorker(io: std.Io, process: std.process.Child) void {
    var child = process;
    _ = child.wait(io) catch {};
}

fn tickTask(app: *App) std.Io.Cancelable!void {
    while (true) {
        try app.io.sleep(.fromMilliseconds(model_mod.tick_ms), .awake);
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
    model.progress_window = opts.progress_window;
    model.sign_in_enabled = opts.sign_in;

    var app: App = .{ .gpa = gpa, .io = io, .session = session, .loop = &loop };
    defer app.deinit();

    if (try loadCachedRows(&app)) |b| {
        try app.adoptRows(&model, b);
    } else {
        try model.setRows(&.{}, 0);
        model.fetched_at = null;
    }
    model.refreshing = true;
    _ = app.spawn(&model, refreshTask, .{ &app, app.generation });
    try app.syncJob(&model);
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
            .tick => {
                if (!model.tick()) continue;
                if (model.ticks % model_mod.ticks_per_second == 0)
                    app.syncJob(&model) catch model.setNotice(.failed, "Could not read background progress.");
            },
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

test "login refresh replaces roles but stale pre-login results cannot reopen authentication" {
    const testing = std.testing;
    var model: Model = .init(testing.allocator, 480);
    defer model.deinit();
    model.sign_in_enabled = true;
    model.mode = .sign_in;
    model.sign_in_state = .running;
    const target: Row = .{
        .eligibility = .{ .schedule_id = "one", .scope = "", .scope_name = "rg", .role_definition_id = "owner", .role_name = "Owner" },
        .subscription_name = "Sub",
        .state = .eligible,
    };
    try model.setRows(&.{target}, 1);
    try model.rememberRetry(&.{target}, .activate, 60);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .session = undefined,
        .loop = undefined,
        .generation = 2,
        .login_generation = 3,
        .inflight = 1,
    };
    defer {
        if (app.rows_batch) |b| b.release(testing.allocator);
        for (app.retired.items) |b| b.release(testing.allocator);
        app.retired.deinit(testing.allocator);
    }
    const stale = try Batch.create(testing.allocator);
    stale.generation = 1;
    stale.failure = "Expired login";
    stale.authentication_required = true;
    try app.handle(&model, .{ .rows_loaded = stale });
    try testing.expect(!model.authentication_required);
    try testing.expectEqual(model_mod.SignInState.running, model.sign_in_state);

    try app.handle(&model, .{ .login_refreshing = 2 });
    try testing.expectEqual(model_mod.SignInState.running, model.sign_in_state);
    try app.handle(&model, .{ .login_refreshing = 3 });
    try testing.expectEqual(model_mod.SignInState.refreshing, model.sign_in_state);
    const done = try Batch.create(testing.allocator);
    done.generation = 3;
    var active = target;
    active.state = .active;
    done.rows = &.{active};
    done.fetched_at = 100;
    try app.handle(&model, .{ .login_done = done });
    try testing.expectEqual(model_mod.SignInState.ready, model.sign_in_state);
    try testing.expectEqual(rows_mod.State.active, model.rows[0].state);
    try testing.expectEqual(@as(usize, 0), model.selected.count());
    try testing.expect(model.busy == null);
}
