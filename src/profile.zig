//! The profiling build's sampler, started by `ZFLS_PROFILE_OUT=<prefix>`
//! when built with `-Dprofile-sampler=true` (never in a release); see
//! profile/sampler.zig. Without the build option every function is empty.

const std = @import("std");
const options = @import("build_options");

const enabled = @hasDecl(options, "profile_sampler") and options.profile_sampler;
const Sampler = if (enabled) @import("profile/sampler.zig").Sampler else void;

pub const Handle = if (enabled) ?*Sampler else void;

pub fn start(gpa: std.mem.Allocator, io: std.Io, environ: *const std.process.Environ.Map) Handle {
    if (!enabled) return {};
    const prefix = environ.get("ZFLS_PROFILE_OUT") orelse return null;
    return Sampler.start(gpa, io, prefix) catch null;
}

pub fn stop(h: Handle) void {
    if (!enabled) return;
    if (h) |s| s.stop();
}
