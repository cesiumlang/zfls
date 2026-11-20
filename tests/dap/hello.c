/* zfls dap's test program (tests/dap_windows.zig): MSVC ABI, PDB, the ifx
 * kit (no Visual Studio, so no headers: puts is the Universal CRT's) */
int puts(const char *s);

static int counter = 42;

int twice(int n) {
    int doubled = 2 * n;
    return doubled;
}

int main(void) {
    int x = 21;
    int y = twice(x);
    puts(y == counter ? "42 42" : "?");
    return 3;
}
