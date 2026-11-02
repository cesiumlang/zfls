/* zfls dap's test program (tests/dap_windows.py): built for the MSVC ABI,
 * with a PDB */
#include <stdio.h>

static int counter = 42;

int twice(int n) {
    int doubled = 2 * n;
    return doubled;
}

int main(void) {
    int x = 21;
    int y = twice(x);
    printf("%d %d\n", y, counter);
    return 3;
}
