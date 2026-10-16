const std = @import("std");

pub const main = @import("__main__.zig").main;
// pub const std_options = impl.std_options;
// pub const std_options_debug_io = impl.std_options_debug_io;

const build_options = @import("build_options");
pub const version = build_options.version;
pub const app_name = "zfls";

pub const regex = @import("regex.zig");
pub const str = @import("str.zig");
pub const patterns = @import("patterns.zig");
pub const constants = @import("constants.zig");
pub const helpers = @import("helpers.zig");
pub const paths = @import("paths.zig");
pub const objects = @import("objects.zig");
pub const parser = @import("parser.zig");
pub const preprocessor = @import("preprocessor.zig");
pub const json = @import("json.zig");
pub const intrinsics = @import("intrinsics.zig");
pub const settings = @import("settings.zig");
pub const glob = @import("glob.zig");
pub const jsonrpc = @import("jsonrpc.zig");
pub const logger = @import("logger.zig");
pub const server = @import("server.zig");
pub const version_info = @import("version.zig");
pub const debug = @import("debug.zig");

test {
    std.testing.refAllDecls(@This());
}
