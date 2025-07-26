const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("CliParse", .{
        .root_source_file = b.path("src/cli_parse.zig"),
        .target = target,
        .optimize = optimize,
    });
}
