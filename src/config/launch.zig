const std = @import("std");
const Command = @import("command.zig").Command;

pub const Policy = enum { normal, controlled };

pub const Error = error{
    LaunchUnsupportedPlatform,
    LaunchPolicyRequiresFreshConfig,
    LaunchPolicyDowngrade,
    LaunchPreparationFailed,
    LaunchConfigDiagnostics,
    LaunchCommandRequired,
    LaunchCommandMustBeDirect,
    LaunchExecutableMustBeAbsolute,
    LaunchArgumentContainsNul,
    LaunchWorkingDirectoryRequired,
    LaunchWorkingDirectoryMustBeAbsolute,
    LaunchWorkingDirectoryContainsNul,
    LaunchShellIntegrationEnabled,
    LaunchCommandOverrideUnsupported,
    LaunchIdentityInvalid,
};

/// Records preparation before any defaults can be synthesized. A failed
/// controlled preparation cannot be recovered by ignoring its diagnostic.
pub const Preparation = enum {
    fresh,
    normal,
    controlled,
    failed_controlled,

    pub fn check(self: Preparation, policy: Policy, os: std.Target.Os.Tag) Error!void {
        switch (self) {
            .fresh => {},
            .normal => if (policy == .controlled)
                return error.LaunchPolicyRequiresFreshConfig,
            .controlled => if (policy == .normal)
                return error.LaunchPolicyDowngrade,
            .failed_controlled => return error.LaunchPreparationFailed,
        }
        if (policy == .controlled and os != .macos)
            return error.LaunchUnsupportedPlatform;
    }

    pub fn begin(self: *Preparation, policy: Policy, os: std.Target.Os.Tag) Error!void {
        try self.check(policy, os);
        self.* = switch (policy) {
            .normal => .normal,
            .controlled => .controlled,
        };
    }

    pub fn fail(self: *Preparation, policy: Policy) void {
        self.* = if (policy == .controlled or self.* == .controlled or
            self.* == .failed_controlled)
            .failed_controlled
        else
            .normal;
    }
};

pub fn isError(err: anyerror) bool {
    inline for (@typeInfo(Error).error_set.?) |field| {
        if (err == @field(Error, field.name)) return true;
    }
    return false;
}

pub fn validateCommand(command: ?Command) Error!void {
    const argv = switch (command orelse return error.LaunchCommandRequired) {
        .shell => return error.LaunchCommandMustBeDirect,
        .direct => |argv| argv,
    };
    if (argv.len == 0) return error.LaunchCommandRequired;
    for (argv) |arg| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null)
            return error.LaunchArgumentContainsNul;
    }
    if (argv[0].len == 0 or argv[0][0] != '/')
        return error.LaunchExecutableMustBeAbsolute;
}

pub fn selectCommand(
    policy: Policy,
    base: ?Command,
    initial: ?Command,
    first: bool,
) Error!?Command {
    const selected = if (first and initial != null) initial else base;
    if (policy == .controlled) try validateCommand(selected);
    return selected;
}

pub fn validateWorkingDirectory(path: ?[]const u8) Error!void {
    const value = path orelse return error.LaunchWorkingDirectoryRequired;
    if (std.mem.indexOfScalar(u8, value, 0) != null)
        return error.LaunchWorkingDirectoryContainsNul;
    if (value.len == 0 or value[0] != '/')
        return error.LaunchWorkingDirectoryMustBeAbsolute;
}

pub fn validateIdentity(name: ?[]const u8) Error!void {
    const value = name orelse return error.LaunchIdentityInvalid;
    if (value.len == 0 or value.len > 255 or value[0] == '-' or
        std.mem.indexOfScalar(u8, value, 0) != null)
        return error.LaunchIdentityInvalid;
}

pub fn validateCommandOverride(policy: Policy, present: bool) Error!void {
    if (policy == .controlled and present)
        return error.LaunchCommandOverrideUnsupported;
}

test "launch policy pure preparation provenance" {
    const testing = std.testing;
    var state: Preparation = .fresh;
    try state.begin(.normal, .macos);
    try testing.expectError(error.LaunchPolicyRequiresFreshConfig, state.check(.controlled, .macos));
    state.fail(.normal);
    try testing.expectError(error.LaunchPolicyRequiresFreshConfig, state.check(.controlled, .macos));
    try state.check(.normal, .macos);
    state = .fresh;
    try state.begin(.controlled, .macos);
    try testing.expectError(error.LaunchPolicyDowngrade, state.check(.normal, .macos));
    state.fail(.controlled);
    try testing.expectError(error.LaunchPreparationFailed, state.check(.controlled, .macos));
    try testing.expectError(error.LaunchPreparationFailed, state.check(.normal, .macos));
    try testing.expectError(error.LaunchUnsupportedPlatform, Preparation.fresh.check(.controlled, .linux));
    try testing.expectError(error.LaunchUnsupportedPlatform, Preparation.fresh.check(.controlled, .windows));
    try testing.expectError(error.LaunchUnsupportedPlatform, Preparation.fresh.check(.controlled, .ios));
}

test "launch policy pure effective argv validation" {
    const testing = std.testing;
    const valid: Command = .{ .direct = &.{ "/bin/program", "a b'c", "" } };
    try validateCommand(valid);
    try testing.expectError(error.LaunchCommandRequired, validateCommand(null));
    try testing.expectError(error.LaunchCommandRequired, validateCommand(.{ .direct = &.{} }));
    try testing.expectError(error.LaunchExecutableMustBeAbsolute, validateCommand(.{ .direct = &.{""} }));
    try testing.expectError(error.LaunchExecutableMustBeAbsolute, validateCommand(.{ .direct = &.{"program"} }));
    try testing.expectError(error.LaunchCommandMustBeDirect, validateCommand(.{ .shell = "/bin/program" }));
    try testing.expectError(error.LaunchArgumentContainsNul, validateCommand(.{ .direct = &.{"/bin/prog\x00ram"} }));
    try testing.expectError(error.LaunchArgumentContainsNul, validateCommand(.{ .direct = &.{ "/bin/program", "a\x00b" } }));
    try testing.expectError(error.LaunchCommandMustBeDirect, selectCommand(.controlled, valid, .{ .shell = "bad" }, true));
    try testing.expectEqual(valid.direct.ptr, (try selectCommand(.controlled, valid, .{ .shell = "bad" }, false)).?.direct.ptr);
    try testing.expect((try selectCommand(.normal, null, null, true)) == null);
    try testing.expectError(error.LaunchCommandRequired, selectCommand(.controlled, null, valid, false));
}

test "launch policy pure cwd identity and override validation" {
    const testing = std.testing;
    try validateWorkingDirectory("/owned space'/child");
    try testing.expectError(error.LaunchWorkingDirectoryRequired, validateWorkingDirectory(null));
    for ([_][]const u8{ "", ".", "~/child", "home", "inherit" }) |path| {
        try testing.expectError(error.LaunchWorkingDirectoryMustBeAbsolute, validateWorkingDirectory(path));
    }
    try testing.expectError(error.LaunchWorkingDirectoryContainsNul, validateWorkingDirectory("/a\x00b"));
    try validateIdentity("account");
    try validateIdentity(&([_]u8{'a'} ** 255));
    for ([_]?[]const u8{ null, "", "-account", "a\x00b", &([_]u8{'a'} ** 256) }) |name| {
        try testing.expectError(error.LaunchIdentityInvalid, validateIdentity(name));
    }
    try validateCommandOverride(.normal, true);
    try validateCommandOverride(.controlled, false);
    try testing.expectError(error.LaunchCommandOverrideUnsupported, validateCommandOverride(.controlled, true));
}
