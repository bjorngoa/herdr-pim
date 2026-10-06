//! Picker state machine. Pure: inputs and async results go in, `Effect`s come
//! out for the app to perform, and nothing here touches the terminal or Azure.
const std = @import("std");
const rows_mod = @import("../domain/rows.zig");
const duration = @import("../domain/duration.zig");
const activation = @import("../app/activation.zig");
const messages = @import("../present/messages.zig");
const TextField = @import("text_field.zig").TextField;

const Row = rows_mod.Row;
const Allocator = std.mem.Allocator;

pub const Input = union(enum) {
    text: []const u8,
    backspace,
    delete_word,
    clear_line,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    tab,
    shift_tab,
    enter,
    escape,
    quit,
    deactivate,
    refresh,
};

pub const Mode = enum { browse, form, confirm_deactivate, progress };

/// Animation clock. The screen only redraws this often while something moves.
pub const tick_ms = 50;
pub const ticks_per_second = 1000 / tick_ms;

pub const Field = enum { justification, duration };

pub const ActivateJob = struct {
    targets: []Row,
    duration_min: u32,
    justification: []const u8,
};

/// Work for the app. Payload slices are owned by the receiver and must be
/// freed with `Model.gpa`.
pub const Effect = union(enum) {
    none,
    quit,
    refresh,
    load_policies: []Row,
    activate: ActivateJob,
    deactivate: []Row,
};

/// A one-line message that owns its text, so it never points into memory
/// that a background task may free.
pub const Notice = struct {
    pub const capacity = 240;

    kind: messages.Kind,
    buf: [capacity]u8 = undefined,
    len: usize = 0,

    /// Copies `source` onto one line: control characters become spaces, runs
    /// of spaces collapse, invalid UTF-8 becomes `?`, and overlong text is
    /// cut at a codepoint boundary.
    pub fn init(kind: messages.Kind, source: []const u8) Notice {
        var n: Notice = .{ .kind = kind };
        var pending_space = false;
        var i: usize = 0;
        while (i < source.len) {
            const len = std.unicode.utf8ByteSequenceLength(source[i]) catch 0;
            if (len == 0 or i + len > source.len) {
                i += 1;
                if (!n.append(&pending_space, "?")) break;
                continue;
            }
            const chunk = source[i .. i + len];
            i += len;
            const cp = std.unicode.utf8Decode(chunk) catch {
                if (!n.append(&pending_space, "?")) break;
                continue;
            };
            if (cp == ' ' or cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) {
                pending_space = n.len > 0;
                continue;
            }
            if (!n.append(&pending_space, chunk)) break;
        }
        return n;
    }

    pub fn text(self: *const Notice) []const u8 {
        return self.buf[0..self.len];
    }

    fn append(self: *Notice, pending_space: *bool, bytes: []const u8) bool {
        const space: usize = @intFromBool(pending_space.*);
        if (self.len + space + bytes.len > capacity) return false;
        if (pending_space.*) self.buf[self.len] = ' ';
        self.len += space;
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
        pending_space.* = false;
        return true;
    }
};

pub const Model = struct {
    gpa: Allocator,
    default_duration_min: u32,

    /// Borrowed from the app's current snapshot.
    rows: []const Row = &.{},
    fetched_at: ?i64 = null,
    refreshing: bool = false,
    /// Static label of the running operation.
    busy: ?[]const u8 = null,
    /// When the running operation started, in seconds; set by the app.
    busy_since: i64 = 0,
    /// Rows of the running operation. Owned; strings borrowed like `targets`.
    working: []Row = &.{},

    filter: TextField = .{},
    /// Indices into `rows` that match `filter`.
    visible: std.ArrayList(u32) = .empty,
    cursor: usize = 0,
    scroll: usize = 0,
    page_size: usize = 10,
    /// Eligibility schedule ids, owned.
    selected: std.StringArrayHashMapUnmanaged(void) = .empty,

    mode: Mode = .browse,
    /// Owned while a form or confirmation is open.
    targets: []Row = &.{},
    /// Borrowed from the app; matches `targets` when loaded.
    plans: []const activation.Plan = &.{},
    field: Field = .justification,
    justification: TextField = .{},
    duration_text: TextField = .{},

    notice: ?Notice = null,
    /// Outcome lines of the last operation, borrowed from the app.
    results: []const messages.Line = &.{},
    ticks: u32 = 0,

    pub fn init(gpa: Allocator, default_duration_min: u32) Model {
        return .{ .gpa = gpa, .default_duration_min = default_duration_min };
    }

    pub fn deinit(m: *Model) void {
        m.visible.deinit(m.gpa);
        m.clearSelection();
        m.selected.deinit(m.gpa);
        m.gpa.free(m.targets);
        m.gpa.free(m.working);
    }

    // ---- queries -----------------------------------------------------------

    pub fn currentRow(m: *const Model) ?Row {
        if (m.cursor >= m.visible.items.len) return null;
        return m.rows[m.visible.items[m.cursor]];
    }

    pub fn isSelected(m: *const Model, row: Row) bool {
        return m.selected.contains(row.eligibility.schedule_id);
    }

    /// Whether the running operation changes `row`.
    pub fn isWorking(m: *const Model, row: Row) bool {
        for (m.working) |w| {
            if (std.mem.eql(u8, w.eligibility.schedule_id, row.eligibility.schedule_id)) return true;
        }
        return false;
    }

    /// Unknown policies (not yet loaded or unreadable) count as requiring one.
    pub fn justificationRequired(m: *const Model) bool {
        if (!m.plansLoaded()) return true;
        for (m.plans) |p| if (p.needsJustification()) return true;
        return false;
    }

    pub fn plansLoaded(m: *const Model) bool {
        return m.plans.len > 0 and m.plans.len == m.targets.len;
    }

    // ---- async results -----------------------------------------------------

    /// Replaces the rows, keeping the cursor on the same role when possible and
    /// dropping selections that no longer exist.
    pub fn setRows(m: *Model, rows: []const Row, fetched_at: i64) Allocator.Error!void {
        const keep = if (m.currentRow()) |r| r.eligibility.schedule_id else null;
        m.rows = rows;
        m.fetched_at = fetched_at;
        m.refreshing = false;

        var i: usize = 0;
        while (i < m.selected.count()) {
            const id = m.selected.keys()[i];
            const exists = for (rows) |r| {
                if (std.mem.eql(u8, r.eligibility.schedule_id, id)) break true;
            } else false;
            if (exists) {
                i += 1;
            } else {
                m.gpa.free(id);
                m.selected.swapRemoveAt(i);
            }
        }
        try m.applyFilter(keep);
    }

    pub fn setNotice(m: *Model, kind: messages.Kind, text: []const u8) void {
        m.notice = .init(kind, text);
    }

    pub fn setRefreshFailed(m: *Model, text: []const u8) void {
        m.refreshing = false;
        m.setNotice(.failed, text);
    }

    /// Accepts policies only if they belong to the open form.
    pub fn setPolicies(m: *Model, plans: []const activation.Plan) void {
        if (m.mode != .form or plans.len != m.targets.len) return;
        for (plans, m.targets) |p, t| {
            if (!std.mem.eql(u8, p.row.eligibility.schedule_id, t.eligibility.schedule_id)) return;
        }
        m.plans = plans;
    }

    pub fn setResults(m: *Model, lines: []const messages.Line) void {
        m.endOperation();
        m.results = lines;
    }

    /// Clears the running operation and closes its progress view.
    pub fn endOperation(m: *Model) void {
        m.busy = null;
        m.gpa.free(m.working);
        m.working = &.{};
        if (m.mode == .progress) m.mode = .browse;
    }

    pub fn setPageSize(m: *Model, n: usize) void {
        m.page_size = @max(1, n);
        m.ensureCursorVisible();
    }

    /// Advances animations; returns whether the screen needs redrawing.
    pub fn tick(m: *Model) bool {
        m.ticks +%= 1;
        return m.busy != null or m.refreshing or m.ticks % ticks_per_second == 0;
    }

    // ---- input -------------------------------------------------------------

    pub fn update(m: *Model, input: Input) Allocator.Error!Effect {
        if (input == .quit) return .quit;
        m.notice = null;
        return switch (m.mode) {
            .browse => m.updateBrowse(input),
            .form => m.updateForm(input),
            .confirm_deactivate => m.updateConfirm(input),
            .progress => m.updateProgress(input),
        };
    }

    fn updateBrowse(m: *Model, input: Input) Allocator.Error!Effect {
        switch (input) {
            .text => |t| try m.editFilter(.{ .insert = t }),
            .backspace => try m.editFilter(.backspace),
            .delete_word => try m.editFilter(.delete_word),
            .clear_line => try m.editFilter(.clear),
            .up => m.moveBy(-1),
            .down => m.moveBy(1),
            .page_up => m.moveBy(-@as(isize, @intCast(m.page_size))),
            .page_down => m.moveBy(@intCast(m.page_size)),
            .home => m.moveBy(std.math.minInt(isize) / 2),
            .end => m.moveBy(std.math.maxInt(isize) / 2),
            .tab => {
                try m.toggleCurrent();
                m.moveBy(1);
            },
            .shift_tab => {
                try m.toggleCurrent();
                m.moveBy(-1);
            },
            .enter => return m.beginActivate(),
            .deactivate => return m.beginDeactivate(),
            .refresh => if (!m.refreshing) {
                m.refreshing = true;
                return .refresh;
            },
            .escape => {
                if (!m.filter.isEmpty()) {
                    try m.editFilter(.clear);
                } else if (m.selected.count() > 0) {
                    m.clearSelection();
                } else return .quit;
            },
            .quit => unreachable,
        }
        return .none;
    }

    fn updateForm(m: *Model, input: Input) Allocator.Error!Effect {
        const field = switch (m.field) {
            .justification => &m.justification,
            .duration => &m.duration_text,
        };
        switch (input) {
            .text => |t| field.insert(t),
            .backspace => field.backspace(),
            .delete_word => field.deleteWord(),
            .clear_line => field.clear(),
            .tab, .shift_tab, .up, .down => m.field = if (m.field == .duration) .justification else .duration,
            .enter => {
                if (m.field == .duration) {
                    m.field = .justification;
                } else return m.submitActivate();
            },
            .escape => m.closeOverlay(),
            else => {},
        }
        return .none;
    }

    fn updateConfirm(m: *Model, input: Input) Allocator.Error!Effect {
        switch (input) {
            .text => |t| {
                if (std.ascii.eqlIgnoreCase(t, "y")) return m.submitDeactivate();
                if (std.ascii.eqlIgnoreCase(t, "n")) m.closeOverlay();
            },
            .enter => return m.submitDeactivate(),
            .escape => m.closeOverlay(),
            else => {},
        }
        return .none;
    }

    /// The operation keeps running; escape only hides its progress view.
    fn updateProgress(m: *Model, input: Input) Effect {
        if (input == .escape) m.mode = .browse;
        return .none;
    }

    fn beginActivate(m: *Model) Allocator.Error!Effect {
        if (m.busy != null) return m.showBusy();
        const targets = try m.collectTargets(.eligible);
        if (targets.len == 0) {
            m.gpa.free(targets);
            m.setNotice(.info, "Nothing to activate: choose an eligible role (○).");
            return .none;
        }
        errdefer m.gpa.free(targets);
        const payload = try m.gpa.dupe(Row, targets);
        m.targets = targets;
        m.plans = &.{};
        m.mode = .form;
        m.field = .justification;
        var buf: [16]u8 = undefined;
        m.duration_text.set(duration.formatHuman(m.default_duration_min, &buf));
        return .{ .load_policies = payload };
    }

    fn beginDeactivate(m: *Model) Allocator.Error!Effect {
        if (m.busy != null) return m.showBusy();
        const targets = try m.collectTargets(.active);
        if (targets.len == 0) {
            m.gpa.free(targets);
            m.setNotice(.info, "Nothing to deactivate: choose an active role (●).");
            return .none;
        }
        m.targets = targets;
        m.mode = .confirm_deactivate;
        return .none;
    }

    fn submitActivate(m: *Model) Allocator.Error!Effect {
        const minutes = duration.parse(m.duration_text.text()) catch {
            m.setNotice(.failed, "Duration must look like 8h, 90m or 1h30m.");
            m.field = .duration;
            return .none;
        };
        const justification = std.mem.trim(u8, m.justification.text(), " ");
        if (justification.len == 0 and m.justificationRequired()) {
            m.setNotice(.failed, "A justification is required.");
            return .none;
        }
        const working = try m.gpa.dupe(Row, m.targets);
        errdefer m.gpa.free(working);
        const job: ActivateJob = .{
            .targets = m.targets,
            .duration_min = minutes,
            .justification = try m.gpa.dupe(u8, justification),
        };
        m.targets = &.{};
        m.closeOverlay();
        m.clearSelection();
        m.beginOperation("Activating", working);
        return .{ .activate = job };
    }

    fn submitDeactivate(m: *Model) Allocator.Error!Effect {
        const working = try m.gpa.dupe(Row, m.targets);
        const targets = m.targets;
        m.targets = &.{};
        m.closeOverlay();
        m.clearSelection();
        m.beginOperation("Deactivating", working);
        return .{ .deactivate = targets };
    }

    fn beginOperation(m: *Model, label: []const u8, working: []Row) void {
        m.busy = label;
        m.gpa.free(m.working);
        m.working = working;
        m.mode = .progress;
    }

    /// Brings back the progress view of the running operation.
    fn showBusy(m: *Model) Effect {
        m.setNotice(.info, "Wait for the current operation to finish.");
        m.mode = .progress;
        return .none;
    }

    fn closeOverlay(m: *Model) void {
        m.gpa.free(m.targets);
        m.targets = &.{};
        m.plans = &.{};
        m.mode = .browse;
    }

    /// Selected rows in `state`, or the current row if nothing is selected.
    fn collectTargets(m: *Model, state: rows_mod.State) Allocator.Error![]Row {
        var out: std.ArrayList(Row) = .empty;
        errdefer out.deinit(m.gpa);
        if (m.selected.count() > 0) {
            for (m.rows) |r| if (r.state == state and m.isSelected(r)) try out.append(m.gpa, r);
        } else if (m.currentRow()) |r| {
            if (r.state == state) try out.append(m.gpa, r);
        }
        return out.toOwnedSlice(m.gpa);
    }

    fn toggleCurrent(m: *Model) Allocator.Error!void {
        const row = m.currentRow() orelse return;
        const id = row.eligibility.schedule_id;
        if (m.selected.fetchSwapRemove(id)) |kv| {
            m.gpa.free(kv.key);
            return;
        }
        const owned = try m.gpa.dupe(u8, id);
        errdefer m.gpa.free(owned);
        try m.selected.put(m.gpa, owned, {});
    }

    fn clearSelection(m: *Model) void {
        for (m.selected.keys()) |k| m.gpa.free(k);
        m.selected.clearRetainingCapacity();
    }

    const FilterEdit = union(enum) { insert: []const u8, backspace, delete_word, clear };

    fn editFilter(m: *Model, edit: FilterEdit) Allocator.Error!void {
        switch (edit) {
            .insert => |t| m.filter.insert(t),
            .backspace => m.filter.backspace(),
            .delete_word => m.filter.deleteWord(),
            .clear => m.filter.clear(),
        }
        try m.applyFilter(null);
    }

    /// Recomputes `visible`. The cursor moves to `keep` if it is still
    /// visible, else to the top.
    fn applyFilter(m: *Model, keep: ?[]const u8) Allocator.Error!void {
        var terms_buf: [16][]const u8 = undefined;
        var terms: std.ArrayList([]const u8) = .initBuffer(&terms_buf);
        var it = std.mem.tokenizeScalar(u8, m.filter.text(), ' ');
        while (it.next()) |t| terms.appendBounded(t) catch break;

        m.visible.clearRetainingCapacity();
        m.cursor = 0;
        for (m.rows, 0..) |row, i| {
            if (!rows_mod.matches(row, terms.items)) continue;
            if (keep) |id| if (std.mem.eql(u8, row.eligibility.schedule_id, id)) {
                m.cursor = m.visible.items.len;
            };
            try m.visible.append(m.gpa, @intCast(i));
        }
        if (keep == null) m.scroll = 0;
        m.ensureCursorVisible();
    }

    fn moveBy(m: *Model, delta: isize) void {
        if (m.visible.items.len == 0) return;
        const last: isize = @intCast(m.visible.items.len - 1);
        const target = std.math.clamp(@as(isize, @intCast(m.cursor)) +| delta, 0, last);
        m.cursor = @intCast(target);
        m.ensureCursorVisible();
    }

    fn ensureCursorVisible(m: *Model) void {
        const count = m.visible.items.len;
        if (count == 0) {
            m.cursor = 0;
            m.scroll = 0;
            return;
        }
        if (m.cursor >= count) m.cursor = count - 1;
        if (m.cursor < m.scroll) m.scroll = m.cursor;
        if (m.cursor >= m.scroll + m.page_size) m.scroll = m.cursor + 1 - m.page_size;
        m.scroll = @min(m.scroll, count -| m.page_size);
    }
};

const testing = std.testing;

fn testRow(id: []const u8, scope_name: []const u8, state: rows_mod.State) Row {
    return .{
        .eligibility = .{ .schedule_id = id, .scope = "", .scope_name = scope_name, .role_definition_id = "", .role_name = "Contributor" },
        .subscription_name = "Sub",
        .state = state,
    };
}

const fixture = [_]Row{
    testRow("e1", "rg-app-dev", .eligible),
    testRow("e2", "rg-app-test", .eligible),
    testRow("a1", "rg-app-prod", .active),
    testRow("e3", "rg-data-dev", .eligible),
};

fn loaded() !Model {
    var m: Model = .init(testing.allocator, 480);
    errdefer m.deinit();
    try m.setRows(&fixture, 0);
    return m;
}

fn freeEffect(effect: Effect) void {
    switch (effect) {
        .load_policies, .deactivate => |rows| testing.allocator.free(rows),
        .activate => |job| {
            testing.allocator.free(job.targets);
            testing.allocator.free(job.justification);
        },
        .none, .quit, .refresh => {},
    }
}

fn press(m: *Model, input: Input) !Effect {
    return m.update(input);
}

test "typing filters rows and resets the cursor" {
    var m = try loaded();
    defer m.deinit();
    _ = try press(&m, .down);
    _ = try press(&m, .{ .text = "dev" });
    try testing.expectEqual(@as(usize, 2), m.visible.items.len);
    try testing.expectEqual(@as(usize, 0), m.cursor);
    _ = try press(&m, .{ .text = " data" });
    try testing.expectEqualStrings("rg-data-dev", m.currentRow().?.eligibility.scope_name);
    _ = try press(&m, .escape);
    try testing.expectEqual(@as(usize, 4), m.visible.items.len);
}

test "cursor movement clamps and scrolls with the page" {
    var m = try loaded();
    defer m.deinit();
    m.setPageSize(2);
    _ = try press(&m, .up);
    try testing.expectEqual(@as(usize, 0), m.cursor);
    _ = try press(&m, .end);
    try testing.expectEqual(@as(usize, 3), m.cursor);
    try testing.expectEqual(@as(usize, 2), m.scroll);
    _ = try press(&m, .page_up);
    try testing.expectEqual(@as(usize, 1), m.cursor);
    try testing.expectEqual(@as(usize, 1), m.scroll);
    _ = try press(&m, .home);
    try testing.expectEqual(@as(usize, 0), m.scroll);
}

test "enter opens the form for the current eligible row and requests policies" {
    var m = try loaded();
    defer m.deinit();
    const effect = try press(&m, .enter);
    defer freeEffect(effect);
    try testing.expectEqual(Mode.form, m.mode);
    try testing.expectEqual(@as(usize, 1), effect.load_policies.len);
    try testing.expectEqualStrings("8h", m.duration_text.text());
    try testing.expect(m.justificationRequired());
}

test "enter on an active row explains instead of opening the form" {
    var m = try loaded();
    defer m.deinit();
    _ = try press(&m, .{ .text = "prod" });
    try testing.expectEqual(Effect.none, try press(&m, .enter));
    try testing.expectEqual(Mode.browse, m.mode);
    try testing.expect(m.notice != null);
}

test "tab selects several rows and activation targets only eligible ones" {
    var m = try loaded();
    defer m.deinit();
    _ = try press(&m, .tab);
    _ = try press(&m, .tab);
    _ = try press(&m, .tab);
    try testing.expectEqual(@as(usize, 3), m.selected.count());

    const open = try press(&m, .enter);
    defer freeEffect(open);
    try testing.expectEqual(@as(usize, 2), m.targets.len);

    _ = try press(&m, .{ .text = "fix incident" });
    const submit = try press(&m, .enter);
    defer freeEffect(submit);
    try testing.expectEqual(@as(usize, 2), submit.activate.targets.len);
    try testing.expectEqual(@as(u32, 480), submit.activate.duration_min);
    try testing.expectEqualStrings("fix incident", submit.activate.justification);
    try testing.expectEqual(@as(usize, 0), m.selected.count());
    try testing.expect(m.busy != null);
    try testing.expectEqual(Mode.progress, m.mode);
    try testing.expectEqual(@as(usize, 2), m.working.len);
}

test "form validates duration and required justification" {
    var m = try loaded();
    defer m.deinit();
    const open = try press(&m, .enter);
    defer freeEffect(open);

    try testing.expectEqual(Effect.none, try press(&m, .enter));
    try testing.expectEqual(messages.Kind.failed, m.notice.?.kind);

    _ = try press(&m, .tab);
    try testing.expectEqual(Field.duration, m.field);
    _ = try press(&m, .clear_line);
    _ = try press(&m, .{ .text = "forever" });
    _ = try press(&m, .tab);
    _ = try press(&m, .{ .text = "x" });
    try testing.expectEqual(Effect.none, try press(&m, .enter));
    try testing.expectEqual(Field.duration, m.field);

    _ = try press(&m, .clear_line);
    _ = try press(&m, .{ .text = "1h" });
    _ = try press(&m, .enter);
    const submit = try press(&m, .enter);
    defer freeEffect(submit);
    try testing.expectEqual(@as(u32, 60), submit.activate.duration_min);
}

test "policies that need no justification allow an empty one" {
    var m = try loaded();
    defer m.deinit();
    const open = try press(&m, .enter);
    defer freeEffect(open);
    const plans = [_]activation.Plan{.{ .row = m.targets[0], .policy = .{}, .duration = .{ .minutes = 480, .clamped = false } }};
    m.setPolicies(&plans);
    try testing.expect(!m.justificationRequired());
    const submit = try press(&m, .enter);
    defer freeEffect(submit);
    try testing.expect(submit == .activate);
}

test "stale policies for another form are ignored" {
    var m = try loaded();
    defer m.deinit();
    const open = try press(&m, .enter);
    defer freeEffect(open);
    const other = [_]activation.Plan{.{ .row = fixture[1], .policy = .{}, .duration = .{ .minutes = 480, .clamped = false } }};
    m.setPolicies(&other);
    try testing.expect(!m.plansLoaded());
}

test "ctrl-d asks for confirmation before deactivating" {
    var m = try loaded();
    defer m.deinit();
    _ = try press(&m, .{ .text = "prod" });
    try testing.expectEqual(Effect.none, try press(&m, .deactivate));
    try testing.expectEqual(Mode.confirm_deactivate, m.mode);
    _ = try press(&m, .{ .text = "n" });
    try testing.expectEqual(Mode.browse, m.mode);

    _ = try press(&m, .deactivate);
    const effect = try press(&m, .{ .text = "y" });
    defer freeEffect(effect);
    try testing.expectEqual(@as(usize, 1), effect.deactivate.len);
    try testing.expectEqualStrings("Deactivating", m.busy.?);
}

test "busy operations block new ones and bring back the progress view" {
    var m = try loaded();
    defer m.deinit();
    m.busy = "Activating";
    try testing.expectEqual(Effect.none, try press(&m, .enter));
    try testing.expectEqual(Mode.progress, m.mode);
    try testing.expect(m.notice != null);
}

test "progress view lasts until results arrive and escape only hides it" {
    var m = try loaded();
    defer m.deinit();
    const open = try press(&m, .enter);
    defer freeEffect(open);
    _ = try press(&m, .{ .text = "deploy" });
    const submit = try press(&m, .enter);
    defer freeEffect(submit);
    try testing.expectEqual(Mode.progress, m.mode);
    try testing.expect(m.isWorking(fixture[0]));
    try testing.expect(!m.isWorking(fixture[1]));

    try testing.expectEqual(Effect.none, try press(&m, .down));
    try testing.expectEqual(@as(usize, 0), m.cursor);
    try testing.expectEqual(Effect.none, try press(&m, .escape));
    try testing.expectEqual(Mode.browse, m.mode);
    try testing.expect(m.busy != null);

    m.setResults(&.{});
    try testing.expect(m.busy == null);
    try testing.expectEqual(@as(usize, 0), m.working.len);
    try testing.expectEqual(Mode.browse, m.mode);
}

test "results close a visible progress view" {
    var m = try loaded();
    defer m.deinit();
    _ = try press(&m, .{ .text = "prod" });
    _ = try press(&m, .deactivate);
    const effect = try press(&m, .enter);
    defer freeEffect(effect);
    try testing.expectEqual(Mode.progress, m.mode);
    try testing.expect(m.isWorking(fixture[2]));
    m.setResults(&.{});
    try testing.expectEqual(Mode.browse, m.mode);
}

test "ticks redraw continuously only while something animates" {
    var m = try loaded();
    defer m.deinit();
    var redraws: usize = 0;
    for (0..ticks_per_second * 3) |_| redraws += @intFromBool(m.tick());
    try testing.expectEqual(@as(usize, 3), redraws);

    m.refreshing = true;
    try testing.expect(m.tick());
    m.refreshing = false;
    m.busy = "Activating";
    try testing.expect(m.tick());
}

test "refresh is requested once until rows arrive" {
    var m = try loaded();
    defer m.deinit();
    try testing.expectEqual(Effect.refresh, try press(&m, .refresh));
    try testing.expectEqual(Effect.none, try press(&m, .refresh));
    try m.setRows(&fixture, 1);
    try testing.expectEqual(Effect.refresh, try press(&m, .refresh));
}

test "setRows keeps the cursor on the same role and prunes selections" {
    var m = try loaded();
    defer m.deinit();
    _ = try press(&m, .tab);
    _ = try press(&m, .down);
    try testing.expectEqualStrings("a1", m.currentRow().?.eligibility.schedule_id);

    const reordered = [_]Row{ fixture[2], fixture[3] };
    try m.setRows(&reordered, 1);
    try testing.expectEqualStrings("a1", m.currentRow().?.eligibility.schedule_id);
    try testing.expectEqual(@as(usize, 0), m.selected.count());
}

test "notices own their text and stay on one line" {
    var m = try loaded();
    defer m.deinit();
    const owned = try testing.allocator.dupe(u8, "could not reach Azure\n     az: \x1b[31mtimeout\xff");
    m.setRefreshFailed(owned);
    testing.allocator.free(owned);
    try testing.expectEqualStrings("could not reach Azure az: [31mtimeout?", m.notice.?.text());

    const long = "x" ** (Notice.capacity + 10);
    try testing.expectEqual(Notice.capacity, Notice.init(.info, long).text().len);
    try testing.expectEqualStrings("a b", Notice.init(.info, "  a \t\n b  ").text());
}

test "escape clears filter, then selection, then quits" {
    var m = try loaded();
    defer m.deinit();
    _ = try press(&m, .tab);
    _ = try press(&m, .{ .text = "x" });
    try testing.expectEqual(Effect.none, try press(&m, .escape));
    try testing.expectEqual(Effect.none, try press(&m, .escape));
    try testing.expectEqual(@as(usize, 0), m.selected.count());
    try testing.expectEqual(Effect.quit, try press(&m, .escape));
    try testing.expectEqual(Effect.quit, try press(&m, .quit));
}
