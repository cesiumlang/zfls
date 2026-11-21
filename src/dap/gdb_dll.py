import gdb, os, struct
zfls_dll_want = ZFLS_WANT
zfls_dll_on = True
zfls_dll_bps = []
zfls_dll_names = {}
def zfls_dll_exports(path):
    with open(path, 'rb') as f:
        d = f.read()
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    nsec, = struct.unpack_from('<H', d, pe + 6)
    optsize, = struct.unpack_from('<H', d, pe + 20)
    opt = pe + 24
    magic, = struct.unpack_from('<H', d, opt)
    exp_rva, = struct.unpack_from('<I', d, opt + (112 if magic == 0x20b else 96))
    secs = [struct.unpack_from('<8sIIII', d, opt + optsize + 40 * i) for i in range(nsec)]
    def off(rva):
        for n, vs, va, rs, rp in secs:
            if va <= rva < va + max(vs, rs):
                return rva - va + rp
        raise ValueError(rva)
    e = off(exp_rva)
    nfun, nnames, afun, anames, aords = struct.unpack_from('<IIIII', d, e + 20)
    out = {}
    for i in range(nnames):
        o = off(struct.unpack_from('<I', d, off(anames) + 4 * i)[0])
        name = d[o:d.index(b'\0', o)].decode()
        if name in zfls_dll_want:
            ordinal, = struct.unpack_from('<H', d, off(aords) + 2 * i)
            out[name] = struct.unpack_from('<I', d, off(afun) + 4 * ordinal)[0]
    text = [va for n, vs, va, rs, rp in secs if n.rstrip(b'\0') == b'.text'][0]
    return out, text
def zfls_dll_loaded(ev):
    path = ev.new_objfile.filename
    base = os.path.basename(path).lower()
    if not (base.startswith('libgfortran-') and base.endswith('.dll')):
        return
    try:
        exports, text = zfls_dll_exports(path)
        start = None
        for line in gdb.execute('info sharedlibrary', to_string=True).splitlines():
            if line.lower().rstrip().endswith(base) and line.lstrip().startswith('0x'):
                start = int(line.split()[0], 16)
        if start is None:
            return
        # gdb's Fortran overflows on a 64-bit address: C reads it
        language = gdb.parameter('language')
        gdb.execute('set language c')
        try:
            for name, rva in exports.items():
                b = gdb.Breakpoint('*0x%x' % (start - text + rva), internal=True)
                if zfls_dll_want[name]:
                    b.condition = zfls_dll_want[name]
                b.enabled = zfls_dll_on
                zfls_dll_bps.append(b)
                zfls_dll_names[b.number] = name
        finally:
            gdb.execute('set language %s' % language)
    except Exception as x:
        gdb.write('zfls dap: no breakpoints in %s: %s\n' % (base, x))
def zfls_dll_enable(on):
    global zfls_dll_on
    zfls_dll_on = on
    for b in zfls_dll_bps:
        b.enabled = on
def zfls_dll_name(number):
    print('zfls-dll %s' % zfls_dll_names.get(number, ''))
gdb.events.new_objfile.connect(zfls_dll_loaded)
