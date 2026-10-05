//! Draws the picker. Stateless apart from telling the model how many rows fit.
//! All strings must live until the frame is rendered, so they are allocated
//! in the per-frame `arena`.
const std = @import("std");
const vaxis = @import("vaxis");
const rows_mod = @import("../domain/rows.zig");
const status_mod = @import("../domain/status.zig");
const duration = @import("../domain/duration.zig");
const time = @import("../domain/time.zig");
const activation = @import("../app/activation.zig");
const messages = @import("../present/messages.zig");
const text = @import("../present/text.zig");
const model_mod = @import("model.zig");

const Row = rows_mod.Row;
const Model = model_mod.Model;
const Window = vaxis.Window;
const Style = vaxis.Style;
const Allocator = std.mem.Allocator;

const accent: vaxis.Color = .{ .index = 4 };
const style_title: Style = .{ .bold = true, .reverse = true };
const style_dim: Style = .{ .dim = true };
const style_bold: Style = .{ .bold = true };
const style_selected: Style = .{ .fg = .{ .index = 6 }, .bold = true };

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

const header_rows = 3;
const max_result_lines = 4;

pub fn draw(arena: Allocator, win: Window, m: *Model, now: i64) Allocator.Error!void {
    win.clear();
    win.hideCursor();
    if (win.height < 6 or win.width < 30) {
        _ = win.printSegment(.{ .text = "Window too small" }, .{});
        return;
    }

    const footer = footerLines(m);
    const list_height = win.height -| (header_rows + footer);
    m.setPageSize(list_height);

    try drawHeader(arena, win, m, now);
    drawFilter(win, m);
    try drawList(arena, win.child(.{ .y_off = header_rows - 1, .height = list_height + 1 }), m, now);
    try drawFooter(arena, win.child(.{ .y_off = @intCast(win.height - footer), .height = footer }), m);

    switch (m.mode) {
        .browse => {},
        .form => try drawForm(arena, win, m),
        .confirm_deactivate => try drawConfirm(arena, win, m),
    }
}

fn footerLines(m: *const Model) u16 {
    const notice: u16 = @intFromBool(m.notice != null);
    return 1 + notice + @as(u16, @intCast(@min(m.results.len, max_result_lines)));
}

fn drawHeader(arena: Allocator, win: Window, m: *const Model, now: i64) Allocator.Error!void {
    const summary = status_mod.summarize(m.rows);
    var col = print(win, 0, 0, " PIM ", style_title);
    const counts = try std.fmt.allocPrint(arena, "  {d} roles · ", .{m.rows.len});
    col = print(win, 0, col, counts, .{});
    col = print(win, 0, col, try std.fmt.allocPrint(arena, "● {d} active", .{summary.active}), .{ .fg = .{ .index = 2 } });
    if (summary.pending > 0) {
        col = print(win, 0, col, " · ", .{});
        _ = print(win, 0, col, try std.fmt.allocPrint(arena, "◐ {d} pending", .{summary.pending}), .{ .fg = .{ .index = 3 } });
    }

    const right = if (m.busy) |label|
        try std.fmt.allocPrint(arena, "{s} {s}… ", .{ spinner[m.ticks % spinner.len], label })
    else if (m.refreshing)
        try std.fmt.allocPrint(arena, "{s} refreshing ", .{spinner[m.ticks % spinner.len]})
    else if (m.fetched_at) |at|
        try updatedAgo(arena, now - at)
    else
        "";
    const width: u16 = @intCast(text.displayWidth(right));
    if (width < win.width) _ = print(win, 0, win.width - width, right, style_dim);
}

fn updatedAgo(arena: Allocator, age: i64) Allocator.Error![]const u8 {
    if (age < 60) return "updated just now ";
    var buf: [16]u8 = undefined;
    return std.fmt.allocPrint(arena, "updated {s} ago ", .{time.formatRemaining(age, &buf)});
}

fn drawFilter(win: Window, m: *const Model) void {
    var col = print(win, 1, 0, " › ", .{ .fg = accent, .bold = true });
    if (m.filter.isEmpty()) {
        if (m.mode == .browse) win.showCursor(col, 1);
        _ = print(win, 1, col, "type to filter", style_dim);
        return;
    }
    col = print(win, 1, col, m.filter.text(), .{});
    if (m.mode == .browse) win.showCursor(col, 1);
}

const Columns = struct { role: u16, scope: u16, subscription: u16 };

const prefix_width = 6; // cursor bar, selection mark, state glyph
const expires_width = 8;

fn columnWidths(arena: Allocator, m: *const Model, total: u16) Allocator.Error!Columns {
    var role: usize = 4;
    var scope: usize = 5;
    var subscription: usize = 12;
    for (m.visible.items) |i| {
        const r = m.rows[i];
        role = @max(role, text.displayWidth(try text.sanitize(arena, r.eligibility.role_name)));
        scope = @max(scope, text.displayWidth(try text.sanitize(arena, r.eligibility.scope_name)));
        subscription = @max(subscription, text.displayWidth(try text.sanitize(arena, r.subscription_name)));
    }
    role = @min(role, 24);
    subscription = @min(subscription, 28);
    const fixed = prefix_width + expires_width + 6;
    const available = @as(usize, total) -| fixed;
    while (role + scope + subscription > available and subscription > 8) subscription -= 1;
    while (role + scope + subscription > available and role > 8) role -= 1;
    scope = @min(scope, available -| (role + subscription));
    return .{ .role = @intCast(role), .scope = @intCast(scope), .subscription = @intCast(subscription) };
}

fn drawList(arena: Allocator, win: Window, m: *const Model, now: i64) Allocator.Error!void {
    const cols = try columnWidths(arena, m, win.width);
    const x_role: u16 = prefix_width;
    const x_scope = x_role + cols.role + 2;
    const x_sub = x_scope + cols.scope + 2;
    const x_exp = x_sub + cols.subscription + 2;

    _ = print(win, 0, x_role, "ROLE", style_dim);
    _ = print(win, 0, x_scope, "SCOPE", style_dim);
    _ = print(win, 0, x_sub, "SUBSCRIPTION", style_dim);
    _ = print(win, 0, x_exp, "EXPIRES", style_dim);

    if (m.visible.items.len == 0) {
        const msg = if (m.rows.len == 0)
            (if (m.refreshing) "Loading roles from Azure…" else "No eligible PIM roles.")
        else
            "No roles match the filter.";
        _ = print(win, 2, x_role, msg, style_dim);
        return;
    }

    const end = @min(m.visible.items.len, m.scroll + m.page_size);
    for (m.visible.items[m.scroll..end], m.scroll..) |row_index, i| {
        const r = m.rows[row_index];
        const y: u16 = @intCast(1 + i - m.scroll);
        const is_cursor = i == m.cursor;
        const line = win.child(.{ .y_off = y, .height = 1 });
        const base: Style = if (is_cursor) .{ .bold = true, .bg = .{ .index = 8 } } else .{};
        if (is_cursor) {
            line.fill(.{ .style = base });
            _ = print(line, 0, 0, "▌", .{ .fg = accent, .bg = base.bg });
        }
        if (m.isSelected(r)) _ = print(line, 0, 2, "✓", merge(base, style_selected));
        _ = print(line, 0, 4, stateGlyph(r.state), merge(base, stateStyle(r.state)));

        try cell(arena, line, x_role, cols.role, r.eligibility.role_name, base);
        try cell(arena, line, x_scope, cols.scope, r.eligibility.scope_name, base);
        try cell(arena, line, x_sub, cols.subscription, r.subscription_name, merge(base, style_dim));
        if (r.state == .active) if (r.active_until) |until| {
            const buf = try arena.create([16]u8);
            _ = print(line, 0, x_exp, time.formatRemaining(until - now, buf), merge(base, .{ .fg = .{ .index = 2 } }));
        };
    }
}

fn drawFooter(arena: Allocator, win: Window, m: *const Model) Allocator.Error!void {
    var y: u16 = 0;
    const shown = m.results[m.results.len -| max_result_lines..];
    for (shown) |line| {
        const col = print(win, y, 1, line.glyph, kindStyle(line.kind));
        _ = print(win, y, col + 1, try text.truncate(arena, line.text, win.width -| (col + 2)), .{});
        y += 1;
    }
    // Pointer capture: vaxis keeps the slice until render, so it must point into the model.
    if (m.notice) |*n| {
        _ = print(win, y, 1, try text.truncate(arena, n.text(), win.width -| 2), kindStyle(n.kind));
        y += 1;
    }
    const help = switch (m.mode) {
        .browse => "↑↓ move · tab select · enter activate · ^d deactivate · ^r refresh · esc quit",
        .form => "enter submit · tab switch field · esc cancel",
        .confirm_deactivate => "y/enter confirm · n/esc cancel",
    };
    _ = print(win, y, 1, try text.truncate(arena, help, win.width -| 2), style_dim);
}

fn drawForm(arena: Allocator, win: Window, m: *Model) Allocator.Error!void {
    const listed = @min(m.targets.len, 5);
    const extra: u16 = @intFromBool(m.targets.len > listed);
    const height: u16 = @intCast(listed + extra + 7);
    const title = try std.fmt.allocPrint(arena, " Activate {d} role{s} ", .{ m.targets.len, if (m.targets.len == 1) "" else "s" });
    const box = overlay(win, title, 76, height) orelse return;

    var y: u16 = 0;
    for (m.targets[0..listed], 0..) |t, i| {
        const hint = if (m.plansLoaded()) try policyHint(arena, m.plans[i]) else "checking policy…";
        const hint_width: u16 = @intCast(text.displayWidth(hint));
        const name_width = box.width -| (hint_width + 4);
        _ = print(box, y, 1, "○", stateStyle(.eligible));
        _ = print(box, y, 3, try text.truncate(arena, try messages.label(arena, t), name_width), .{});
        _ = print(box, y, box.width -| (hint_width + 1), hint, style_dim);
        y += 1;
    }
    if (extra > 0) {
        _ = print(box, y, 3, try std.fmt.allocPrint(arena, "+{d} more", .{m.targets.len - listed}), style_dim);
        y += 1;
    }
    y += 1;

    const label_width = 16;
    const duration_row = y;
    _ = print(box, y, 1, "Duration", if (m.field == .duration) style_bold else style_dim);
    var col = print(box, y, label_width, m.duration_text.text(), .{});
    if (try durationNote(arena, m)) |note| _ = print(box, y, col + 2, note, .{ .fg = .{ .index = 3 } });
    y += 1;
    const justification_row = y;
    const required = m.justificationRequired();
    _ = print(box, y, 1, if (required) "Justification*" else "Justification", if (m.field == .justification) style_bold else style_dim);
    const shown = try text.truncate(arena, m.justification.text(), box.width -| (label_width + 2));
    col = print(box, y, label_width, shown, .{});

    if (m.field == .justification) {
        box.showCursor(col, justification_row);
    } else {
        box.showCursor(label_width + @as(u16, @intCast(text.displayWidth(m.duration_text.text()))), duration_row);
    }
}

fn drawConfirm(arena: Allocator, win: Window, m: *const Model) Allocator.Error!void {
    const listed = @min(m.targets.len, 6);
    const title = try std.fmt.allocPrint(arena, " Deactivate {d} role{s}? ", .{ m.targets.len, if (m.targets.len == 1) "" else "s" });
    const box = overlay(win, title, 70, @intCast(listed + 3)) orelse return;
    for (m.targets[0..listed], 0..) |t, i| {
        _ = print(box, @intCast(i), 1, "●", stateStyle(.active));
        _ = print(box, @intCast(i), 3, try text.truncate(arena, try messages.label(arena, t), box.width -| 4), .{});
    }
    if (m.targets.len > listed) _ = print(box, @intCast(listed), 3, try std.fmt.allocPrint(arena, "+{d} more", .{m.targets.len - listed}), style_dim);
}

/// A bordered, centred box; returns its inner window.
fn overlay(win: Window, title: []const u8, max_width: u16, inner_height: u16) ?Window {
    const width = @min(max_width, win.width -| 2);
    const height = @min(inner_height + 2, win.height -| 2);
    if (width < 20 or height < 3) return null;
    const outer = win.child(.{
        .x_off = @intCast((win.width - width) / 2),
        .y_off = @intCast((win.height - height) / 2),
        .width = width,
        .height = height,
    });
    outer.clear();
    const inner = outer.child(.{ .border = .{ .where = .all, .style = .{ .fg = accent } } });
    _ = print(outer, 0, 2, title, .{ .fg = accent, .bold = true });
    return inner;
}

fn policyHint(arena: Allocator, plan: activation.Plan) Allocator.Error![]const u8 {
    const p = plan.policy orelse return "policy unknown";
    var parts: std.ArrayList([]const u8) = .empty;
    if (p.max_duration_min) |max| {
        const buf = try arena.create([16]u8);
        try parts.append(arena, try std.fmt.allocPrint(arena, "max {s}", .{duration.formatHuman(max, buf)}));
    }
    if (p.approval_required) try parts.append(arena, "approval");
    if (p.mfa_required) try parts.append(arena, "MFA");
    if (p.ticket_required) try parts.append(arena, "ticket (unsupported)");
    return std.mem.join(arena, " · ", parts.items);
}

/// Warns when the typed duration is invalid or longer than a policy allows.
fn durationNote(arena: Allocator, m: *const Model) Allocator.Error!?[]const u8 {
    const minutes = duration.parse(m.duration_text.text()) catch return "e.g. 8h, 90m, 1h30m";
    if (!m.plansLoaded()) return null;
    var cap: ?u32 = null;
    for (m.plans) |p| if (p.policy) |pol| if (pol.max_duration_min) |max| {
        cap = if (cap) |c| @min(c, max) else max;
    };
    const limit = cap orelse return null;
    if (minutes <= limit) return null;
    const buf = try arena.create([16]u8);
    return try std.fmt.allocPrint(arena, "capped to {s} by policy", .{duration.formatHuman(limit, buf)});
}

fn cell(arena: Allocator, win: Window, x: u16, width: u16, value: []const u8, style: Style) Allocator.Error!void {
    if (width == 0) return;
    const safe = try text.truncate(arena, try text.sanitize(arena, value), width);
    _ = print(win, 0, x, safe, style);
}

/// Prints one unwrapped segment and returns the column after it.
fn print(win: Window, row: u16, col: u16, s: []const u8, style: Style) u16 {
    const result = win.printSegment(.{ .text = s, .style = style }, .{ .row_offset = row, .col_offset = col, .wrap = .none });
    return result.col;
}

fn merge(base: Style, over: Style) Style {
    var s = over;
    if (std.meta.eql(over.bg, vaxis.Color.default)) s.bg = base.bg;
    s.bold = over.bold or base.bold;
    return s;
}

fn stateGlyph(state: rows_mod.State) []const u8 {
    return switch (state) {
        .active => "●",
        .pending => "◐",
        .eligible => "○",
    };
}

fn stateStyle(state: rows_mod.State) Style {
    return switch (state) {
        .active => .{ .fg = .{ .index = 2 } },
        .pending => .{ .fg = .{ .index = 3 } },
        .eligible => style_dim,
    };
}

fn kindStyle(kind: messages.Kind) Style {
    return switch (kind) {
        .ok => .{ .fg = .{ .index = 2 } },
        .pending => .{ .fg = .{ .index = 3 } },
        .failed => .{ .fg = .{ .index = 1 } },
        .info => style_dim,
    };
}
