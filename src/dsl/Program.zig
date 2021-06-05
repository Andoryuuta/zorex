//! The public interface for compiling and running Zorex programs.

const compiler = @import("compiler.zig");
const CompilerResult = @import("compiler.zig").CompilerResult;
const Compilation = @import("Compilation.zig");
const Node = @import("Node.zig");
const CompilerContext = @import("CompilerContext.zig");

const combn = @import("../combn/combn.zig");
const Context = combn.Context;
const Result = combn.Result;

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const assert = std.debug.assert;

const Program = @This();

/// If compile() fails, this error message and offset explains why and where.
error_message: ?[]const u8,
error_offset: usize,

/// The source of the program, null after successful compilation.
src: ?[]const u8,

/// The compiled program.
program: ?CompilerResult,

/// Context for the program.
context: ?Context(void, Node),

allocator: *mem.Allocator,

pub const Error = error{
    OutOfMemory,
    CompilationFailed,
};

/// Initializes a new program with the given source, which is borrowed until compile() is called
/// and returns.
pub fn init(allocator: *mem.Allocator, src: []const u8) Program {
    return Program{
        .error_message = null,
        .error_offset = 0,
        .src = src,
        .program = null,
        .context = null,
        .allocator = allocator,
    };
}

/// Compiles the program, returning an error if compilation fails.
pub fn compile(self: *Program) !void {
    // Compile the syntax.
    var compilerResult = try compiler.compile(self.allocator, self.src.?);
    switch (compilerResult.compilation.result) {
        .err => |e| {
            self.error_message = e;
            self.error_offset = compilerResult.compilation.offset;
            compilerResult.deinit(self.allocator);
            return Error.CompilationFailed;
        },
        .value => {},
    }
    self.program = compilerResult;
    self.src = null;
}

/// Executes the program with the given input.
pub fn execute(self: *Program, input: []const u8) !Node {
    nosuspend {
        self.context = try Context(void, Node).init(self.allocator, input, {});

        const compilation = self.program.?.compilation.result.value;
        try compilation.value.parser.ptr.parse(&self.context.?);

        var sub = self.context.?.subscribe();
        var first = sub.next().?;
        assert(sub.next() == null); // no ambiguous parse paths here
        return first.result.value;
    }
}

pub fn deinit(self: *const Program) void {
    if (self.program) |prog| {
        self.context.?.deinit();
        prog.deinit(self.allocator);
    }
}

test "example_regex" {
    const allocator = testing.allocator;

    const String = @import("String.zig");

    // Compile the regexp.
    var program = Program.init(allocator, "//");
    defer program.deinit();
    program.compile() catch |err| switch (err) {
        Error.CompilationFailed => @panic(program.error_message.?),
        else => unreachable,
    };

    // Execute the regexp.
    const input = "hmmm";
    const result = try program.execute(input);

    try testing.expectEqualStrings("TODO(slimsag): value from parsing regexp!", result.name.value.items);
    try testing.expect(result.value == null);
    try testing.expect(result.children == null);

    // TODO(slimsag): Node type is not JSON-serializable for some reason.
    //const stdout = std.io.getStdOut().writer();
    //try std.json.stringify(result, std.json.StringifyOptions{}, stdout);
}

test "example_zorex" {
    const allocator = testing.allocator;

    const String = @import("String.zig");

    // Compile the zorex.
    var program = Program.init(allocator, "Date = //; Date");
    defer program.deinit();
    program.compile() catch |err| switch (err) {
        Error.CompilationFailed => @panic(program.error_message.?),
        else => unreachable,
    };

    // Execute the zorex.
    const input = "hmmm";
    const result = try program.execute(input);

    // TODO(slimsag): node name should not be unknown
    try testing.expectEqualStrings("unknown", result.name.value.items);
    try testing.expect(result.value == null);
    try testing.expect(result.children != null);
    try testing.expectEqual(@as(usize, 1), result.children.?.len);
    var child = (result.children.?)[0];
    try testing.expectEqualStrings("TODO(slimsag): value from parsing regexp!", child.name.value.items);
    try testing.expect(child.value == null);
    try testing.expect(child.children == null);

    // TODO(slimsag): Node type is not JSON-serializable for some reason.
    // const stdout = std.io.getStdOut().writer();
    // try std.json.stringify(result, std.json.StringifyOptions{}, stdout);
}
