//! diagnostics borrow their text and source slices from arena-backed storage
//! do not manually free anything

const std = @import("std");

const ast = @import("./ast.zig");
const pretty = @import("../pretty.zig");

/// severity bucket for a diagnostic report
/// TODO: only err and warning can be toggled
pub const Severity = enum { err, warning, note, help };

/// role for a span inside a report
/// TODO: only context can be toggled off
pub const SpanRole = enum { primary, secondary, context, trace };

// TODO: decide on colors for box and each bucket
const COLOR_DIM = "\x1b[2m";
const COLOR_RESET = "\x1b[0m";

/// one span entry attached to a report
pub const SpanPart = struct {
    span: ast.Span,
    role: SpanRole = .primary,
    message: []const u8 = "",
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
};

/// label tied to a span
pub const Label = struct {
    span: ast.Span,
    message: []const u8 = "",
};

/// plain note line
pub const Note = struct {
    message: []const u8,
};

/// stack trace frame with optional source context
pub const TraceFrame = struct {
    function_name: []const u8,
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    span: ?ast.Span = null,
    pc: ?usize = null,

    /// empty frame shell
    pub fn empty() TraceFrame {
        return .{ .function_name = "" };
    }
};

/// one rendered part of a report
pub const Part = union(enum) {
    span: SpanPart,
    @"error": []const u8,
    tip: []const u8,
    warn: []const u8,
    note: []const u8,
    trace: TraceFrame,
};

/// arena-backed payload
pub const Report = struct {
    parts: []const Part = &.{},
    message: []const u8 = "",
    source_name: ?[]const u8 = null,
    source: ?[]const u8 = null,

    pub fn deinit(self: *Report, alloc: std.mem.Allocator) void {
        if (self.message.len != 0) alloc.free(self.message);
        if (self.source_name) |sn| alloc.free(sn);
        if (self.source) |src| alloc.free(src);
        for (self.parts) |part| switch (part) {
            .@"error" => |err| alloc.free(err),
            .tip => |tip| alloc.free(tip),
            .warn => |warn| alloc.free(warn),
            .note => |note| alloc.free(note),
            .span => |span| {
                if (span.message.len != 0) alloc.free(span.message);
                if (span.source_name) |sn| alloc.free(sn);
                if (span.source) |src| alloc.free(src);
            },
            .trace => |trace| {
                alloc.free(trace.function_name);
                if (trace.source_name) |sn| alloc.free(sn);
                if (trace.source) |src| alloc.free(src);
            },
        };
        alloc.free(self.parts);
    }

    /// deep copy borrowed text into `alloc`
    pub fn copy(report: Report, alloc: std.mem.Allocator) !Report {
        const message = try alloc.dupe(u8, report.message);
        errdefer alloc.free(message);
        const parts = try alloc.dupe(Part, report.parts);
        errdefer alloc.free(parts);

        for (parts) |*part| switch (part.*) {
            .@"error" => |err| part.* = .{ .@"error" = try alloc.dupe(u8, err) },
            .tip => |tip| part.* = .{ .tip = try alloc.dupe(u8, tip) },
            .warn => |warn| part.* = .{ .warn = try alloc.dupe(u8, warn) },
            .note => |note| part.* = .{ .note = try alloc.dupe(u8, note) },
            .span => |span| {
                var c = span;
                if (c.message.len != 0) c.message = try alloc.dupe(u8, c.message);
                if (c.source_name) |sn| c.source_name = try alloc.dupe(u8, sn);
                if (c.source) |src| c.source = try alloc.dupe(u8, src);
                part.* = .{ .span = c };
            },
            .trace => |frame| {
                var c = frame;
                c.function_name = try alloc.dupe(u8, c.function_name);
                if (c.source_name) |sn| c.source_name = try alloc.dupe(u8, sn);
                if (c.source) |src| c.source = try alloc.dupe(u8, src);
                part.* = .{ .trace = c };
            },
        };

        return .{
            .parts = parts,
            .message = message,
            .source_name = null,
            .source = null,
        };
    }
};

/// wrapper for reports emitted by a phase
pub fn Diagnostic(comptime Kind: type) type {
    return struct {
        kind: Kind,
        report: Report,
    };
}

/// primary span if the report has one
pub fn primarySpan(report: Report) ?SpanPart {
    var fallback: ?SpanPart = null;
    for (report.parts) |part| {
        if (part == .span) {
            if (part.span.role == .primary) return part.span;
            if (fallback == null) fallback = part.span;
        }
    }
    return fallback;
}

/// first error message if the report has one
pub fn firstError(report: Report) ?[]const u8 {
    for (report.parts) |part| {
        if (part == .@"error") return part.@"error";
    }
    return null;
}

/// render a full report to the writer
pub fn renderReport(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    report: Report,
) !void {
    const source_name = report.source_name orelse "<source>";
    const source = report.source orelse "";
    if (report.parts.len == 0 and report.message.len != 0) {
        try pretty.printError(writer, "{s}", .{report.message});
        return;
    }

    var error_seen = false;
    var trace_seen = false;
    var trace_idx: usize = 0;
    for (report.parts) |part| {
        switch (part) {
            .@"error" => |message| {
                if (error_seen) try writer.writeByte('\n');
                try pretty.printError(writer, "{s}", .{message});
                error_seen = true;
            },
            .span => |span| {
                const msg = if (span.message.len == 0) null else span.message;
                switch (span.role) {
                    .primary => try renderSpanBlock(alloc, writer, span.source_name orelse source_name, span.source orelse source, span.span, msg),
                    .secondary => try renderSecondarySpan(writer, span.source_name orelse source_name, span.span, msg),
                    else => {},
                }
            },
            .tip => |tip| try writer.print("  = tip: {s}\n", .{tip}),
            .warn => |warn| try writer.print("  = warning: {s}\n", .{warn}),
            .note => |note| try writer.print("  = note: {s}\n", .{note}),
            .trace => |frame| {
                if (!trace_seen) {
                    try writer.writeAll("\nstack trace:\n");
                    trace_seen = true;
                }
                try renderTrace(writer, frame, trace_idx);
                trace_idx += 1;
            },
        }
    }
}

/// render ad hoc report from span and labels
pub fn renderAt(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    span: ?ast.Span,
    message: []const u8,
    labels: []const Label,
    notes: []const Note,
) !void {
    const part_count = 1 + @as(usize, @intFromBool(span != null)) + labels.len + notes.len;
    var parts = try alloc.alloc(Part, part_count);
    defer alloc.free(parts);

    var i: usize = 0;
    parts[i] = .{ .@"error" = message };
    i += 1;
    if (span) |s| {
        parts[i] = .{ .span = .{ .span = s, .role = .primary, .source_name = source_name, .source = source } };
        i += 1;
    }
    for (labels) |label| {
        parts[i] = .{ .span = .{ .span = label.span, .role = .secondary, .message = label.message, .source_name = source_name, .source = source } };
        i += 1;
    }
    for (notes) |note| {
        parts[i] = .{ .note = note.message };
        i += 1;
    }

    try renderReport(alloc, writer, .{
        .message = message,
        .parts = parts,
        .source_name = source_name,
        .source = source,
    });
}

fn renderTrace(writer: *std.Io.Writer, frame: TraceFrame, idx: usize) !void {
    const frame_source = frame.source_name orelse "<source>";
    try writer.print("  {d}: {s}", .{ idx, frame.function_name });
    if (frame.span) |span| {
        try writer.print(" at {s}:{d}:{d}\n", .{ frame_source, span.line, span.column });
    } else if (frame.pc) |pc| {
        try writer.print(" at {s}:pc={d}\n", .{ frame_source, pc });
    } else {
        try writer.print(" at {s}\n", .{frame_source});
    }
}

const SpanLine = struct {
    num: u32,
    text: []const u8,
    span_start: usize,
    span_end: usize,
    span_col: u32,
};

const ExtractedSpan = struct {
    lines: []SpanLine,
    ctx_before: [2]SpanLine,
    ctx_before_len: usize,
    ctx_after: [2]SpanLine,
    ctx_after_len: usize,
    line_width: usize,
    buf: []SpanLine,

    pub fn deinit(self: ExtractedSpan, alloc: std.mem.Allocator) void {
        alloc.free(self.buf);
    }
};

fn extractSpan(
    alloc: std.mem.Allocator,
    source: []const u8,
    location: ast.Span,
    start_line: u32,
    start_column: u32,
) !?ExtractedSpan {
    const clamped_start = @min(location.start, source.len);
    const line1_before = std.mem.findScalarLast(u8, source[0..clamped_start], '\n') orelse 0;
    var line_byte: usize = if (line1_before == 0) 0 else line1_before + 1;
    var line_num: u32 = start_line;
    const line_cap = countSpanLines(source, location.start, location.end) + 1;
    const render_end = if (location.end <= line_byte) @min(line_byte + 1, source.len) else location.end;

    var buf = try alloc.alloc(SpanLine, line_cap);
    errdefer alloc.free(buf);
    var total: usize = 0;

    while (line_byte < render_end and line_byte < source.len) {
        const line_end_rel = std.mem.findScalar(u8, source[line_byte..], '\n') orelse (source.len - line_byte);
        const line_end = line_byte + line_end_rel;
        buf[total] = .{
            .num = line_num,
            .text = source[line_byte..line_end],
            .span_start = if (line_num == start_line) location.start else line_byte,
            .span_end = @min(render_end, line_end),
            .span_col = if (line_num == start_line) start_column else 1,
        };
        total += 1;
        line_byte = line_end + 1;
        line_num += 1;
    }

    if (total == 0) {
        alloc.free(buf);
        return null;
    }

    const lines = buf[0..total];
    var ctx_before: [2]SpanLine = undefined;
    var ctx_before_len: usize = 0;

    if (line1_before > 0) {
        var prev_end: usize = line1_before;
        var ctx_num: u32 = start_line;
        while (ctx_before_len < 2 and prev_end > 0) {
            const prev_nl = std.mem.findScalarLast(u8, source[0..prev_end], '\n') orelse 0;
            const ctx_start = if (prev_nl == 0) 0 else prev_nl + 1;
            const ctx_text = source[ctx_start..prev_end];
            if (ctx_num == 0) break;
            ctx_num -= 1;
            if (std.mem.trim(u8, ctx_text, " \t\r").len != 0) {
                ctx_before[ctx_before_len] = .{
                    .num = ctx_num,
                    .text = ctx_text,
                    .span_start = 0,
                    .span_end = 0,
                    .span_col = 0,
                };
                ctx_before_len += 1;
            }
            prev_end = prev_nl;
        }
    }

    var ctx_after: [2]SpanLine = undefined;
    var ctx_after_len: usize = 0;
    var ctx_pos: usize = line_byte;
    var ctx_num: u32 = line_num;

    while (ctx_after_len < 2) {
        if (ctx_pos >= source.len) break;
        const next_nl = std.mem.findScalar(u8, source[ctx_pos..], '\n') orelse (source.len - ctx_pos);
        const ctx_text = source[ctx_pos .. ctx_pos + next_nl];
        if (std.mem.trim(u8, ctx_text, " \t\r").len == 0) {
            ctx_pos = ctx_pos + next_nl + 1;
            ctx_num += 1;
            continue;
        }
        ctx_after[ctx_after_len] = .{
            .num = ctx_num,
            .text = ctx_text,
            .span_start = 0,
            .span_end = 0,
            .span_col = 0,
        };
        ctx_after_len += 1;
        ctx_pos = ctx_pos + next_nl + 1;
        ctx_num += 1;
    }

    const max_line_num = blk: {
        var max_line = start_line;
        for (ctx_before[0..ctx_before_len]) |cl| {
            if (cl.num > max_line)
                max_line = cl.num;
        }
        for (lines) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        for (ctx_after[0..ctx_after_len]) |cl| {
            if (cl.num > max_line) max_line = cl.num;
        }
        break :blk max_line;
    };

    return .{
        .lines = lines,
        .ctx_before = ctx_before,
        .ctx_before_len = ctx_before_len,
        .ctx_after = ctx_after,
        .ctx_after_len = ctx_after_len,
        .line_width = @max(countDigits(max_line_num), @as(usize, 2)),
        .buf = buf,
    };
}

fn renderContextBefore(writer: *std.Io.Writer, extracted: ExtractedSpan, comptime dim: bool) !void {
    var before_idx: usize = extracted.ctx_before_len;
    while (before_idx > 0) {
        before_idx -= 1;
        const cl = extracted.ctx_before[before_idx];
        if (dim and pretty.supports_color) try writer.writeAll(COLOR_DIM);
        try writeLineNumber(writer, cl.num, extracted.line_width);
        try writeExpanded(writer, cl.text, 0);
        try writer.writeByte('\n');
        if (dim and pretty.supports_color) try writer.writeAll(COLOR_RESET);
    }
    if (extracted.ctx_before_len > 0) {
        try writeBlankPipeLine(writer, extracted.line_width, 0);
    }
}

fn renderContextAfter(writer: *std.Io.Writer, extracted: ExtractedSpan, comptime dim: bool) !void {
    if (extracted.ctx_after_len > 0) {
        try writeBlankPipeLine(writer, extracted.line_width, 0);
    }
    for (extracted.ctx_after[0..extracted.ctx_after_len]) |cl| {
        if (dim and pretty.supports_color) try writer.writeAll(COLOR_DIM);
        try writeLineNumber(writer, cl.num, extracted.line_width);
        try writeExpanded(writer, cl.text, 0);
        try writer.writeByte('\n');
        if (dim and pretty.supports_color) try writer.writeAll(COLOR_RESET);
    }
}

// columns are byte-counted by the lexer, so tabs must be expanded or carets drift left
const tab_width = 2;

/// display columns `text` occupies, tabs snap to the next tab stop
fn displayWidth(text: []const u8, start_col: usize) usize {
    var col = start_col;
    for (text) |ch| {
        if (ch == '\t') col += tab_width - (col % tab_width) else col += 1;
    }
    return col - start_col;
}

/// write `text` with tabs expanded to spaces
fn writeExpanded(writer: *std.Io.Writer, text: []const u8, start_col: usize) !void {
    var col = start_col;
    for (text) |ch| {
        if (ch == '\t') {
            const w = tab_width - (col % tab_width);
            for (0..w) |_| try writer.writeByte(' ');
            col += w;
        } else {
            try writer.writeByte(ch);
            col += 1;
        }
    }
}

fn countDigits(value: u32) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits;
}

fn leadingWhitespaceLen(text: []const u8) usize {
    var idx: usize = 0;
    while (idx < text.len) : (idx += 1) {
        if (text[idx] != ' ' and text[idx] != '\t') break;
    }
    return idx;
}

fn writeLineNumber(writer: *std.Io.Writer, num: u32, width: usize) !void {
    const digits = countDigits(num);
    if (width > digits) {
        for (0..width - digits) |_| try writer.writeByte(' ');
    }
    try writer.print("{d}", .{num});
    try writePipePrefix(writer, 2);
}

fn writePipePrefix(writer: *std.Io.Writer, spaces_after_pipe: usize) !void {
    try writer.writeByte(' ');
    try writer.writeByte('|');
    for (0..spaces_after_pipe) |_| try writer.writeByte(' ');
}

fn writeBoxPrefix(writer: *std.Io.Writer, line_width: usize, indent: usize) !void {
    for (0..line_width) |_| try writer.writeByte(' ');
    try writePipePrefix(writer, indent);
}

fn writeBlankPipeLine(writer: *std.Io.Writer, line_width: usize, indent: usize) !void {
    try writeBoxPrefix(writer, line_width, indent);
    try writer.writeByte('\n');
}

fn writeIndentAndPipe(writer: *std.Io.Writer, line_width: usize) !void {
    for (0..line_width) |_| try writer.writeByte(' ');
    try writer.writeAll(" |  ");
}

fn countSpanLines(source: []const u8, start: usize, end: usize) usize {
    const lo = @min(start, source.len);
    const hi = @min(end, source.len);
    var lines: usize = 1;
    for (source[lo..hi]) |ch| {
        if (ch == '\n') lines += 1;
    }
    return lines;
}

fn renderSecondarySpan(
    writer: *std.Io.Writer,
    source_name: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
) !void {
    const line = if (location.line == 0) 1 else location.line;
    const column = if (location.column == 0) 1 else location.column;
    try writer.print("  = {s}\n", .{label_message orelse "secondary span"});
    try writer.print("    --> {s}:{d}:{d}\n", .{ source_name, line, column });
}

fn renderSpanBlock(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
) !void {
    const start_line = if (location.line == 0) 1 else location.line;
    const start_column = if (location.column == 0) 1 else location.column;

    if (countSpanLines(source, location.start, location.end) > 1) {
        return renderBoxSpanBlock(alloc, writer, source_name, source, location, label_message);
    }

    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, start_line, start_column });

    const extracted = try extractSpan(alloc, source, location, start_line, start_column) orelse return;
    defer extracted.deinit(alloc);

    try renderContextBefore(writer, extracted, false);

    const bookend_threshold = 10;
    const total = extracted.lines.len;
    const tail_cut = if (total > bookend_threshold) 5 else total;
    const tail_start = if (total > bookend_threshold and total >= 10) total - 5 else total;
    var bookend_printed = false;

    for (extracted.lines, 0..) |cl, i| {
        const is_first = i == 0;
        const is_last = i + 1 == total;

        if (total > bookend_threshold and i >= tail_cut and i < tail_start) {
            if (!bookend_printed) {
                try writer.print("   ... {d} lines ...\n", .{total - tail_cut - (total - tail_start)});
                bookend_printed = true;
            }
            continue;
        }

        try writeLineNumber(writer, cl.num, extracted.line_width);
        try writeExpanded(writer, cl.text, 0);
        try writer.writeByte('\n');

        if (is_first or is_last) {
            const col = cl.span_col;
            const before_len = @min(@as(usize, col -| 1), cl.text.len);
            const pad = displayWidth(cl.text[0..before_len], 0);
            const span_here = cl.span_end -| cl.span_start;
            const clamped = @min(span_here, cl.text.len -| before_len);
            const highlight = @max(displayWidth(cl.text[before_len..][0..clamped], before_len), 1);

            try writeIndentAndPipe(writer, extracted.line_width);
            for (0..pad) |_| try writer.writeByte(' ');

            if (is_first and is_last) {
                try writer.writeByte('^');
                if (highlight > 1) {
                    for (0..highlight - 2) |_| try writer.writeByte('~');
                    try writer.writeByte('^');
                }
                if (label_message) |msg| try writer.print(" {s}", .{msg});
            } else if (is_first) {
                try writer.writeByte('^');
                if (highlight > 1) for (0..highlight - 1) |_| try writer.writeByte('~');
            } else {
                if (highlight > 1) for (0..highlight - 1) |_| try writer.writeByte('~');
                try writer.writeByte('^');
                if (label_message) |msg| try writer.print(" {s}", .{msg});
            }
            try writer.writeByte('\n');
        }
    }

    try renderContextAfter(writer, extracted, false);
}

fn renderBoxSpanBlock(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    source_name: []const u8,
    source: []const u8,
    location: ast.Span,
    label_message: ?[]const u8,
) !void {
    const start_line = if (location.line == 0) 1 else location.line;
    const start_column = if (location.column == 0) 1 else location.column;

    try writer.print(" --> {s}:{d}:{d}\n", .{ source_name, start_line, start_column });
    if (pretty.supports_color) try writer.writeAll(COLOR_DIM);
    try writePipePrefix(writer, 0);
    try writer.writeByte('\n');
    if (pretty.supports_color) try writer.writeAll(COLOR_RESET);

    const extracted = try extractSpan(alloc, source, location, start_line, start_column) orelse return;
    defer extracted.deinit(alloc);

    try renderContextBefore(writer, extracted, true);

    const bookend_threshold = 10;
    const total = extracted.lines.len;
    const tail_cut = if (total > bookend_threshold) 5 else total;
    const tail_start = if (total > bookend_threshold and total >= 10) total - 5 else total;
    var bookend_printed = false;

    const common_indent = blk: {
        var min_indent: usize = std.math.maxInt(usize);
        for (extracted.lines) |cl| {
            if (std.mem.trim(u8, cl.text, " \t\r").len == 0) continue;
            const indent = leadingWhitespaceLen(cl.text);
            if (indent < min_indent) min_indent = indent;
        }
        break :blk if (min_indent == std.math.maxInt(usize)) 0 else min_indent;
    };
    const display_trim = common_indent;

    const first_line = extracted.lines[0];
    const last_line = extracted.lines[total - 1];
    const first_trim_w = displayWidth(first_line.text[0..@min(display_trim, first_line.text.len)], 0);
    const last_trim_w = displayWidth(last_line.text[0..@min(display_trim, last_line.text.len)], 0);

    const marker_offset = first_trim_w -| 4;
    const first_span_off = @min(@as(usize, first_line.span_col -| 1), first_line.text.len);
    const top_dashes = displayWidth(first_line.text[0..first_span_off], 0) -| first_trim_w;
    const total_w = displayWidth(first_line.text, 0) -| first_trim_w;
    const top_vs = @max(@as(usize, 1), total_w -| top_dashes);

    const last_span_len = @min(last_line.span_end -| last_line.span_start, last_line.text.len);
    const bottom_dashes = @max(@as(usize, 1), displayWidth(last_line.text[0..last_span_len], 0) -| last_trim_w);

    try writeBoxPrefix(writer, extracted.line_width, 2);
    for (0..marker_offset) |_| try writer.writeByte(' ');
    try writer.writeByte('+');
    for (0..top_dashes + 1) |_| try writer.writeByte('-');
    for (0..top_vs) |_| try writer.writeByte('v');
    try writer.writeByte('\n');

    for (extracted.lines, 0..) |cl, i| {
        if (total > bookend_threshold and i >= tail_cut and i < tail_start) {
            if (!bookend_printed) {
                if (pretty.supports_color) try writer.writeAll(COLOR_DIM);
                try writeBoxPrefix(writer, extracted.line_width, 2);
                for (0..marker_offset) |_| try writer.writeByte(' ');
                try writer.print("... {d} lines ...\n", .{total - tail_cut - (total - tail_start)});
                if (pretty.supports_color) try writer.writeAll(COLOR_RESET);
                bookend_printed = true;
            }
            continue;
        }
        try writeLineNumber(writer, cl.num, extracted.line_width);
        const row_trim_w = displayWidth(cl.text[0..@min(display_trim, cl.text.len)], 0);
        for (0..row_trim_w -| 4) |_| try writer.writeByte(' ');
        try writer.writeAll("| ");
        try writeExpanded(writer, cl.text[display_trim..], row_trim_w);
        try writer.writeByte('\n');
    }

    try writeBoxPrefix(writer, extracted.line_width, 2);
    for (0..marker_offset) |_| try writer.writeByte(' ');
    try writer.writeByte('+');
    for (0..bottom_dashes) |_| try writer.writeByte('-');
    try writer.writeByte('^');
    if (label_message) |msg| try writer.print(" {s}", .{msg});
    try writer.writeByte('\n');

    try renderContextAfter(writer, extracted, true);
}

test "single line span" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try renderAt(
        std.testing.allocator,
        &buf.writer,
        "example.rv",
        "let x = 1\nlet y = 2\n",
        .{ .start = 4, .end = 5, .line = 1, .column = 5 },
        "boom",
        &.{.{ .span = .{ .start = 14, .end = 15, .line = 2, .column = 5 }, .message = "here" }},
        &.{.{ .message = "try something else" }},
    );
    try std.testing.expect(buf.written().len != 0);
    const output = buf.written();
    try std.testing.expect(std.mem.find(u8, output, "-->") != null);
    try std.testing.expect(std.mem.find(u8, output, "let y = 2") != null);
}

test "multi-line span with bracket" {
    var buf = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer buf.deinit();
    try renderAt(
        std.testing.allocator,
        &buf.writer,
        "multi.rv",
        \\before
        \\const x: string = 1 +
        \\  2 +
        \\  3
        \\after
    ,
        .{ .start = 14, .end = 36, .line = 2, .column = 18 },
        "x wants string, got number",
        &.{},
        &.{},
    );
    const output = buf.written();
    try std.testing.expect(std.mem.find(u8, output, "-->") != null);
    try std.testing.expect(std.mem.find(u8, output, "before") != null);
    try std.testing.expect(std.mem.find(u8, output, "const x: string = 1 +") != null);
    try std.testing.expect(std.mem.find(u8, output, "|   2 +") != null);
    try std.testing.expect(std.mem.find(u8, output, "|   3") != null);
    try std.testing.expect(std.mem.find(u8, output, "+-^") != null);
    try std.testing.expect(std.mem.find(u8, output, "x wants string, got number") != null);
    try std.testing.expect(std.mem.find(u8, output, "after") != null);
}

test "report copy preserves multiple error parts" {
    const alloc = std.testing.allocator;
    const report: Report = .{
        .message = "first problem",
        .parts = &.{
            .{ .@"error" = "first problem" },
            .{ .@"error" = "second problem" },
            .{ .span = .{
                .span = .{ .start = 0, .end = 1, .line = 1, .column = 1 },
                .role = .primary,
            } },
        },
    };

    const copied = try report.copy(alloc);
    defer {
        alloc.free(copied.message);
        for (copied.parts) |part| switch (part) {
            .@"error" => |msg| alloc.free(msg),
            .span => |span| {
                if (span.message.len != 0) alloc.free(span.message);
                if (span.source_name) |sn| alloc.free(sn);
                if (span.source) |src| alloc.free(src);
            },
            .tip => |tip| alloc.free(tip),
            .warn => |warn| alloc.free(warn),
            .note => |note| alloc.free(note),
            .trace => |trace| {
                alloc.free(trace.function_name);
                if (trace.source_name) |sn| alloc.free(sn);
                if (trace.source) |src| alloc.free(src);
            },
        };
        alloc.free(copied.parts);
    }

    try std.testing.expectEqualStrings("first problem", copied.message);
    try std.testing.expectEqualStrings("first problem", copied.parts[0].@"error");
    try std.testing.expectEqualStrings("second problem", copied.parts[1].@"error");
}

test "render report prints multiple error blocks" {
    const alloc = std.testing.allocator;
    var buf = std.Io.Writer.Allocating.init(alloc);
    defer buf.deinit();

    const report: Report = .{
        .source_name = "<source>",
        .source = "hi\n",
        .parts = &.{
            .{ .@"error" = "first problem" },
            .{ .span = .{
                .span = .{ .start = 0, .end = 2, .line = 1, .column = 1 },
                .role = .primary,
            } },
            .{ .@"error" = "second problem" },
            .{ .span = .{
                .span = .{ .start = 0, .end = 2, .line = 1, .column = 1 },
                .role = .primary,
            } },
        },
    };

    try renderReport(alloc, &buf.writer, report);
    try std.testing.expect(std.mem.find(u8, buf.written(), "first problem") != null);
    try std.testing.expect(std.mem.find(u8, buf.written(), "second problem") != null);
}
