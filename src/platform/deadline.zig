//! Runs a call with a deadline. The call and a timer race in an `Io.Select`;
//! whichever finishes second is canceled and waited for, so nothing outlives
//! `call`.
const std = @import("std");

pub const TimedOut = error{TimedOut};

pub fn Result(comptime function: anytype) type {
    const Return = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const info = @typeInfo(Return).error_union;
    return (info.error_set || TimedOut || std.Io.Cancelable)!info.payload;
}

/// Calls `function(args)` and returns its result, or `error.TimedOut` once
/// `timeout` has passed. Without concurrency support the call runs inline
/// with no deadline. `function` must reach cancelation points (any `Io`
/// operation) for a timeout to take effect promptly.
pub fn call(
    io: std.Io,
    timeout: std.Io.Duration,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Result(function) {
    const Outcome = union(enum) {
        done: @typeInfo(@TypeOf(function)).@"fn".return_type.?,
        expired: std.Io.Cancelable!void,
    };
    var slots: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &slots);
    defer select.cancelDiscard();

    select.concurrent(.done, function, args) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return @call(.auto, function, args),
    };
    select.concurrent(.expired, sleep, .{ io, timeout }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {},
    };

    return switch (try select.await()) {
        .done => |result| result,
        .expired => |slept| {
            try slept;
            return error.TimedOut;
        },
    };
}

fn sleep(io: std.Io, duration: std.Io.Duration) std.Io.Cancelable!void {
    try io.sleep(duration, .awake);
}

const testing = std.testing;

fn quick(value: u32) error{Boom}!u32 {
    if (value == 0) return error.Boom;
    return value * 2;
}

fn slow(io: std.Io) std.Io.Cancelable!u32 {
    try io.sleep(.fromSeconds(30), .awake);
    return 1;
}

test "returns the result of a call that finishes in time" {
    try testing.expectEqual(@as(u32, 42), try call(testing.io, .fromSeconds(5), quick, .{21}));
    try testing.expectError(error.Boom, call(testing.io, .fromSeconds(5), quick, .{0}));
}

test "times out and cancels a call that takes too long" {
    const io = testing.io;
    const start = std.Io.Clock.awake.now(io);
    try testing.expectError(error.TimedOut, call(io, .fromMilliseconds(50), slow, .{io}));
    const elapsed = start.durationTo(std.Io.Clock.awake.now(io));
    try testing.expect(elapsed.toMilliseconds() < 5_000);
}
