/* zfls dap's attach on Windows's Debugger Engine (tests/dap_engine_attach.zig):
 * the program waits for a line on its input, for the debugger to attach
 * first (the ifx kit has no headers: the Universal CRT's functions) */
int getchar(void);
int puts(const char *s);

int twice(int n) {
    int doubled = 2 * n;
    return doubled;
}

int main(void) {
    int c = getchar();
    int y = twice(c - '0');
    puts(y == 6 ? "6" : "?");
    return 4;
}
