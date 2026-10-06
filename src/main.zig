//! Composition root: parses arguments, wires adapters and runs a command.
const std = @import("std");
const build_options = @import("build_options");
const args = @import("cli/args.zig");
const commands = @import("cli/commands.zig");
const paths = @import("platform/paths.zig");
const env = @import("platform/env.zig");
const session_mod = @import("app/session.zig");
const log = @import("platform/log.zig");
const tui = @import("tui/app.zig");
const vaxis = @import("vaxis");

pub const std_options: std.Options = .{ .log_level = .warn, .logFn = log.logFn };

pub const panic = std.debug.FullPanic(restoreTerminalThenPanic);

/// Restores the terminal if the picker panics, then panics as usual.
fn restoreTerminalThenPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const exit_ok = 0;
const exit_failure = 1;
const exit_usage = 2;

pub fn main(init: std.process.Init) u8 {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    var stderr_buffer: [1024]u8 = undefined;
    var stderr: std.Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);

    const code = run(init, &stdout.interface, &stderr.interface);
    stdout.interface.flush() catch {};
    stderr.interface.flush() catch {};
    return code;
}

fn run(init: std.process.Init, stdout: *std.Io.Writer, stderr: *std.Io.Writer) u8 {
    const arena = init.arena.allocator();
    const argv = argStrings(arena, init.minimal.args) catch return exit_failure;

    var arg_diag: args.Diagnostics = .{};
    const command = args.parse(arena, argv, &arg_diag) catch |err| {
        const reason = switch (err) {
            error.UnknownCommand => "unknown command",
            error.UnknownOption => "unknown option",
            error.MissingValue => "missing value for",
            error.InvalidValue => "invalid value",
            error.MissingFilter => "FILTER (or --all for down) is required for",
            error.OutOfMemory => "out of memory",
        };
        stderr.print("pim: {s} '{s}'. See `pim help`.\n", .{ reason, arg_diag.arg }) catch {};
        return exit_usage;
    };

    switch (command) {
        .help => {
            stdout.writeAll(commands.help_text) catch {};
            return exit_ok;
        },
        .version => {
            stdout.print("pim {s}\n", .{build_options.version}) catch {};
            return exit_ok;
        },
        .pick, .list, .status, .up, .down => {},
    }

    const state_dir = paths.stateDir(arena, init.environ_map) catch |err| {
        stderr.print("pim: cannot determine state directory ({t}); set PIM_STATE_DIR.\n", .{err}) catch {};
        return exit_failure;
    };
    var session: session_mod.Session = .init(arena, .{
        .io = init.io,
        .gpa = init.gpa,
        .environ = init.environ_map,
        .state_dir = state_dir,
    });
    defer session.deinit();

    var stdin_buffer: [1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    const interactive = std.Io.File.stdin().isTty(init.io) catch false;

    const ctx: commands.Context = .{
        .session = &session,
        .stdout = stdout,
        .stderr = stderr,
        .stdin = if (interactive) &stdin.interface else null,
        .now = std.Io.Clock.real.now(init.io).toSeconds(),
        .color = useColor(init),
    };

    if (command == .pick) return runPicker(init, &session, command.pick, ctx, stderr);

    var diag: session_mod.Diagnostics = .{};
    const result = switch (command) {
        .list => |opts| commands.list(ctx, opts, &diag),
        .status => |opts| commands.status(ctx, opts, &diag),
        .up => |opts| commands.up(ctx, opts, &diag),
        .down => |opts| commands.down(ctx, opts, &diag),
        .pick, .help, .version => unreachable,
    };
    result catch |err| {
        stdout.flush() catch {};
        commands.reportError(stderr, err, diag) catch {};
        return exit_failure;
    };
    return exit_ok;
}

fn runPicker(init: std.process.Init, session: *session_mod.Session, opts: args.Pick, ctx: commands.Context, stderr: *std.Io.Writer) u8 {
    const terminal = (std.Io.File.stdin().isTty(init.io) catch false) and (std.Io.File.stdout().isTty(init.io) catch false);
    if (!terminal) {
        if (!opts.implicit) {
            stderr.writeAll("pim: the picker needs a terminal; use `pim ls` in scripts.\n") catch {};
            return exit_usage;
        }
        var diag: session_mod.Diagnostics = .{};
        commands.list(ctx, .{}, &diag) catch |err| {
            commands.reportError(stderr, err, diag) catch {};
            return exit_failure;
        };
        return exit_ok;
    }
    const filter = std.mem.join(session.arena, " ", opts.terms) catch return exit_failure;
    tui.run(init.gpa, init.io, init.environ_map, session, .{
        .default_duration_min = opts.duration_min,
        .initial_filter = filter,
        .progress_window = env.enabled(init.environ_map, env.progress_window),
    }) catch |err| {
        stderr.print("pim: the picker failed ({t}).\n", .{err}) catch {};
        return exit_failure;
    };
    return exit_ok;
}

fn argStrings(arena: std.mem.Allocator, process_args: std.process.Args) ![]const []const u8 {
    const raw = try process_args.toSlice(arena);
    const out = try arena.alloc([]const u8, raw.len -| 1);
    for (out, raw[1..]) |*dst, src| dst.* = src;
    return out;
}

fn useColor(init: std.process.Init) bool {
    if (init.environ_map.get("NO_COLOR")) |v| if (v.len > 0) return false;
    return std.Io.File.stdout().isTty(init.io) catch false;
}

test {
    _ = @import("domain/time.zig");
    _ = @import("domain/scope.zig");
    _ = @import("domain/role.zig");
    _ = @import("domain/rows.zig");
    _ = @import("domain/status.zig");
    _ = @import("domain/duration.zig");
    _ = @import("domain/selection.zig");
    _ = @import("adapters/arm/dto.zig");
    _ = @import("adapters/arm/client.zig");
    _ = @import("adapters/azcli.zig");
    _ = @import("adapters/snapshot_cache.zig");
    _ = @import("adapters/json_store.zig");
    _ = @import("adapters/herdr.zig");
    _ = @import("domain/alerts.zig");
    _ = @import("app/alerts_service.zig");
    _ = @import("platform/paths.zig");
    _ = @import("platform/env.zig");
    _ = @import("platform/deadline.zig");
    _ = @import("app/snapshot_service.zig");
    _ = @import("app/session.zig");
    _ = @import("app/activation.zig");
    _ = @import("cli/args.zig");
    _ = @import("cli/render.zig");
    _ = @import("cli/commands.zig");
    _ = @import("present/text.zig");
    _ = @import("present/messages.zig");
    _ = @import("present/errors.zig");
    _ = @import("tui/text_field.zig");
    _ = @import("tui/model.zig");
    _ = @import("tui/keymap.zig");
    _ = @import("tui/view.zig");
    _ = @import("tui/app.zig");
}
