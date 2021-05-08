const ResultStream = @import("result_stream.zig").ResultStream;
const ParserPath = @import("parser_path.zig").ParserPath;

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

pub const Error = error{OutOfMemory};

pub const ResultTag = enum {
    value,
    err,
};

/// A parser result, one of:
///
/// 1. A `value` and new `offset` into the input `src`.
/// 2. An `err` and new `offset` ito the input `src` ((i.e. position of error).
///
/// A Result always knows how to `deinit` itself.
pub fn Result(comptime Value: type) type {
    return struct {
        offset: usize,
        result: union(ResultTag) {
            value: Value,
            err: []const u8,
        },

        pub fn init(offset: usize, value: Value) @This() {
            return .{
                .offset = offset,
                .result = .{ .value = value },
            };
        }

        pub fn deinit(self: @This()) void {
            switch (self.result) {
                .value => |value| {
                    switch (@typeInfo(@TypeOf(value))) {
                        .Optional => if (value) |v| v.deinit(),
                        else => value.deinit(),
                    }
                },
                else => {},
            }
        }

        pub fn initError(offset: usize, err: []const u8) @This() {
            return .{
                .offset = offset,
                .result = .{ .err = err },
            };
        }
    };
}

const MemoizeValue = struct {
    results: usize, // untyped pointer *ResultStream(Result(Value))
    deinit: fn (results: usize, allocator: *mem.Allocator) void,
};

fn MemoizedResult(comptime Value: type) type {
    return struct {
        results: *ResultStream(Result(Value)),
        was_cached: bool,
    };
}

/// A key describing a parser node at a specific position in an input string, as well as the number
/// of times it reentrantly called itself at that exact position.
const ParserPosDepthKey = struct {
    pos_key: ParserPosKey,
    reentrant_depth: usize,
};

/// Describes the exact string and offset into it that a parser node is parsing.
pub const ParserPosKey = struct {
    node_name: ParserNodeName,
    src_ptr: usize,
    offset: usize,
};

/// The name of a parser node. This includes hashes of:
///
/// * The parser's type name (e.g. "MapTo", "Sequence", etc.)
/// * The actual parser inputs (e.g. the list of parsers to match in a Sequence parser, or for a
///   MapTo parser the input parser to match and the actual function that does mapping.)
///
/// It is enough to distinctly represent a _single node in the parser graph._ Note that it is NOT
/// the same as:
///
/// * Identifying a singular parser instance (two parser instances with the same inputs will be
///   "deduplicated" and have the same parser node name.)
/// * Identifying a parser node at a particular position: the parser `offset` position and `src`
///   string to parse are NOT parse of a parser node name, for that see `ParserPosKey`.
///
pub const ParserNodeName = u64;

/// Records a single recursion retry for a parser.
const RecursionRetry = struct {
    /// The current reentrant depth of the parser. 
    depth: usize,

    /// The maximum reentrant depth before this retry attempt will be stopped.
    max_depth: usize,
};

const Memoizer = struct {
    /// Parser position & reentrant depth key -> memoized results
    memoized: std.AutoHashMap(ParserPosDepthKey, MemoizeValue),

    /// *Parser(T) -> computed parser node name.
    node_name_cache: std.AutoHashMap(usize, ParserNodeName),

    /// Maps position key -> the currently active recursion retry attempt, if any.
    recursion: std.AutoHashMap(ParserPosKey, RecursionRetry),

    /// Memoized values to cleanup later, because freeing them inside a reentrant parser
    /// invocation is not possible as the parent still intends to use it.
    ///
    /// TODO(slimsag): consider something like reference counting here to reduce memory
    /// footprint.
    deferred_cleanups: std.ArrayList(MemoizeValue),

    /// Tells if the given parser node is currently being retried at different maximum reentrant
    /// depths as part of a Reentrant combinator.
    pub fn isRetrying(self: *@This(), key: ParserPosKey) bool {
        const recursion = self.recursion.get(key);
        if (recursion == null) return false;
        return true;
    }

    fn clearPastRecursions(self: *@This(), parser: ParserPosKey, new_max_depth: usize) !void {
        var i: usize = 0;
        while (i <= new_max_depth) : (i += 1) {
            var removed_entry = self.memoized.remove(ParserPosDepthKey{
                .pos_key = parser,
                .reentrant_depth = i,
            });
            if (removed_entry) |e| try self.deferred_cleanups.append(e.value);
        }
    }

    pub fn get(self: *@This(), comptime Value: type, allocator: *mem.Allocator, parser_path: ParserPath, parser: ParserPosKey, new_max_depth: ?usize) !MemoizedResult(Value) {
        // We memoize results for each unique ParserPosDepthKey, meaning that a parser node can be
        // invoked to parse a specific input string at a specific offset recursively in a reentrant
        // way up to a maximum depth (new_max_depth). This enables our GLL parser to handle grammars
        // that are left-recursive, such as:
        //
        // ```ebnf
        // Expr = Expr?, "abc" ;
        // Grammar = Expr ;
        // ```
        //
        // Where an input string "abcabcabc" would require `Expr` be parsed at offset=0 in the
        // input string multiple times. How many times? We start out with a maximum reentry depth
        // of zero, and if we determine that the parsing is cyclic (a ResultStream subscriber is in
        // fact itself the source) we consider that parse path as failed (it matches only the empty
        // language) and retry with a new_max_depth of N+1 and retry the whole parse path,
        // repeating this process until eventually we find the parsing is not cyclic.
        //
        // It is important to note that this is for handling reentrant parsing _at the same exact
        // offset position in the input string_, the GLL parsing algorithm itself handles left
        // recursive and right recursive parsing fine on its own, as long as the parse position is
        // changing, but many implementations cannot handle reentrant parsing at the same exact
        // offset position in the input string (I am unsure if this is by design, or a limitation
        // of the implementations themselves). Packrattle[1] which uses an "optimized" GLL parsing
        // algorithm (memoization is localized to parse nodes) is the closest to our algorithm, and
        // can handle this type of same-position left recursion in some instances such as with:
        //
        // ```ebnf
        // Expr = Expr?, "abc" ;
        // Grammar = Expr, EOF ;
        // ```
        //
        // However, it does so using a _globalized_ retry mechanism[2] which in this event resets
        // the entire parser back to an earlier point in time, only if the overall parse failed.
        // This also coincidently means that if the `EOF` matcher is removed (`Grammar = Expr ;`)
        // then `Expr` matching becomes "non-greedy" matching just one "abc" value instead of all
        // three as when the EOF matcher is in place.
        //
        // Our implementation here uses node-localized retries, which makes us not subject to the
        // same bug as packrattle and more optimized (the entire parse need not fail for us to
        // detect and retry in this case, we do so exactly at the reentrant parser node itself.)
        //
        // [1] https://github.com/robey/packrattle
        // [2] https://github.com/robey/packrattle/blob/3db99f2d87abdddb9d29a0d0cf86e272c59d4ddb/src/packrattle/engine.js#L137-L177
        //
        var reentrant_depth: usize = 0;
        const recursionEntry = self.recursion.get(parser);
        if (recursionEntry) |entry| {
            if (new_max_depth != null) {
                // Existing entry, but we want to retry with a new_max_depth;
                reentrant_depth = new_max_depth.?;
                try self.recursion.put(parser, .{ .depth = new_max_depth.?, .max_depth = new_max_depth.? });
                try self.clearPastRecursions(parser, new_max_depth.?);
            } else {
                // Existing entry, so increment the depth and continue.
                var depth = entry.depth;
                if (depth > 0) {
                    depth -= 1;
                }
                try self.recursion.put(parser, .{ .depth = depth, .max_depth = entry.max_depth });
                reentrant_depth = depth;
            }
        } else if (new_max_depth != null) {
            // No existing entry, want to retry with new_max_depth.
            reentrant_depth = new_max_depth.?;
            try self.recursion.put(parser, .{ .depth = new_max_depth.?, .max_depth = new_max_depth.? });
            try self.clearPastRecursions(parser, new_max_depth.?);
        } else {
            // No existing entry, but a distant parent parser may be retrying with a max depth that
            // we should respect.
            var next_node = parser_path.stack.root;
            while (next_node) |next| {
                const parentRecursionEntry = self.recursion.get(next.data);
                if (parentRecursionEntry) |parent_entry| {
                    reentrant_depth = parent_entry.depth;
                    try self.clearPastRecursions(parser, parent_entry.max_depth);
                    break;
                }
                next_node = next.next;
            }
        }

        // Do we have an existing result stream for this key?
        const m = try self.memoized.getOrPut(ParserPosDepthKey{
            .pos_key = parser,
            .reentrant_depth = reentrant_depth,
        });
        if (!m.found_existing) {
            // Create a new result stream for this key.
            var results = try allocator.create(ResultStream(Result(Value)));
            results.* = try ResultStream(Result(Value)).init(allocator, parser);
            m.entry.value = MemoizeValue{
                .results = @ptrToInt(results),
                .deinit = struct {
                    fn deinit(_resultsPtr: usize, _allocator: *mem.Allocator) void {
                        var _results = @intToPtr(*ResultStream(Result(Value)), _resultsPtr);
                        _results.deinit();
                        _allocator.destroy(_results);
                    }
                }.deinit,
            };
        }
        return MemoizedResult(Value){
            .results = @intToPtr(*ResultStream(Result(Value)), m.entry.value.results),
            .was_cached = m.found_existing,
        };
    }

    pub fn init(allocator: *mem.Allocator) !*@This() {
        var self = try allocator.create(@This());
        self.* = .{
            .memoized = std.AutoHashMap(ParserPosDepthKey, MemoizeValue).init(allocator),
            .node_name_cache = std.AutoHashMap(usize, ParserNodeName).init(allocator),
            .recursion = std.AutoHashMap(ParserPosKey, RecursionRetry).init(allocator),
            .deferred_cleanups = std.ArrayList(MemoizeValue).init(allocator),
        };
        return self;
    }

    pub fn deinit(self: *@This(), allocator: *mem.Allocator) void {
        var iter = self.memoized.iterator();
        while (iter.next()) |memoized| {
            memoized.value.deinit(memoized.value.results, allocator);
        }
        self.memoized.deinit();
        self.node_name_cache.deinit();
        self.recursion.deinit();
        for (self.deferred_cleanups.items) |item| {
            item.deinit(item.results, allocator);
        }
        self.deferred_cleanups.deinit();
        allocator.destroy(self);
    }
};

/// Describes context to be given to a `Parser`, such as `input` parameters, an `allocator`, and
/// the actual `src` to parse.
pub fn Context(comptime Input: type, comptime Value: type) type {
    return struct {
        input: Input,
        allocator: *mem.Allocator,
        src: []const u8,
        offset: usize,
        results: *ResultStream(Result(Value)),
        existing_results: bool,
        memoizer: *Memoizer,
        key: ParserPosKey,
        path: ParserPath,

        pub fn init(allocator: *mem.Allocator, src: []const u8, input: Input) !@This() {
            var src_ptr: usize = 0;
            if (src.len > 0) {
                src_ptr = @ptrToInt(&src[0]);
            }
            const key = .{
                .node_name = 0,
                .src_ptr = src_ptr,
                .offset = 0,
            };

            var results = try allocator.create(ResultStream(Result(Value)));
            results.* = try ResultStream(Result(Value)).init(allocator, key);
            return @This(){
                .input = input,
                .allocator = allocator,
                .src = src,
                .offset = 0,
                .results = results,
                .existing_results = false,
                .memoizer = try Memoizer.init(allocator),
                .key = key,
                .path = ParserPath.init(),
            };
        }

        pub fn initChild(self: @This(), comptime NewValue: type, node_name: ParserNodeName, offset: usize) !Context(Input, NewValue) {
            return self.initChildRetry(NewValue, node_name, offset, null);
        }

        /// initChildRetry initializes a child context to be used as a single retry attempt with a
        /// new maximum depth of reentrant parser invocations for the child and all of its
        /// children.
        pub fn initChildRetry(self: @This(), comptime NewValue: type, node_name: ParserNodeName, offset: usize, max_depth: ?usize) !Context(Input, NewValue) {
            const key = ParserPosKey{
                .node_name = node_name,
                .src_ptr = @ptrToInt(&self.src[0]),
                .offset = offset,
            };
            var child_ctx = Context(Input, NewValue){
                .input = self.input,
                .allocator = self.allocator,
                .src = self.src,
                .offset = offset,
                .results = undefined,
                .existing_results = false,
                .memoizer = self.memoizer,
                .key = key,
                .path = try self.path.clone(self.allocator),
            };
            try child_ctx.path.push(child_ctx.key, self.allocator);

            var memoized = try self.memoizer.get(NewValue, self.allocator, child_ctx.path, key, max_depth);
            child_ctx.results = memoized.results;
            if (memoized.was_cached) {
                child_ctx.existing_results = true;
            }
            return child_ctx;
        }

        /// isRetrying tells if this context represents a retry initiated previously via
        /// initChildRetry, potentially by a distant parent recursive call, indicating that a new
        /// reentrant retry should not be attempted.
        pub fn isRetrying(self: @This(), node_name: ParserNodeName, offset: usize) bool {
            return self.memoizer.isRetrying(ParserPosKey{
                .node_name = node_name,
                .src_ptr = @ptrToInt(&self.src[0]),
                .offset = offset,
            });
        }

        pub fn with(self: @This(), new_input: anytype) Context(@TypeOf(new_input), Value) {
            return Context(@TypeOf(new_input), Value){
                .input = new_input,
                .allocator = self.allocator,
                .src = self.src,
                .offset = self.offset,
                .results = self.results,
                .existing_results = self.existing_results,
                .memoizer = self.memoizer,
                .key = self.key,
                .path = self.path,
            };
        }

        pub fn deinit(self: @This()) void {
            self.results.deinit();
            self.allocator.destroy(self.results);
            self.memoizer.deinit(self.allocator);
            self.path.deinit(self.allocator);
            return;
        }

        pub fn deinitChild(self: @This()) void {
            self.path.deinit(self.allocator);
            return;
        }
    };
}

/// An interface whose implementation can be swapped out at runtime. It carries an arbitrary
/// `Context` to make the type signature generic.
pub fn Parser(comptime Value: type) type {
    return struct {
        const Self = @This();
        _parse: fn (self: *const Self, ctx: *const Context(void, Value)) callconv(.Async) Error!void,
        _nodeName: fn (self: *const Self, node_name_cache: *std.AutoHashMap(usize, ParserNodeName)) Error!u64,

        pub fn init(
            parseImpl: fn (self: *const Self, ctx: *const Context(void, Value)) callconv(.Async) Error!void,
            nodeNameImpl: fn (self: *const Self, node_name_cache: *std.AutoHashMap(usize, ParserNodeName)) Error!u64,
        ) @This() {
            return .{ ._parse = parseImpl, ._nodeName = nodeNameImpl };
        }

        pub fn parse(self: *const Self, ctx: *const Context(void, Value)) callconv(.Async) Error!void {
            var frame = try std.heap.page_allocator.allocAdvanced(u8, 16, @frameSize(self._parse), std.mem.Allocator.Exact.at_least);
            defer std.heap.page_allocator.free(frame);
            return try await @asyncCall(frame, {}, self._parse, .{ self, ctx });
        }

        pub fn nodeName(self: *const Self, node_name_cache: *std.AutoHashMap(usize, ParserNodeName)) Error!u64 {
            var v = try node_name_cache.getOrPut(@ptrToInt(self));
            if (!v.found_existing) {
                v.entry.value = 1337; // "currently calculating" code
                const calculated = try self._nodeName(self, node_name_cache);

                // If self._nodeName added more entries to node_name_cache, ours is now potentially invalid.
                var vv = node_name_cache.getEntry(@ptrToInt(self));
                vv.?.value = calculated;
                return calculated;
            }
            if (v.entry.value == 1337) {
                return 0; // reentrant, don't bother trying to calculate any more recursively
            }
            return v.entry.value;
        }
    };
}

test "syntax" {
    const p = Parser([]u8);
}