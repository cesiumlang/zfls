/* zfls dap's test program of a break instruction (tests/dap_windows.zig):
 * the program's own `int 3`, as the Intel runtime executes in
 * for__issue_diagnostic at a runtime error under a debugger */
#include <intrin.h>

int main(void) {
    __debugbreak();
    return 5;
}
