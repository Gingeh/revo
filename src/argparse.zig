//!
//! general arg parsing library (lung, 2026)
//!
//! can parse crazy stuff like
//!     `revo -Wow script.rv --this-is-passthru`
//! and `revo -Wow decompile script.rv`
//!
//! see the tests below for a tutorial
//!
//! we can't just take an existing library off github because their apis are
//!     always zig-specific and compile-time or something. not good for revo
//!
//! we're gonna use it for both the cli and a builtin module
//!
//! flags (long/short) come first, in any order, until the first
//! 'terminal positional is filled (so the script path for revo cli)
//!
//! after that, every remaining token is passthrough,
//! never parsed as a flag again
//! a single optional leading "command" word (compile/repl/bench5/etc)
//! can be matched before flags are even considered
//!
//! todo
//! [x] long --args
//! [x] short -aRgS
//! [x] leftover / passthrough argv
//! [x] leading command word (flat, not nested subcommand trees)
//! [x] stop-parsing-flags-after-first-positional (needed for `revo script.rv -i`
//!     to hand `-i` to the script instead of eating it as revo's own flag)
//!

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Arg = struct {
    name: []const u8 = "",
    short: ?u8 = null,
    kind: Kind = .boolean,
    description: []const u8 = "",
    enabled: bool = false, // will get mutated, for .boolean
    value: ?[]const u8 = null, // will get mutated, for .string / .positional

    // only meaningful for .positional:
    terminal: bool = false, // once filled, stop interpreting flags for the rest of argv
    passthrough: bool = false, // also copy the raw token into `leftover` when filled

    pub const Kind = enum {
        boolean,
        string,
        positional,
    };

    /// renders flag syntax into buf, e.g. "-e" or "--test"
    /// returns the used portion of buf
    pub fn flagString(self: Arg, buf: *[16]u8) []const u8 {
        var len: usize = 0;
        if (self.short) |s| {
            buf[len] = '-';
            len += 1;
            buf[len] = s;
            len += 1;
        } else {
            buf[len] = '-';
            len += 1;
            buf[len] = '-';
            len += 1;
            for (self.name) |c| {
                if (len >= buf.len) break;
                buf[len] = c;
                len += 1;
            }
        }
        return buf[0..len];
    }
};

/// single leading word (args[1] of real argv) matched before any
/// flag parsing happens
///
/// matching one js sets `triggered` (and `value` for prefix matches) and parsing
/// continues against the same flat `Result.args` list. an unmatched word is left
/// alone and falls through to normal token handling (so becomes the
/// first positional / script path)
pub const Command = struct {
    name: []const u8,
    prefix: bool = false, // match via startsWith(name) instead of exact eql
    description: []const u8 = "",
    // only consulted when prefix = true, called with the text after `name`
    // (e.g. "5" from "bench5", "" from bare "bench"). null means always accept
    validate: ?*const fn (remainder: []const u8) bool = null,
    triggered: bool = false, // will get modified dynamically
    value: []const u8 = "", // for prefix matches: the text after `name`
};

pub const Result = struct {
    args: []Arg,
    commands: []Command = &.{},
    // owned by caller; tokens here are exactly the original argv slices,
    // still null-terminated, u can hand them straight to a child process/VM
    leftover: *std.ArrayList([:0]const u8),
    // set right before any ParseError is returned, so callers can build
    // their own message ("unknown option '{s}'", "-e requires an argument")
    // without the library needing to know their wording
    err_token: ?[:0]const u8 = null,

    fn findLong(self: *Result, name: []const u8) ?*Arg {
        for (self.args) |*a| {
            if (a.kind != .positional and std.mem.eql(u8, a.name, name)) return a;
        }
        return null;
    }

    fn findShort(self: *Result, c: u8) ?*Arg {
        for (self.args) |*a| {
            if (a.kind != .positional and a.short != null and a.short.? == c) return a;
        }
        return null;
    }

    // first not-yet-filled positional slot, in declaration order
    fn nextPositional(self: *Result) ?*Arg {
        for (self.args) |*a| {
            if (a.kind == .positional and a.value == null) return a;
        }
        return null;
    }
};

pub const ParseError = error{
    UnexpectedLongArg,
    UnexpectedShortArg,
    MissingValue,
};

fn looksLikeFlag(s: []const u8) bool {
    // a bare "-" is conventionally a stdin/passthrough marker, not a flag
    return s.len > 1 and s[0] == '-';
}

/// mutates your populated result
/// `args` should NOT include argv[0] pretty please
pub fn parse(allocator: Allocator, args: []const [:0]const u8, res: *Result) !void {
    var i: usize = 0;
    var no_more_flags = false; // "--" seen, or a terminal positional filled

    while (i < args.len) : (i += 1) {
        const tok = args[i];
        const str: []const u8 = tok;

        if (str.len == 0) {
            try res.leftover.append(allocator, tok);
            continue;
        }

        // leading command word:
        //   only ever attempted for the very first token
        if (i == 0 and !looksLikeFlag(str)) {
            var matched = false;
            for (res.commands) |*cmd| {
                if (cmd.prefix) {
                    if (std.mem.startsWith(u8, str, cmd.name)) {
                        const rest = str[cmd.name.len..];
                        if (cmd.validate == null or cmd.validate.?(rest)) {
                            cmd.triggered = true;
                            cmd.value = rest;
                            matched = true;
                            break;
                        }
                    }
                } else if (std.mem.eql(u8, str, cmd.name)) {
                    cmd.triggered = true;
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }

        // plain token:
        //   positional or passthrough (also every token once
        //   no_more_flags is set, flag-looking or not)
        if (no_more_flags or !looksLikeFlag(str)) {
            if (!looksLikeFlag(str)) {
                if (res.nextPositional()) |arg| {
                    arg.value = str;
                    if (arg.terminal) no_more_flags = true;
                    if (arg.passthrough) try res.leftover.append(allocator, tok);
                    continue;
                }
            }
            try res.leftover.append(allocator, tok);
            continue;
        }

        // bare "--": everything after is raw, never a flag again
        if (str.len == 2 and str[1] == '-') {
            no_more_flags = true;
            continue;
        }

        // branch --arg | --arg=value
        if (str[1] == '-') {
            const body = str[2..];
            const eq = std.mem.indexOfScalar(u8, body, '=');
            const name = if (eq) |e| body[0..e] else body;

            const arg = res.findLong(name) orelse {
                res.err_token = tok;
                return ParseError.UnexpectedLongArg;
            };
            switch (arg.kind) {
                .boolean => arg.enabled = true,
                .string, .positional => {
                    if (eq) |e| {
                        arg.value = body[e + 1 ..];
                    } else {
                        i += 1;
                        if (i >= args.len) {
                            res.err_token = tok;
                            return ParseError.MissingValue;
                        }
                        arg.value = args[i];
                    }
                },
            }
            continue;
        }

        // branch -aRgS lump (last one may take a value)
        var j: usize = 1;
        while (j < str.len) : (j += 1) {
            const c = str[j];
            const arg = res.findShort(c) orelse {
                res.err_token = tok;
                return ParseError.UnexpectedShortArg;
            };
            switch (arg.kind) {
                .boolean => arg.enabled = true,
                .string, .positional => {
                    if (j + 1 < str.len) {
                        // -ovalue : rest of the lump the value
                        arg.value = str[j + 1 ..];
                    } else {
                        // -o value : next argv token is the value
                        i += 1;
                        if (i >= args.len) {
                            res.err_token = tok;
                            return ParseError.MissingValue;
                        }
                        arg.value = args[i];
                    }
                    break; // a flag being one taht takes a value ends the lump
                },
            }
        }
    }
}

pub fn usage(allocator: Allocator, args: []const Arg, commands: []const Command) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer buf.deinit(allocator);

    // for alignment
    var max_flag: usize = 0;
    var flag_buf: [16]u8 = undefined;
    for (args) |arg| {
        const fs = arg.flagString(&flag_buf);
        if (fs.len > max_flag) max_flag = fs.len;
    }

    //
    // commands
    if (commands.len > 0) {
        try buf.append(allocator, '\n');
        try buf.appendSlice(allocator, "Commands:\n");
        for (commands) |cmd| {
            try buf.appendSlice(allocator, "  ");
            try buf.appendSlice(allocator, cmd.name);
            for (0..max_flag + 2 - cmd.name.len) |_| try buf.append(allocator, ' ');
            try buf.appendSlice(allocator, cmd.description);
            try buf.append(allocator, '\n');
        }
    }

    //
    // options section (and skip positionals)
    try buf.appendSlice(allocator, "\noptions:\n");
    for (args) |arg| {
        if (arg.kind == .positional) continue;
        const fs = arg.flagString(&flag_buf);
        try buf.appendSlice(allocator, "  ");
        try buf.appendSlice(allocator, fs);
        for (0..max_flag + 2 - fs.len) |_| try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, arg.description);
        try buf.append(allocator, '\n');
    }

    return try buf.toOwnedSlice(allocator);
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return true; // bare bench is valid with default iters
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "flags before a terminal positional, passthru after it" {
    const allocator = std.testing.allocator;
    var leftover: std.ArrayList([:0]const u8) = .empty;
    defer leftover.deinit(allocator);

    var my_args = [_]Arg{
        .{ .name = "e", .short = 'e', .kind = .string },
        .{ .name = "i", .short = 'i', .kind = .boolean },
        .{ .name = "script", .kind = .positional, .terminal = true, .passthrough = true },
        .{ .name = "output", .kind = .positional }, // passthrough = false
    };
    var res = Result{ .args = &my_args, .leftover = &leftover };

    // -i is ours (before the script path); -x after it belongs to the script
    const argv: []const [:0]const u8 = &.{ "-i", "script.rv", "-x", "extra" };
    try parse(allocator, argv, &res);

    try std.testing.expect(my_args[1].enabled); // -i
    try std.testing.expectEqualStrings("script.rv", my_args[2].value.?);
    try std.testing.expectEqual(@as(usize, 3), leftover.items.len);
    try std.testing.expectEqualStrings("script.rv", leftover.items[0]);
    try std.testing.expectEqualStrings("-x", leftover.items[1]); // NOT parsed as a flag
    try std.testing.expectEqualStrings("extra", leftover.items[2]);
}

test "compile mode: output path is captured but excluded from passthrough" {
    const allocator = std.testing.allocator;
    var leftover: std.ArrayList([:0]const u8) = .empty;
    defer leftover.deinit(allocator);

    var commands = [_]Command{.{ .name = "compile" }};
    var my_args = [_]Arg{
        .{ .name = "script", .kind = .positional, .terminal = true, .passthrough = true },
        .{ .name = "output", .kind = .positional },
    };
    var res = Result{ .args = &my_args, .commands = &commands, .leftover = &leftover };

    const argv: []const [:0]const u8 = &.{ "compile", "script.rv", "out.rvo" };
    try parse(allocator, argv, &res);

    try std.testing.expect(commands[0].triggered);
    try std.testing.expectEqualStrings("script.rv", my_args[0].value.?);
    try std.testing.expectEqualStrings("out.rvo", my_args[1].value.?);
    try std.testing.expectEqual(@as(usize, 1), leftover.items.len); // just the script
}

test "unrecognized leading word falls through to script path" {
    const allocator = std.testing.allocator;
    var leftover: std.ArrayList([:0]const u8) = .empty;
    defer leftover.deinit(allocator);

    var commands = [_]Command{ .{ .name = "compile" }, .{ .name = "repl" } };
    var my_args = [_]Arg{
        .{ .name = "script", .kind = .positional, .terminal = true, .passthrough = true },
    };
    var res = Result{ .args = &my_args, .commands = &commands, .leftover = &leftover };

    const argv: []const [:0]const u8 = &.{"weird.rv"};
    try parse(allocator, argv, &res);

    try std.testing.expect(!commands[0].triggered);
    try std.testing.expect(!commands[1].triggered);
    try std.testing.expectEqualStrings("weird.rv", my_args[0].value.?);
}

test "prefix command with a validator (bench[n]), including a failed match" {
    const allocator = std.testing.allocator;
    var leftover: std.ArrayList([:0]const u8) = .empty;
    defer leftover.deinit(allocator);

    var commands = [_]Command{.{ .name = "bench", .prefix = true, .validate = allDigits }};
    var my_args = [_]Arg{
        .{ .name = "i", .short = 'i', .kind = .boolean },
        .{ .name = "script", .kind = .positional, .terminal = true, .passthrough = true },
    };
    {
        var res = Result{ .args = &my_args, .commands = &commands, .leftover = &leftover };
        const argv: []const [:0]const u8 = &.{ "bench5", "-i" };
        try parse(allocator, argv, &res);
        try std.testing.expect(commands[0].triggered);
        try std.testing.expectEqualStrings("5", commands[0].value);
        try std.testing.expect(my_args[0].enabled); // -i still parsed normally afterward
    }

    // reset and try a suffix that fails validation; "bench" shouldn't match,
    // so the whole token falls through and becomes the script path instead
    commands[0].triggered = false;
    my_args[0].enabled = false;
    my_args[1].value = null;
    leftover.clearRetainingCapacity();
    {
        var res = Result{ .args = &my_args, .commands = &commands, .leftover = &leftover };
        const argv: []const [:0]const u8 = &.{"benchfoo.rv"};
        try parse(allocator, argv, &res);
        try std.testing.expect(!commands[0].triggered);
        try std.testing.expectEqualStrings("benchfoo.rv", my_args[1].value.?);
    }
}

test "unknown long flag reports the wacky token" {
    const allocator = std.testing.allocator;
    var leftover: std.ArrayList([:0]const u8) = .empty;
    defer leftover.deinit(allocator);

    var my_args = [_]Arg{.{ .name = "test", .kind = .boolean }};
    var res = Result{ .args = &my_args, .leftover = &leftover };

    const argv: []const [:0]const u8 = &.{"--bogus"};
    try std.testing.expectError(ParseError.UnexpectedLongArg, parse(allocator, argv, &res));
    try std.testing.expectEqualStrings("--bogus", res.err_token.?);
}
