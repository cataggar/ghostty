const std = @import("std");

pub fn substitute(b: *std.Build, source: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("src/build/install-prefix.py"));
    run.addFileArg(source);
    run.addDirectoryArg(b.graph.path(.install_prefix, ""));
    return run.captureStdOut(.{});
}
