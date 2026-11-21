# zfls dap (ifx_class.zig): the dynamic type of Intel ifx's polymorphic
# object E (declared type D), from its descriptor; sets $N and prints
# `zfls-class TYPE` (with `(BOUNDS)` for an array)
import gdb, re, struct
def zfls_ifx_word(inf, at):
    return struct.unpack('<Q', inf.read_memory(at, 8).tobytes())[0]
def zfls_ifx_class(E, N, D):
    v = gdb.parse_and_eval(E)
    if v.type.strip_typedefs().code == gdb.TYPE_CODE_PTR:
        data = int(v)
    elif v.address is not None:
        data = int(v.address)
    else:
        return
    where = gdb.execute('info address ' + E, to_string=True)
    f, inf = gdb.selected_frame(), gdb.selected_inferior()
    places = []
    m = re.search(r'DW_OP_fbreg (-?\d+)\s+\d+: DW_OP_deref\s+\d+: DW_OP_deref\s*[,.]', where)
    if m:
        places.append(zfls_ifx_word(inf, int(f.read_register('rbp')) + int(m.group(1))))
    m = re.search(r'static storage at address (0x[0-9a-fA-F]+)', where)
    if m:
        places.append(int(m.group(1), 16))
    m = re.search(r'frame base reg \$(\w+) offset (-?\d+)\+(-?\d+)', where)
    if m:
        places.append(int(f.read_register(m.group(1))) + int(m.group(2)) + int(m.group(3)))
    for at in places:
        try:
            w = struct.unpack('<6Q', inf.read_memory(at, 48).tobytes())
        except gdb.MemoryError:
            continue
        if data == 0 or w[0] != data or w[4] > 7:
            continue
        rank, size = w[4], w[1]
        dims = [struct.unpack('<3q', inf.read_memory(at + 48 + 24 * k, 24).tobytes()) for k in range(rank)]
        record = zfls_ifx_word(inf, at + 8 * (6 + 3 * rank))
        if record == 0:
            return
        name = inf.read_memory(zfls_ifx_word(inf, record), 128).tobytes().split(b'\0')[0].decode('ascii', 'replace')
        if not re.fullmatch(r'\w+#\w+', name):
            return
        module, typ = name.lower().split('#')
        if rank == 0 and typ == D.lower():
            return
        blocks = [None]
        b = f.block()
        while b is not None:
            blocks.append(b)
            b = b.superblock
        found = None
        for c in (module + '::' + typ, typ):
            for b in blocks:
                try:
                    found = gdb.lookup_type(c, b) if b is not None else gdb.lookup_type(c)
                    break
                except gdb.error:
                    continue
            if found is not None:
                break
        if found is None or found.sizeof != size:
            return
        if rank == 0:
            gdb.set_convenience_variable(N, gdb.Value(data).cast(found.pointer()))
            print('zfls-class ' + typ)
            return
        if getattr(found, 'dynamic', True):
            return
        stride = size
        for extent, sm, lower in dims:
            if extent > 1 and sm != stride:
                return
            stride *= extent
        array = found
        for extent, sm, lower in reversed(dims):
            array = array.array(lower, lower + extent - 1)
        gdb.set_convenience_variable(N, gdb.Value(data).cast(array.pointer()).dereference())
        bounds = ','.join(str(e) if lo == 1 else '%d:%d' % (lo, lo + e - 1) for e, sm, lo in dims)
        print('zfls-class %s (%s)' % (typ, bounds))
        return
