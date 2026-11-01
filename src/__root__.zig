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
pub const json5 = @import("json5.zig");
pub const intrinsics = @import("intrinsics.zig");
pub const settings = @import("settings.zig");
pub const glob = @import("glob.zig");
pub const jsonrpc = @import("jsonrpc.zig");
pub const logger = @import("logger.zig");
pub const constructs = @import("constructs.zig");
pub const arguments = @import("arguments.zig");
pub const autouse = @import("autouse.zig");
pub const selection = @import("selection.zig");
pub const fuzzy = @import("fuzzy.zig");
pub const implicit = @import("implicit.zig");
pub const unused = @import("unused.zig");
pub const modgraph = @import("modgraph.zig");
pub const argcheck = @import("argcheck.zig");
pub const literals = @import("literals.zig");
pub const rewrite = @import("rewrite.zig");
pub const outline = @import("outline.zig");
pub const project = @import("project.zig");
pub const semantic = @import("semantic.zig");
pub const suppress = @import("suppress.zig");
pub const server = @import("server.zig");
pub const version_info = @import("version.zig");
pub const debug = @import("debug.zig");

test {
    std.testing.refAllDecls(@This());
}
