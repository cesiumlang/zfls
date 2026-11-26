//! The flags of a compile_commands.json entry that the compiler check
//! passes on: an allow-list. A flag that can run a program or load code
//! (a wrapper, a tool's location, a plugin, a spec file, a response file)
//! is dropped, and so is every argument that is not a known flag or the
//! value of one.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Flags followed by their value as the next argument
const separate_value = [_][]const u8{
    "/I",     "/D",       "/U",       "-I",       "-J",          "-D",           "-U",      "-x",         "-isystem",      "-iquote", "-idirafter", "-isysroot",
    "-arch",  "-module",  "-mdir",    "-warn",    "-stand",      "-check",       "-assume", "-real-size", "-integer-size", "-align",  "-fp-model",  "-fpe",
    "-names", "-convert", "-include", "-imacros", "-module-dir", "-double-size",
};

/// Flags dropped with the value that follows them
const dropped_with_value = [_][]const u8{ "-o", "-MF", "-MT", "-MQ" };

/// Dropped, as is anything starting with them (they run code, load code or
/// name a tool); compared without case
const denied_prefixes = [_][]const u8{
    "-wrapper",           "-specs",      "-fplugin",           "-fpass-plugin",    "-fuse-ld", "-fuse-linker-plugin", "-fpp-name", "-fload",
    "-xlinker",           "-xassembler", "-xpreprocessor",     "-xclang",          "-xflang",  "-xoffload",           "-mllvm",    "-load",
    "-plugin",            "-qoption",    "-qlocation",         "-wl,",             "-wa,",     "-wp,",                "-wc,",      "-iplugindir",
    "-no-integrated-cpp", "-driver",     "-working-directory", "-pass-exit-codes", "/qoption", "/qlocation",          "/link",     "/wl,",
};

/// Allowed when an argument starts with them
const allowed_prefixes = [_][]const u8{
    "-I",                  "-J",         "-D",            "-U",           "-isystem",     "-iquote",   "-idirafter", "-isysroot", "-std",
    "-f",                  "-W",         "-w",            "-O",           "-g",           "-m",        "-cpp",       "-nocpp",    "-free",
    "-fixed",              "-pedantic",  "-ansi",         "-pipe",        "-pthread",     "-arch",     "--target=",  "-x",        "-q",
    "-no",                 "-warn",      "-stand",        "-extend",      "-traceback",   "-standard", "-ip",        "-implicit", "-heap",
    "-auto",               "-save",      "-zero",         "-mkl",         "-openmp",      "-parallel", "-gen",       "-diag",     "-real",
    "-integer",            "-double",    "-align",        "-assume",      "-check",       "-names",    "-convert",   "-fp",       "-fpe",
    "-pad",                "-module",    "-mdir",         "-C",           "-dusty",       "-colour",   "-kind=",     "-ieee=",    "-info",
    "-nologo",             "-include",   "-imacros",      "-M",           "-acc",         "-cuda",     "-gpu",       "-tp",       "-i8",
    "-r8",                 "-i4",        "-r4",           "-d8",          "-d16",         "-lfs",
    // Windows
         "/I",         "/D",        "/U",
    "/module:",            "/nologo",    "/warn",         "/free",        "/fixed",       "/fpp",      "/nofpp",     "/stand",    "/std",
    "/Q",                  "/O",         "/Z",            "/W",           "/w",           "/MD",       "/MT",        "/debug",    "/assume",
    "/check",              "/real-size", "/integer-size", "/double-size", "/align",       "/fp",       "/names",     "/iface",    "/extend-source",
    "/standard-semantics", "/traceback", "/libs",         "/threads",     "/heap-arrays", "/4",        "/G",
};

fn startsWithNoCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

fn isIn(set: []const []const u8, x: []const u8) bool {
    for (set) |o| if (std.mem.eql(u8, x, o)) return true;
    return false;
}

/// Whether `x` is a flag that runs or loads something, or names a tool
pub fn isDenied(x: []const u8) bool {
    // a response file, which the compilers' drivers expand wherever it is,
    // as the value of a flag too, into flags this list never sees
    if (x.len > 0 and x[0] == '@') return true;
    // -B<dir>: where the driver looks for its programs
    if (std.mem.startsWith(u8, x, "-B")) return true;
    for (denied_prefixes) |p| if (startsWithNoCase(x, p)) return true;
    // a pass-through list of options for a tool
    if (std.mem.startsWith(u8, x, "-W") and std.mem.findScalar(u8, x, ',') != null) return true;
    return false;
}

fn isAllowed(x: []const u8) bool {
    if (x.len < 2) return false;
    if (isDenied(x)) return false;
    // the dependency options, dropped as are `-c` and the output file
    if (isIn(&.{ "-M", "-MM", "-MD", "-MMD", "-MP", "-MG", "-c", "/c" }, x)) return false;
    if (std.mem.startsWith(u8, x, "-MF") or std.mem.startsWith(u8, x, "-MT") or std.mem.startsWith(u8, x, "-MQ")) return false;
    if (std.mem.startsWith(u8, x, "-o") and !std.mem.startsWith(u8, x, "-openmp")) return false;
    for (allowed_prefixes) |p| if (std.mem.startsWith(u8, x, p)) return true;
    return false;
}

/// The arguments of a command (the compiler first, kept as it is) that
/// pass the allow-list, each flag with its value
pub fn safeArgs(a: Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (args.len == 0) return out.items;
    try out.append(a, args[0]);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (isIn(&dropped_with_value, x)) {
            i += 1;
            continue;
        }
        if (isIn(&separate_value, x)) {
            if (i + 1 >= args.len) break;
            i += 1;
            // a value that is itself a denied flag is not a value
            if (isDenied(args[i])) continue;
            try out.appendSlice(a, args[i - 1 .. i + 1]);
            continue;
        }
        if (isAllowed(x)) try out.append(a, x);
    }
    return out.items;
}

test "flags that run or load code are dropped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try safeArgs(a, &.{
        "gfortran", "-wrapper",    "sh,-c,x",    "-B/tmp/x",      "-specs=s.spec",  "-fplugin=p.so",  "-fplugin-arg-p-k=v", "-Xlinker",
        "-v",       "@resp.txt",   "-Wl,-x",     "-Qoption,a,b",  "/Qlocation,f,d", "-fpp-name=prog", "-fuse-ld=ld",        "-I",
        "inc",      "-DX=1",       "-std=f2018", "-c",            "a.f90",          "-o",             "a.o",                "-Wall",
        "-cpp",     "-ffree-form", "-x",         "f95-cpp-input", "-J",             "mod",            "other.o",            "-MF",
        "a.d",      "-MD",         "-fopenmp",   "-O2",
    });
    const want = [_][]const u8{ "gfortran", "-I", "inc", "-DX=1", "-std=f2018", "-Wall", "-cpp", "-ffree-form", "-x", "f95-cpp-input", "-J", "mod", "-fopenmp", "-O2" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "a response file is dropped, also as the value of a flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try safeArgs(a, &.{ "gfortran", "-D", "@pwn", "-I", "@inc", "/D", "@x", "@all.rsp", "-I", "inc", "-DA@B" });
    const want = [_][]const u8{ "gfortran", "-I", "inc", "-DA@B" };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

test "the flags of real projects' commands stay" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const keep = [_][]const u8{
        "gfortran",       "-I/src/inc", "-isystem",    "/usr/inc",                "-DNAME", "-UNAME",  "-std=f2008",    "-fdefault-real-8", "-ffixed-line-length-none",
        "-fcheck=bounds", "-Wall",      "-Wno-unused", "-Werror=line-truncation", "-g",     "-O3",     "-march=native", "-fPIC",            "-pedantic",
        "-fopenmp",       "-cpp",       "-J/b/mod",    "-module",                 "mods",   "/nologo", "/warn:all",     "/module:mods",     "/Qopenmp",
        "/I",             "inc",        "-warn",       "all",                     "-stand", "f18",     "-free",         "-fpp",             "-traceback",
        "-qopenmp",       "-Mfree",     "-gdwarf-4",   "-pthread",
    };
    const got = try safeArgs(a, &keep);
    try std.testing.expectEqual(keep.len, got.len);
}
