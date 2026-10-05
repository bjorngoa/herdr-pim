//! Small versioned JSON documents in the state directory, written atomically
//! with owner-only permissions. `T` must have a `version: u32` field and a
//! `pub const schema_version: u32`; files with another version are ignored.
const std = @import("std");

const log = std.log.scoped(.store);

const max_bytes = 8 * 1024 * 1024;

const private_file: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;
const private_dir: std.Io.File.Permissions =
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o700) else .default_dir;

/// Returns the stored value, or null when it is missing, unreadable or of an
/// incompatible version. Memory is owned by `arena`.
pub fn load(comptime T: type, arena: std.mem.Allocator, io: std.Io, dir_path: []const u8, file_name: []const u8) ?T {
    const path = std.fs.path.join(arena, &.{ dir_path, file_name }) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| {
        if (err != error.FileNotFound) log.warn("cannot read {s}: {t}", .{ path, err });
        return null;
    };
    return decode(T, arena, bytes) catch |err| {
        log.warn("ignoring {s}: {t}", .{ path, err });
        return null;
    };
}

/// Atomically replaces the file, creating the directory if needed.
pub fn save(comptime T: type, io: std.Io, dir_path: []const u8, file_name: []const u8, value: T) !void {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{ .permissions = private_dir });
    defer dir.close(io);

    var atomic = try dir.createFileAtomic(io, file_name, .{ .permissions = private_file, .replace = true });
    defer atomic.deinit(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = atomic.file.writer(io, &buffer);
    try encode(T, value, &file_writer.interface);
    try file_writer.interface.flush();
    try atomic.replace(io);
}

pub const DecodeError = error{ IncompatibleVersion, InvalidDocument, OutOfMemory };

pub fn decode(comptime T: type, arena: std.mem.Allocator, bytes: []const u8) DecodeError!T {
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const Header = struct { version: u32 };
    const header = std.json.parseFromSliceLeaky(Header, arena, bytes, options) catch |err| return mapJsonError(err);
    if (header.version != T.schema_version) return error.IncompatibleVersion;
    return std.json.parseFromSliceLeaky(T, arena, bytes, options) catch |err| mapJsonError(err);
}

pub fn encode(comptime T: type, value: T, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, writer);
}

fn mapJsonError(err: anytype) DecodeError {
    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidDocument;
}

const testing = std.testing;

const Doc = struct {
    pub const schema_version: u32 = 2;
    version: u32 = schema_version,
    name: []const u8,
    count: ?i64 = null,
};

test "encode and decode round-trip" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    try encode(Doc, .{ .name = "a \"b\"" }, &out.writer);
    const doc = try decode(Doc, arena, out.written());
    try testing.expectEqualStrings("a \"b\"", doc.name);
    try testing.expect(doc.count == null);
}

test "decode rejects other versions and garbage" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectError(error.IncompatibleVersion, decode(Doc, arena, "{\"version\":1,\"name\":\"x\"}"));
    try testing.expectError(error.InvalidDocument, decode(Doc, arena, "{}"));
    try testing.expectError(error.InvalidDocument, decode(Doc, arena, "nope"));
}

test "save then load through the file system" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = testing.io;

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const dir = try std.fs.path.join(arena, &.{ root, "state", "pim" });

    try testing.expect(load(Doc, arena, io, dir, "doc.json") == null);
    try save(Doc, io, dir, "doc.json", .{ .name = "saved", .count = 3 });
    const doc = load(Doc, arena, io, dir, "doc.json") orelse return error.TestExpectedDocument;
    try testing.expectEqual(@as(?i64, 3), doc.count);
}
