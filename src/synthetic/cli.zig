const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");

/// The available actions for the CLI. This is the list of available
/// synthetic generators. View docs for each individual one in the
/// predictably named files under `cli/`.
pub const Action = enum {
    ascii,
    kitty,
    osc,
    utf8,

    /// Returns the struct associated with the action. The struct
    /// should have a few decls:
    ///
    ///   - `const Options`: The CLI options for the action.
    ///   - `fn create`: Create a new instance of the action from options.
    ///   - `fn destroy`: Destroy the instance of the action.
    ///
    /// See TerminalStream for an example.
    pub fn Struct(comptime action: Action) type {
        return switch (action) {
            .ascii => @import("cli/Ascii.zig"),
            .kitty => @import("cli/Kitty.zig"),
            .osc => @import("cli/Osc.zig"),
            .utf8 => @import("cli/Utf8.zig"),
        };
    }
};

/// An entrypoint for the synthetic generator CLI.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const action_ = try cli.action.detectArgs(Action, alloc, init.minimal.args);
    const action = action_ orelse return error.NoAction;
    try mainAction(alloc, action, init.io, init.environ_map, .{
        .cli = init.minimal.args,
    });
}

pub const Args = union(enum) {
    /// The arguments passed to the CLI via argc/argv.
    cli: std.process.Args,

    /// Simple string arguments, parsed via std.process.Args.IteratorGeneral.
    string: []const u8,
};

pub fn mainAction(
    alloc: Allocator,
    action: Action,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: Args,
) !void {
    switch (action) {
        inline else => |comptime_action| {
            const Impl = Action.Struct(comptime_action);
            try mainActionImpl(Impl, alloc, io, env, args);
        },
    }
}

fn mainActionImpl(
    comptime Impl: type,
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: Args,
) !void {
    // First, parse our CLI options.
    const Options = Impl.Options;
    var opts: Options = .{};
    defer if (@hasDecl(Options, "deinit")) opts.deinit();
    switch (args) {
        .cli => |a| {
            var iter = try cli.args.argsIterator(a, alloc);
            defer iter.deinit();
            try cli.args.parse(Options, alloc, io, env, &opts, &iter);
        },
        .string => |str| {
            var iter = try std.process.Args.IteratorGeneral(.{}).init(
                alloc,
                str,
            );
            defer iter.deinit();
            try cli.args.parse(Options, alloc, io, env, &opts, &iter);
        },
    }

    // TODO: Make this a command line option.
    var seed: u64 = undefined;
    std.Io.random(io, std.mem.asBytes(&seed));
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    // Our output always goes to stdout.
    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
    const writer = &stdout_writer.interface;

    // Create our implementation
    const impl = try Impl.create(alloc, opts);
    defer impl.destroy(alloc);
    try impl.run(writer, rand);

    // Always flush
    writer.flush() catch |err| switch (err) {
        error.WriteFailed => return,
    };
}

test {
    // Make sure we ref all our actions
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action = @field(Action, field.name);
        const Impl = Action.Struct(action);
        _ = Impl;
    }
}
