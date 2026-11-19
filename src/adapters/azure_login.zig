//! Interactive Azure CLI login without taking over the picker's terminal.
//! Only the device code is forwarded to the UI; CLI output stays in memory.
const std = @import("std");
const deadline = @import("../platform/deadline.zig");

pub const Method = enum { browser, device_code };
pub const device_url = "https://microsoft.com/devicelogin";

pub const DeviceCode = struct {
    bytes: [32]u8 = undefined,
    len: usize = 0,

    pub fn text(code: *const DeviceCode) []const u8 {
        return code.bytes[0..code.len];
    }
};

pub const Progress = struct {
    context: *anyopaque,
    update: *const fn (*anyopaque, DeviceCode) void,
};

pub fn login(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, method: Method, progress: Progress) !void {
    try deadline.call(io, .fromSeconds(10 * 60), run, .{ arena, io, environ, method, progress });
}

fn run(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, method: Method, progress: Progress) !void {
    try runExecutable(arena, io, environ, method, progress, "az");
}

fn runExecutable(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, method: Method, progress: Progress, exe: []const u8) !void {
    var child_env = try environ.clone(arena);
    try child_env.put("AZURE_CORE_COLLECT_TELEMETRY", "false");
    try child_env.put("AZURE_CORE_NO_COLOR", "true");
    try child_env.put("AZURE_CORE_ONLY_SHOW_ERRORS", "false");
    // Avoid the CLI's terminal subscription selector after authentication.
    try child_env.put("AZURE_CORE_LOGIN_EXPERIENCE_V2", "off");

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(arena, &.{ exe, "login", "--output", "none", "--allow-no-subscriptions" });
    if (method == .device_code) try argv.append(arena, "--use-device-code");
    if (try currentTenant(arena, io, &child_env, exe)) |tenant|
        try argv.appendSlice(arena, &.{ "--tenant", tenant });

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .environ_map = &child_env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.AzCliNotFound,
        else => return err,
    };
    defer child.kill(io);

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(arena, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    var last: ?DeviceCode = null;
    while (reader.fill(4096, .none)) |_| {
        for (0..2) |i| {
            const output = reader.reader(i).buffered();
            if (output.len > 64 * 1024) return error.StreamTooLong;
            if (parseDeviceCode(output)) |code| {
                if (last == null or !std.mem.eql(u8, last.?.text(), code.text())) {
                    progress.update(progress.context, code);
                    last = code;
                }
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    try reader.checkAnyError();
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.SignInFailed,
        else => return error.SignInFailed,
    }
}

fn currentTenant(arena: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map, exe: []const u8) !?[]const u8 {
    const result = std.process.run(arena, io, .{
        .argv = &.{ exe, "account", "show", "--query", "tenantId", "--output", "tsv" },
        .environ_map = environ,
        .stdout_limit = .limited(1024),
        .stderr_limit = .limited(4096),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    }) catch |err| switch (err) {
        error.Canceled => return err,
        error.FileNotFound => return error.AzCliNotFound,
        else => return null,
    };
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return null;
    const tenant = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (tenant.len == 0 or tenant.len > 253) return null;
    for (tenant) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '.') return null;
    return tenant;
}

fn parseDeviceCode(output: []const u8) ?DeviceCode {
    const url = std.mem.indexOf(u8, output, device_url) orelse return null;
    const after_url = output[url + device_url.len ..];
    const marker = "enter the code ";
    const start = (std.mem.indexOf(u8, after_url, marker) orelse return null) + marker.len;
    const rest = after_url[start..];
    const end = std.mem.indexOfAny(u8, rest, " \r\n\t.") orelse return null;
    if (end < 6 or end > 32) return null;
    for (rest[0..end]) |c| if (!std.ascii.isUpper(c) and !std.ascii.isDigit(c) and c != '-') return null;
    var code: DeviceCode = .{ .len = end };
    @memcpy(code.bytes[0..end], rest[0..end]);
    return code;
}

const testing = std.testing;

test "device instructions are extracted from streamed CLI output without arbitrary text" {
    const output = "To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code ABCD12345 to authenticate.";
    try testing.expectEqualStrings("ABCD12345", parseDeviceCode(output).?.text());
    try testing.expect(parseDeviceCode("enter the code ABCD12345 to authenticate") == null);
    try testing.expect(parseDeviceCode("https://microsoft.com/devicelogin and enter the code ABCD12") == null);
    try testing.expect(parseDeviceCode("https://microsoft.com/devicelogin and enter the code bad\x1b[2J text") == null);
}

const Recorder = struct {
    code: ?DeviceCode = null,
    seen_at: i128 = 0,

    fn update(context: *anyopaque, code: DeviceCode) void {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        recorder.code = code;
        recorder.seen_at = std.Io.Clock.awake.now(testing.io).toNanoseconds();
    }

    fn progress(recorder: *Recorder) Progress {
        return .{ .context = recorder, .update = update };
    }
};

test "browser and device login preserve tenant and stream instructions before exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "az",
        .flags = .{ .permissions = .fromMode(0o700) },
        .data =
        \\#!/bin/sh
        \\if [ "$1" = account ]; then printf 'tenant.example\n'; exit 0; fi
        \\[ "$AZURE_CORE_LOGIN_EXPERIENCE_V2" = off ] || exit 3
        \\[ "$AZURE_CORE_COLLECT_TELEMETRY" = false ] || exit 4
        \\case "$*" in *"--tenant tenant.example"*) ;; *) exit 5 ;; esac
        \\case "$*" in *"--output none"*) ;; *) exit 6 ;; esac
        \\case "$*" in
        \\  *--use-device-code*) [ "$EXPECT_DEVICE" = yes ] || exit 7 ;;
        \\  *) [ "$EXPECT_DEVICE" = no ] || exit 8 ;;
        \\esac
        \\printf 'https://microsoft.com/devicelogin and enter the code ABCD' >&2
        \\/bin/sleep 0.05
        \\printf '12345 to authenticate.' >&2
        \\/bin/sleep 0.1
        \\
        ,
    });
    const exe = try tmp.dir.realPathFileAlloc(io, "az", arena);
    var environ: std.process.Environ.Map = .init(arena);
    for ([_]Method{ .browser, .device_code }) |method| {
        try environ.put("EXPECT_DEVICE", if (method == .device_code) "yes" else "no");
        var recorder: Recorder = .{};
        try runExecutable(arena, io, &environ, method, recorder.progress(), exe);
        try testing.expectEqualStrings("ABCD12345", recorder.code.?.text());
        try testing.expect(std.Io.Clock.awake.now(io).toNanoseconds() - recorder.seen_at >= 50 * std.time.ns_per_ms);
    }
}

test "login failures and cancellation return without taking over the terminal" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;
    var environ: std.process.Environ.Map = .init(arena);
    var recorder: Recorder = .{};
    const exe = try std.fs.path.join(arena, &.{ try tmp.dir.realPathFileAlloc(io, ".", arena), "az" });
    try tmp.dir.writeFile(io, .{
        .sub_path = "az",
        .flags = .{ .permissions = .fromMode(0o700) },
        .data = "#!/bin/sh\nexit 1\n",
    });
    try testing.expectError(error.SignInFailed, runExecutable(arena, io, &environ, .browser, recorder.progress(), exe));
    try tmp.dir.writeFile(io, .{
        .sub_path = "az",
        .flags = .{ .permissions = .fromMode(0o700) },
        .data = "#!/bin/sh\nif [ \"$1\" = account ]; then exit 1; fi\nexec /bin/sleep 30\n",
    });
    const start = std.Io.Clock.awake.now(io);
    try testing.expectError(error.TimedOut, deadline.call(io, .fromMilliseconds(100), runExecutable, .{ arena, io, &environ, Method.device_code, recorder.progress(), exe }));
    try testing.expect(start.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 5_000);
}
