// zfls dap's C++ exception filters (tests/dap_gdb_cpp.zig): C++ that
// throws and catches, for tests/dap/mixed.f90
#include <stdexcept>

extern "C" int twice(int n) {
    try {
        if (n < 0) throw std::invalid_argument("negative");
        return 2 * n;
    } catch (const std::exception &) {
        return 0;
    }
}
