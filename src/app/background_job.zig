//! Picker operations outlive the terminal. The worker inherits an exclusive
//! file lock through stdin, so there is no unlocked handoff or stale PID reuse.
const std = @import("std");
const builtin = @import("builtin");
const store = @import("../adapters/json_store.zig");
const herdr = @import("../adapters/herdr.zig");
const rows_mod = @import("../domain/rows.zig");
const selection = @import("../domain/selection.zig");
const session_mod = @import("session.zig");
const activation = @import("activation.zig");
const service = @import("snapshot_service.zig");
const messages = @import("../present/messages.zig");
const errors = @import("../present/errors.zig");

pub const worker_command = "__background-worker";
const file_name = "operation.json";
const lock_name = "operation.lock";
const private_file: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
const private_dir: std.Io.Dir.Permissions =
    if (@hasDecl(std.Io.Dir.Permissions, "fromMode")) .fromMode(0o700) else .default_dir;

pub const Job = struct {
    pub const schema_version: u32 = 1;
    version: u32 = schema_version,
    id: []const u8,
    intent: selection.Intent,
    targets: []const rows_mod.Row,
    duration_min: u32,
    started_at: i64,
    done: bool = false,
    lines: []const messages.Line = &.{},
    failure: ?[]const u8 = null,
    /// Cleared by the worker before it contacts Azure.
    justification: ?[]const u8 = null,
};

/// Caller must reap the child, but must never kill it when the picker closes.
pub fn start(session: *session_mod.Session, arena: std.mem.Allocator, intent: selection.Intent, targets: []const rows_mod.Row, duration_min: u32, justification: []const u8) !std.process.Child {
    const env = session.env;
    const lock = try acquire(env.io, env.state_dir);
    // Closing (not unlocking) preserves the child's inherited lock.
    defer lock.close(env.io);

    const now = std.Io.Clock.real.now(env.io);
    var job: Job = .{
        .id = try std.fmt.allocPrint(arena, "{d}", .{now.toNanoseconds()}),
        .intent = intent,
        .targets = targets,
        .duration_min = duration_min,
        .started_at = now.toSeconds(),
        .justification = justification,
    };
    const exe = try std.process.executablePathAlloc(env.io, arena);
    try store.save(Job, env.io, env.state_dir, file_name, job);
    return std.process.spawn(env.io, .{
        .argv = &.{ exe, worker_command, job.id },
        .environ_map = env.environ,
        .stdin = .{ .file = lock },
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
        .create_no_window = true,
    }) catch |err| {
        job.done = true;
        job.justification = null;
        job.failure = "Could not start the background worker; no requests were submitted.";
        try store.save(Job, env.io, env.state_dir, file_name, job);
        return err;
    };
}

fn acquire(io: std.Io, state_dir: []const u8) !std.Io.File {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, state_dir, .{ .permissions = private_dir });
    defer dir.close(io);
    return dir.createFile(io, lock_name, .{
        .read = true,
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = private_file,
    }) catch |err| switch (err) {
        error.WouldBlock => error.OperationInProgress,
        else => err,
    };
}

/// A lost worker is reported, never retried: Azure may have accepted requests.
pub fn load(arena: std.mem.Allocator, env: session_mod.Env) !?Job {
    const path = try std.fs.path.join(arena, &.{ env.state_dir, lock_name });
    const lock = std.Io.Dir.cwd().openFile(env.io, path, .{
        .mode = .read_write,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        error.WouldBlock => return store.load(Job, arena, env.io, env.state_dir, file_name),
        else => return err,
    };
    defer lock.close(env.io);
    var job = store.load(Job, arena, env.io, env.state_dir, file_name) orelse return null;
    if (!job.done) {
        job.done = true;
        job.justification = null;
        job.failure = "The background worker stopped. Some requests may have reached Azure; refresh roles before retrying.";
        try store.save(Job, env.io, env.state_dir, file_name, job);
    }
    return job;
}

pub fn run(session: *session_mod.Session, id: []const u8) !void {
    const env = session.env;
    var job = store.load(Job, session.arena, env.io, env.state_dir, file_name) orelse return error.NoJob;
    if (job.done or !std.mem.eql(u8, job.id, id)) return error.NoJob;
    const justification = job.justification orelse "";
    job.justification = null;
    try store.save(Job, env.io, env.state_dir, file_name, job);

    var diag: session_mod.Diagnostics = .{};
    execute(session, &job, justification, &diag) catch |err| {
        job.failure = try errors.summaryAlloc(session.arena, err, diag);
    };
    job.done = true;
    try store.save(Job, env.io, env.state_dir, file_name, job);
    const notification = try describeNotification(session.arena, job);
    herdr.Notifier.fromEnv(env.environ).show(session.arena, env.io, notification.title, notification.body) catch |err|
        std.log.warn("cannot notify about background operation: {t}", .{err});
}

fn execute(session: *session_mod.Session, job: *Job, justification: []const u8, diag: *session_mod.Diagnostics) errors.Error!void {
    const arena = session.arena;
    const io = session.env.io;
    const submissions = switch (job.intent) {
        .activate => blk: {
            const plans = try activation.plan(session, arena, job.targets, job.duration_min, diag);
            break :blk try activation.activate(session, arena, plans, justification, std.Io.Clock.real.now(io).toSeconds(), diag);
        },
        .deactivate => try activation.deactivate(session, arena, job.targets, diag),
    };
    const settling = for (submissions) |s| {
        if (s.settlesAutomatically()) break true;
    } else false;

    var lines: std.ArrayList(messages.Line) = .empty;
    var problems: std.ArrayList(messages.Line) = .empty;
    var still_applying = false;
    if (settling) {
        if (activation.awaitSettled(session, arena, submissions, job.intent, 120, diag)) |settled| {
            still_applying = !settled;
        } else |err| {
            try problems.append(arena, try problemLine(arena, "Could not confirm the change", err, diag.*));
        }
    }
    const now = std.Io.Clock.real.now(io).toSeconds();
    const rows: []const rows_mod.Row = if (service.refresh(session, arena, now, diag)) |snapshot|
        try rows_mod.build(arena, snapshot, now)
    else |err| blk: {
        try problems.append(arena, try problemLine(arena, "Could not refresh roles", err, diag.*));
        break :blk &.{};
    };
    for (submissions) |s|
        try lines.append(arena, try messages.describeOutcome(arena, s, job.intent, messages.findRow(rows, s.row), now));
    try lines.appendSlice(arena, problems.items);
    if (still_applying) try lines.append(arena, .{ .kind = .info, .glyph = "...", .text = "Azure is still applying some changes; press ^r to refresh." });
    job.lines = lines.items;
}

fn problemLine(arena: std.mem.Allocator, what: []const u8, err: errors.Error, diag: session_mod.Diagnostics) std.mem.Allocator.Error!messages.Line {
    return .{
        .kind = .info,
        .glyph = "!",
        .text = try std.fmt.allocPrint(arena, "{s}: {s}. Press ^r to refresh.", .{ what, try errors.summaryAlloc(arena, err, diag) }),
    };
}

fn describeNotification(arena: std.mem.Allocator, job: Job) !messages.Notification {
    const action = if (job.intent == .activate) "activation" else "deactivation";
    if (job.failure) |failure| return .{
        .title = try std.fmt.allocPrint(arena, "PIM {s} failed", .{action}),
        .body = failure,
    };
    var failed: usize = 0;
    var pending: usize = 0;
    var uncertain = false;
    for (job.lines) |line| switch (line.kind) {
        .failed => failed += 1,
        .pending => pending += 1,
        .info => uncertain = true,
        .ok => {},
    };
    return .{
        .title = try std.fmt.allocPrint(arena, "PIM {s} {s}", .{ action, if (failed > 0) "had failures" else if (pending > 0 or uncertain) "needs attention" else "complete" }),
        .body = if (job.lines.len == 1) job.lines[0].text else try std.fmt.allocPrint(arena, "{d} roles: {d} failed, {d} pending. Open the PIM picker for details.", .{ job.targets.len, failed, pending }),
    };
}

const testing = std.testing;

fn testJob() Job {
    return .{ .id = "test", .intent = .activate, .targets = &.{}, .duration_min = 60, .started_at = 1 };
}

test "job lock excludes duplicate operations and detects a lost worker" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    const lock = try acquire(io, dir);
    var closed = false;
    defer if (!closed) lock.close(io);
    var job = testJob();
    job.justification = "private reason";
    try store.save(Job, io, dir, file_name, job);
    try testing.expectError(error.OperationInProgress, acquire(io, dir));
    try testing.expect(!(try load(arena, env)).?.done);
    lock.close(io);
    closed = true;
    const lost = (try load(arena, env)).?;
    try testing.expect(lost.done and lost.failure != null and lost.justification == null);
    try testing.expect((store.load(Job, arena, io, dir, file_name) orelse return error.TestExpectedJob).done);
}

test "worker inherits the lock after its parent releases its handle" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const lock = try acquire(io, dir);
    var child = std.process.spawn(io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdin = .{ .file = lock },
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch |err| {
        lock.close(io);
        return err;
    };
    lock.close(io);
    defer child.kill(io);
    try testing.expectError(error.OperationInProgress, acquire(io, dir));
    child.kill(io);
    const available = try acquire(io, dir);
    available.close(io);
}

test "completed results survive an unlocked worker without being marked interrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var environ: std.process.Environ.Map = .init(arena);
    const env: session_mod.Env = .{ .io = io, .gpa = testing.allocator, .environ = &environ, .state_dir = dir };
    const lock = try acquire(io, dir);
    lock.close(io);
    var job = testJob();
    job.done = true;
    job.lines = &.{.{ .kind = .ok, .glyph = "*", .text = "Owner: active" }};
    try store.save(Job, io, dir, file_name, job);
    const completed = (try load(arena, env)).?;
    try testing.expect(completed.done and completed.failure == null);
    try testing.expectEqualStrings("Owner: active", completed.lines[0].text);
}

test "completion notifications distinguish failures, pending and success" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var job = testJob();
    job.lines = &.{.{ .kind = .ok, .glyph = "", .text = "active" }};
    try testing.expectEqualStrings("PIM activation complete", (try describeNotification(arena, job)).title);
    job.lines = &.{.{ .kind = .pending, .glyph = "", .text = "awaiting approval" }};
    try testing.expectEqualStrings("PIM activation needs attention", (try describeNotification(arena, job)).title);
    job.lines = &.{.{ .kind = .failed, .glyph = "", .text = "rejected" }};
    try testing.expectEqualStrings("PIM activation had failures", (try describeNotification(arena, job)).title);
    job.failure = "not signed in";
    try testing.expectEqualStrings("not signed in", (try describeNotification(arena, job)).body);
}
