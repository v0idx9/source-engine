#!/usr/bin/env python
"""
Compile Source .fxc shader sources into .vcs shader packs.

Why this exists
---------------
Valve's pipeline is buildshaders.bat -> perl -> nmake -> shadercompile.exe, where
shadercompile.exe is a VMPI-distributed farm tool that nothing in this (waf-only,
Windows-project-less) tree can build. All it actually does, though, is:

  1. enumerate the combos declared in the .fxc,
  2. drop the ones matching a SKIP expression,
  3. invoke fxc.exe once per surviving combo,
  4. pack the resulting bytecode into a .vcs.

fxc.exe is already vendored at dx9sdk/utilities/fxc.exe, so this script does those
four steps directly and skips the farm entirely.

Why we need it at all: this engine's stdshaders have diverged from the retail .vcs
that ship in hl2_misc.vpk. lightmappedgeneric_ps20b declares 96 dynamic combos here
but the retail file has 288, so CShaderManager computes
`m_nStaticIndex / m_nDynamicCombos` against the wrong divisor, fails the lookup, and
falls back to combo 0 -- rendering every world surface, prop and VGUI glyph with a
garbage shader variant.

Combo index math is NOT invented here. It is the running-product scheme that
fxc_prep.pl uses and that the pre-generated fxctmp9/*.inc encode -- and those .inc
are what the engine's C++ was compiled against, so they are ground truth.
`--validate-inc` re-derives the multipliers from the .fxc and diffs them against
every .inc in the tree; it must pass before any output is trustworthy.
"""

import os
import re
import sys
import struct
import argparse

STDSHADERS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                          "materialsystem", "stdshaders")
STDSHADERS = os.path.normpath(STDSHADERS)
INCDIR = os.path.join(STDSHADERS, "fxctmp9")


# ---------------------------------------------------------------------------
# .fxc parsing -- mirrors devtools/bin/fxc_prep.pl
# ---------------------------------------------------------------------------

def read_input_file(path, base_dir, depth=0):
    """Inline #include "..." exactly like fxc_prep.pl's ReadInputFile."""
    if depth > 16:
        return []
    out = []
    try:
        with open(path, "r", errors="replace") as f:
            lines = f.readlines()
    except IOError:
        return []
    for line in lines:
        m = re.search(r'#include\s+"(.*)"', line, re.I)
        if m:
            inc = os.path.join(base_dir, m.group(1))
            if os.path.exists(inc):
                out.extend(read_input_file(inc, base_dir, depth + 1))
            # perl would die on a missing include; in practice they all resolve.
        else:
            out.append(line)
    return out


class Combos(object):
    def __init__(self):
        self.statics = []    # (name, min, max)
        self.dynamics = []
        self.skips = []      # raw perl-ish expression strings
        self.centroid_mask = 0


def parse_fxc(fxc_path, basename, x360=False):
    """Parse combo/skip/centroid directives for one target basename (e.g.
    'lightmappedgeneric_ps20b'). Tag filtering mirrors fxc_prep.pl lines ~741-770."""
    lines = read_input_file(fxc_path, os.path.dirname(fxc_path))

    psver = None
    vsver = None
    m = re.search(r'_ps(\d+\w?)$', basename, re.I)
    if m:
        psver = m.group(1)
    m = re.search(r'_vs(\d+\w?)$', basename, re.I)
    if m:
        vsver = m.group(1)

    # Pass 1 mutates the lines in place; perl aliases $line into @fxc so the SKIP /
    # CENTROID passes below see the same edits. Replicate that by rewriting the list.
    filtered = []
    for line in lines:
        if x360 and '[PC]' in line:
            line = ''
        if (not x360) and '[XBOX]' in line:
            line = ''
        if psver and re.search(r'\[ps\d+\w?\]', line, re.I) \
                and not re.search(r'\[ps%s\]' % re.escape(psver), line, re.I):
            line = ''
        if vsver and re.search(r'\[vs\d+\w?\]', line, re.I) \
                and not re.search(r'\[vs%s\]' % re.escape(vsver), line, re.I):
            line = ''
        # perl: s/\[[^\[\]]*\]//  -- no /g, so only the FIRST bracket group goes.
        line = re.sub(r'\[[^\[\]]*\]', '', line, count=1)
        filtered.append(line)

    c = Combos()
    for line in filtered:
        if re.match(r'^\s*$', line):
            continue
        m = re.match(r'^\s*//\s*STATIC\s*:\s*"(.*)"\s+"(\d+)\.\.(\d+)"', line)
        if m:
            c.statics.append((m.group(1).strip(), int(m.group(2)), int(m.group(3))))
            continue
        m = re.match(r'^\s*//\s*DYNAMIC\s*:\s*"(.*)"\s+"(\d+)\.\.(\d+)"', line)
        if m:
            c.dynamics.append((m.group(1).strip(), int(m.group(2)), int(m.group(3))))
            continue

    # perl requires the colon: m/^\s*\/\/\s*SKIP\s*\s*\:\s*(.*)$/
    # Some .fxc have "// SKIP (expr)" with no colon -- Valve's own tooling silently
    # ignores those, so we must too. Ignoring a skip only ever compiles MORE combos
    # than needed (harmless); honouring one Valve drops would omit a combo the engine
    # asks for (fatal), so erring this way is also the safe direction.
    for line in filtered:
        m = re.match(r'^\s*//\s*SKIP\s*\:\s*(.*)$', line)
        if m:
            expr = m.group(1).strip()
            if expr:
                c.skips.append(expr)
        m = re.match(r'^\s*//\s*CENTROID\s*\:\s*TEXCOORD(\d+)\s*$', line)
        if m:
            c.centroid_mask |= (1 << int(m.group(1)))

    return c


def compute_multipliers(c):
    """Running product: dynamics first (starting at 1), then statics continue from
    the dynamic total. This is what fxctmp9/*.inc encodes."""
    dyn_mult = []
    mult = 1
    for (name, lo, hi) in c.dynamics:
        dyn_mult.append(mult)
        mult *= (hi - lo + 1)
    num_dynamic = mult

    stat_mult = []
    for (name, lo, hi) in c.statics:
        stat_mult.append(mult)
        mult *= (hi - lo + 1)
    total = mult
    return dyn_mult, num_dynamic, stat_mult, total


# ---------------------------------------------------------------------------
# .inc cross-check
# ---------------------------------------------------------------------------

def parse_inc_getindex(inc_path):
    """Pull the ( mult * m_nNAME ) terms out of both GetIndex() bodies."""
    with open(inc_path, "r", errors="replace") as f:
        text = f.read()
    results = []
    for m in re.finditer(r'int GetIndex\(\)\s*\{(.*?)\}', text, re.S):
        body = m.group(1)
        ret = re.search(r'return\s+(.*?);', body, re.S)
        if not ret:
            continue
        terms = re.findall(r'\(\s*(\d+)\s*\*\s*m_n(\w+)\s*\)', ret.group(1))
        results.append([(name, int(mult)) for (mult, name) in terms])
    return results  # [static_terms, dynamic_terms] in file order


def shader_targets(list_file):
    """Expand a stdshader_*.txt list into (src_fxc, target_basename) pairs, per
    valve_perl_helpers.pl LoadShaderListFile."""
    out = []
    with open(list_file, "r", errors="replace") as f:
        for line in f:
            line = re.sub(r'//.*$', '', line).strip()
            if not line or not re.search(r'\.(fxc|vsh|psh)$', line, re.I):
                continue
            if not line.lower().endswith('.fxc'):
                continue
            base = re.sub(r'\.fxc$', '', line, flags=re.I)
            if re.search(r'_ps2x', base, re.I):
                out.append((line, re.sub(r'_ps2x', '_ps20', base, flags=re.I)))
                out.append((line, re.sub(r'_ps2x', '_ps20b', base, flags=re.I)))
            elif re.search(r'_vsxx', base, re.I):
                out.append((line, re.sub(r'_vsxx', '_vs11', base, flags=re.I)))
                out.append((line, re.sub(r'_vsxx', '_vs20', base, flags=re.I)))
            else:
                out.append((line, base))
    return out


def cmd_validate_inc(args):
    lists = [os.path.join(STDSHADERS, n) for n in
             ("stdshader_dx9_20b.txt", "stdshader_dx9_30.txt")]
    targets = []
    for l in lists:
        if os.path.exists(l):
            targets.extend(shader_targets(l))

    checked = failed = missing = 0
    failures = []
    for (src, base) in targets:
        inc = os.path.join(INCDIR, base + ".inc")
        fxc = os.path.join(STDSHADERS, src)
        if not os.path.exists(inc) or not os.path.exists(fxc):
            missing += 1
            continue
        c = parse_fxc(fxc, base)
        dyn_mult, num_dyn, stat_mult, total = compute_multipliers(c)

        inc_terms = parse_inc_getindex(inc)
        if len(inc_terms) != 2:
            missing += 1
            continue
        inc_static, inc_dynamic = inc_terms[0], inc_terms[1]

        ours_static = [(n, m) for ((n, lo, hi), m) in zip(c.statics, stat_mult)]
        ours_dynamic = [(n, m) for ((n, lo, hi), m) in zip(c.dynamics, dyn_mult)]

        checked += 1
        if ours_static != inc_static or ours_dynamic != inc_dynamic:
            failed += 1
            if len(failures) < 6:
                failures.append((base, ours_static, inc_static, ours_dynamic, inc_dynamic))

    print("validated %d shader targets against fxctmp9/*.inc" % checked)
    print("  matched : %d" % (checked - failed))
    print("  MISMATCH: %d" % failed)
    print("  skipped (no .inc/.fxc): %d" % missing)
    for (base, os_, is_, od_, id_) in failures:
        print("\n--- MISMATCH %s" % base)
        print("  ours static : %s" % (os_,))
        print("  inc  static : %s" % (is_,))
        print("  ours dynamic: %s" % (od_,))
        print("  inc  dynamic: %s" % (id_,))
    return 1 if failed else 0


# ---------------------------------------------------------------------------
# combo enumeration + SKIP evaluation
# ---------------------------------------------------------------------------

def translate_skip(expr, declared):
    """Perl-ish skip expression -> Python. Operators seen in practice: $VAR, &&,
    ||, !, ==, !=, <, >, parens, and perl's `defined`."""
    e = re.sub(r'\$(\w+)', r'\1', expr)
    # perl `defined $X` asks whether the var exists at all. After tag filtering a
    # var may legitimately not exist for this target, so resolve it to a constant
    # against the declared set rather than leaving a bare name to evaluate.
    e = re.sub(r'\bdefined\s+(\w+)',
               lambda m: 'True' if m.group(1) in declared else 'False', e)
    e = e.replace('&&', ' and ').replace('||', ' or ')
    # '!' is negation, but must not eat the '!' of '!='
    e = re.sub(r'!(?!=)', ' not ', e)
    # A leading '!' leaves a leading space, and compile(..., 'eval') rejects that
    # as an unexpected indent.
    return e.strip()


class SkipSet(object):
    """Skips split by which vars they touch, so the static-only ones can be
    evaluated once per static combo instead of once per (static, dynamic) pair."""

    def __init__(self, c):
        static_names = set(n for (n, lo, hi) in c.statics)
        dynamic_names = set(n for (n, lo, hi) in c.dynamics)
        self.static_only = []
        self.mixed = []
        self.undefined = set()
        declared = static_names | dynamic_names
        for expr in c.skips:
            py = translate_skip(expr, declared)
            names = set(re.findall(r'\b([A-Za-z_]\w*)\b', py))
            names -= {'and', 'or', 'not', 'True', 'False'}
            unknown = names - static_names - dynamic_names
            # A skip may reference a var that tag-filtering removed for this target
            # (e.g. PIXELFOGTYPE is [ps20]-only but a SKIP still names it when we
            # build ps20b). fxc_prep.pl concatenates every SKIP into
            # "(s1)||(s2)||...||0" regardless, and in perl an undefined var is just
            # false -- shadercompile is handed that same string, so undefined-is-zero
            # is the semantics Valve actually shipped against. Bind them to 0.
            self.undefined |= unknown
            code = compile(py, '<skip>', 'eval')
            if names & dynamic_names:
                self.mixed.append(code)
            else:
                self.static_only.append(code)
        self.zeros = dict((n, 0) for n in self.undefined)


def iter_combos(vars_):
    """Yield dicts of name->value over the full cartesian product, in .inc order."""
    ranges = [range(lo, hi + 1) for (n, lo, hi) in vars_]
    names = [n for (n, lo, hi) in vars_]
    import itertools
    for values in itertools.product(*reversed(ranges)):
        yield dict(zip(reversed(names), values))


def combo_index(vars_, mults, values):
    idx = 0
    for ((name, lo, hi), m) in zip(vars_, mults):
        idx += m * values[name]
    return idx


def enumerate_live(c, verbose=False):
    """Return (live_static, num_dynamic, total_invocations).
    live_static: list of (static_combo_id, [live dynamic ids])"""
    dyn_mult, num_dyn, stat_mult, total = compute_multipliers(c)
    skips = SkipSet(c)

    # Precompute the dynamic combos, keyed by their own values, so the mixed skips
    # can be re-evaluated cheaply per static combo.
    dyn_list = list(iter_combos(c.dynamics))
    for d in dyn_list:
        d['__id'] = combo_index(c.dynamics, dyn_mult, d)

    live = []
    n_inv = 0
    for sv in iter_combos(c.statics):
        env = dict(skips.zeros)
        env.update(sv)
        dead = False
        for code in skips.static_only:
            if eval(code, {}, env):
                dead = True
                break
        if dead:
            continue
        sid = combo_index(c.statics, stat_mult, sv) // num_dyn
        live_dyn = []
        for d in dyn_list:
            env2 = dict(skips.zeros)
            env2.update(sv)
            env2.update(d)
            skip = False
            for code in skips.mixed:
                if eval(code, {}, env2):
                    skip = True
                    break
            if not skip:
                live_dyn.append(d['__id'])
        if live_dyn:
            live.append((sid, live_dyn))
            n_inv += len(live_dyn)
    return live, num_dyn, n_inv


# ---------------------------------------------------------------------------
# fxc driver + .vcs writer
# ---------------------------------------------------------------------------

MAX_SHADER_UNPACKED_BLOCK_SIZE = 1 << 17     # shader_vcs_version.h
BLOCK_UNCOMPRESSED = 0x80000000              # vertexshaderdx8.cpp CreateDynamicCombos_Ver5


def shader_type_for(basename):
    b = basename.lower()
    if 'ps30' in b:
        return 'ps_3_0'
    if 'ps20b' in b:
        return 'ps_2_b'
    if 'ps20' in b:
        return 'ps_2_0'
    if 'ps11' in b:
        return 'ps_1_1'
    if 'vs30' in b:
        return 'vs_3_0'
    if 'vs20' in b:
        return 'vs_2_0'
    if 'vs11' in b:
        return 'vs_1_1'
    raise ValueError("cannot infer shader type from %s" % basename)


_obj_seq = None


def run_fxc(fxc_exe, src, stype, defines, workdir):
    import subprocess
    import threading
    # The object file name MUST be unique per invocation. An earlier version keyed it
    # on (static*1000+dynamic)%100000, which collides (sid=77,did=0 and sid=177,did=0
    # both give s77000.o) -- concurrent workers then clobber each other's output, and
    # the benign outcome is the crash we saw. The malignant one is a worker reading
    # another's .o and silently packing the wrong bytecode into the .vcs.
    obj = os.path.join(workdir, "s%d_%d.o" % (threading.get_ident(), next(_obj_seq)))
    args = [fxc_exe, '/nologo', '/T' + stype, '/Dmain=main', '/Emain']
    for (k, v) in defines:
        args.append('/D%s=%s' % (k, v))
    args.append('/Fo' + obj)
    args.append(src)
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if p.returncode != 0 or not os.path.exists(obj):
        return None, p.stdout.decode('utf-8', 'replace')
    with open(obj, 'rb') as f:
        data = f.read()
    os.unlink(obj)
    return data, None


BLOCK_LZMA = 0x40000000
LZMA_ID = (ord('A') << 24) | (ord('M') << 16) | (ord('Z') << 8) | ord('L')   # 'LZMA'


def lzma_pack(payload):
    """Valve's lzma_header_t (tier1/lzmaDecoder.h) followed by props + a raw LZMA1
    stream -- exactly the bytes CLZMA::Uncompress hands to LzmaDecode, which takes
    `properties` (LZMA_PROPS_SIZE=5) and the stream separately and decodes a known
    actualSize. So emit FORMAT_RAW and build the 5 property bytes ourselves:
    one packed (lc/lp/pb) byte then dict_size LE, which is the SDK's layout."""
    import lzma
    lc, lp, pb, dict_size = 3, 0, 2, 1 << 20
    filters = [{"id": lzma.FILTER_LZMA1, "dict_size": dict_size,
                "lc": lc, "lp": lp, "pb": pb}]
    stream = lzma.compress(payload, format=lzma.FORMAT_RAW, filters=filters)
    props = bytes([(pb * 5 + lp) * 9 + lc]) + struct.pack('<I', dict_size)
    return struct.pack('<III', LZMA_ID, len(payload), len(stream)) + props + stream


def build_payload(entries):
    """entries: [(dynamic_combo_id, bytecode)] -> the raw unpacked block payload,
    a run of [uint32 comboID][uint32 size][bytecode]."""
    out = bytearray()
    for (did, code) in entries:
        out.extend(struct.pack('<II', did, len(code)))
        out.extend(code)
    return bytes(out)


def pack_blocks(payload, compress=True):
    """Split a payload into blocks the loader can consume and terminate the chain.
    Every block must decompress to <= MAX_SHADER_UNPACKED_BLOCK_SIZE, so we split on
    the *unpacked* size regardless of compression."""
    out = bytearray()
    pos = 0
    # Split on record boundaries, not arbitrary bytes: each block must contain whole
    # [id][size][code] records or the reader's inner loop desyncs.
    bounds = []
    p = 0
    start = 0
    cur = 0
    while p < len(payload):
        sz = struct.unpack_from('<I', payload, p + 4)[0]
        rec = 8 + sz
        if cur and cur + rec > MAX_SHADER_UNPACKED_BLOCK_SIZE:
            bounds.append((start, p))
            start = p
            cur = 0
        cur += rec
        p += rec
    if start < len(payload):
        bounds.append((start, len(payload)))

    for (a, b) in bounds:
        chunk = payload[a:b]
        if compress:
            packed = lzma_pack(chunk)
            # Only take the compressed form if it actually helps.
            if len(packed) < len(chunk):
                out.extend(struct.pack('<I', BLOCK_LZMA | len(packed)))
                out.extend(packed)
                continue
        out.extend(struct.pack('<I', BLOCK_UNCOMPRESSED | len(chunk)))
        out.extend(chunk)
    out.extend(struct.pack('<I', 0xffffffff))
    return bytes(out)


def write_vcs(path, num_dyn, total_combos, centroid_mask, static_payloads, compress=True):
    """static_payloads: list of (static_combo_id, raw_payload_bytes), any order.

    Static combos whose bytecode is byte-identical share one data block: the
    canonical one gets a StaticComboRecord_t, the rest get StaticComboAliasRecord_t
    redirects. That's what version 6 is for ("v5 + duplicate static combo records"),
    and it is safe precisely because a v6 block keys its entries by DYNAMIC combo id
    only -- nothing in the block depends on which static combo it came from.
    FindCombo() searches the alias table first and rewrites the id before looking it
    up in the main dictionary, and both searches are binary, so both tables must be
    sorted by static combo id.
    """
    canon = {}          # payload -> canonical sid
    aliases = []        # (sid, source_sid)
    unique = []         # (sid, payload)
    for (sid, payload) in sorted(static_payloads, key=lambda x: x[0]):
        prev = canon.get(payload)
        if prev is None:
            canon[payload] = sid
            unique.append((sid, payload))
        else:
            aliases.append((sid, prev))
    aliases.sort(key=lambda x: x[0])

    blocks = [(sid, pack_blocks(payload, compress)) for (sid, payload) in unique]

    n_records = len(blocks) + 1                  # + sentinel; the header counts it
    data_start = 28 + n_records * 8 + 4 + len(aliases) * 8

    records = []
    off = data_start
    for (sid, blob) in blocks:
        records.append((sid, off))
        off += len(blob)
    file_size = off
    records.append((0xffffffff, file_size))      # sentinel points at EOF

    with open(path, 'wb') as f:
        # m_nSourceCRC32 is read into the header but never validated by the engine.
        f.write(struct.pack('<iiiIIII', 6, total_combos & 0xffffffff, num_dyn,
                            0, centroid_mask, n_records, 0))
        for (sid, o) in records:
            f.write(struct.pack('<II', sid, o))
        f.write(struct.pack('<I', len(aliases)))
        for (sid, src) in aliases:
            f.write(struct.pack('<II', sid, src))
        for (sid, blob) in blocks:
            f.write(blob)
    return file_size, len(unique), len(aliases)


def cmd_compile(args):
    import time
    import tempfile
    import shutil
    from concurrent.futures import ThreadPoolExecutor

    fxc_exe = os.path.abspath(args.fxc)
    src = os.path.join(STDSHADERS, args.src)
    if not os.path.exists(fxc_exe):
        print("fxc.exe not found: %s" % fxc_exe)
        return 1

    c = parse_fxc(src, args.target)
    dyn_mult, num_dyn, stat_mult, total = compute_multipliers(c)
    stype = shader_type_for(args.target)

    print("compiling %s (%s) from %s" % (args.target, stype, args.src))
    t0 = time.time()
    live, num_dyn, n_inv = enumerate_live(c)
    print("  live static combos=%d  fxc invocations=%d  (enumerated in %.1fs)"
          % (len(live), n_inv, time.time() - t0))
    if args.limit:
        live = live[:args.limit]
        n_inv = sum(len(d) for (s, d) in live)
        print("  --limit: restricted to %d static combos (%d invocations)" % (len(live), n_inv))

    # Reverse the index math so a combo id can be turned back into /D defines.
    def defines_for(sid, did):
        out = []
        rem = did
        for ((name, lo, hi), m) in zip(c.dynamics, dyn_mult):
            n = hi - lo + 1
            out.append((name, (rem // m) % n + lo))
        rem = sid * num_dyn
        for ((name, lo, hi), m) in zip(c.statics, stat_mult):
            n = hi - lo + 1
            out.append((name, (rem // m) % n + lo))
        return out

    common = [('TOTALSHADERCOMBOS', total), ('CENTROIDMASK', c.centroid_mask),
              ('NUMDYNAMICCOMBOS', num_dyn), ('FLAGS', '0x0'),
              ('SHADER_MODEL_' + stype.upper(), 1)]

    global _obj_seq
    import itertools
    _obj_seq = itertools.count()   # next() is atomic under the GIL

    workroot = tempfile.mkdtemp(prefix='vcs_')
    errors = []
    counter = [0]
    t0 = time.time()

    def do_static(item):
        (sid, dyn_ids) = item
        entries = []
        for did in dyn_ids:
            defs = common + defines_for(sid, did)
            code, err = run_fxc(fxc_exe, src, stype, defs, workroot)
            counter[0] += 1
            if code is None:
                if len(errors) < 5:
                    errors.append((sid, did, err))
                continue
            entries.append((did, code))
        if not entries:
            return None
        return (sid, build_payload(entries))

    results = []
    try:
        with ThreadPoolExecutor(max_workers=args.jobs) as ex:
            for i, r in enumerate(ex.map(do_static, live)):
                if r:
                    results.append(r)
                if (i % 200) == 0 and i:
                    el = time.time() - t0
                    rate = counter[0] / max(el, 0.001)
                    print("    %d/%d static combos, %d fxc calls, %.0f/s, %.0fs elapsed"
                          % (i, len(live), counter[0], rate, el))
    finally:
        shutil.rmtree(workroot, ignore_errors=True)

    if errors:
        print("  %d compile errors; first:" % len(errors))
        for (sid, did, err) in errors[:3]:
            print("    static=%d dynamic=%d:\n%s" % (sid, did, (err or '')[:400]))
        return 1

    outdir = os.path.join(args.out, 'shaders', 'fxc')
    os.makedirs(outdir, exist_ok=True)
    outfile = os.path.join(outdir, args.target + '.vcs')
    size, nuniq, nalias = write_vcs(outfile, num_dyn, total, c.centroid_mask,
                                    results, compress=not args.no_compress)
    print("  wrote %s (%d bytes) in %.0fs" % (outfile, size, time.time() - t0))
    print("  %d static combos -> %d unique blocks + %d aliases, dyn=%d"
          % (len(results), nuniq, nalias, num_dyn))
    return 0


def lzma_unpack_check(data, p):
    """Decode a Valve lzma_header_t block the way CLZMA::Uncompress does, so verify
    actually proves the device can read what we wrote."""
    import lzma
    try:
        ident, actual, lzsize = struct.unpack_from('<III', data, p)
        if ident != LZMA_ID:
            return None
        props = data[p + 12:p + 17]
        stream = data[p + 17:p + 17 + lzsize]
        b = props[0]
        lc = b % 9
        b //= 9
        lp = b % 5
        pb = b // 5
        dict_size = struct.unpack('<I', props[1:5])[0]
        filters = [{"id": lzma.FILTER_LZMA1, "dict_size": dict_size,
                    "lc": lc, "lp": lp, "pb": pb}]
        out = lzma.LZMADecompressor(format=lzma.FORMAT_RAW,
                                    filters=filters).decompress(stream)
        if len(out) != actual:
            return None
        return out
    except Exception:
        return None


def cmd_verify(args):
    """Re-read a .vcs the way CShaderManager does and assert its invariants.
    Catches a truncated/mis-keyed pack before it ever reaches the device."""
    path = args.path
    data = open(path, 'rb').read()
    if len(data) < 28:
        print("FAIL: shorter than a header")
        return 1
    ver, total, dyn, flags, centroid, nstatic, crc = struct.unpack_from('<iiiIIII', data, 0)
    print("%s: ver=%d dyn=%d nstatic=%d centroid=0x%x (%d bytes)"
          % (os.path.basename(path), ver, dyn, nstatic, centroid, len(data)))
    problems = []
    if ver != 6:
        problems.append("version %d != 6" % ver)

    off = 28
    recs = []
    for i in range(nstatic):
        recs.append(struct.unpack_from('<II', data, off))
        off += 8
    ndup = struct.unpack_from('<I', data, off)[0]
    off += 4
    dups = []
    for i in range(ndup):
        dups.append(struct.unpack_from('<II', data, off))
        off += 8

    # FindCombo() binary-searches the alias table BEFORE the main dictionary, so the
    # alias table must be ascending, must not repeat, must not shadow a real record,
    # and every source must actually exist -- otherwise a combo silently resolves to
    # the wrong shader (or none), which is the failure mode we're fixing.
    rec_ids = set(r[0] for r in recs[:-1])
    alias_ids = [d[0] for d in dups]
    if alias_ids != sorted(alias_ids):
        problems.append("alias table is not ascending (binary search would fail)")
    if len(set(alias_ids)) != len(alias_ids):
        problems.append("duplicate alias ids")
    for (aid, src) in dups:
        if src not in rec_ids:
            problems.append("alias %d -> %d, but %d has no record" % (aid, src, src))
            break
        if aid in rec_ids:
            problems.append("alias %d also has its own record (ambiguous)" % aid)
            break

    if recs[-1][0] != 0xffffffff:
        problems.append("last record id 0x%x is not the 0xffffffff sentinel" % recs[-1][0])
    if recs[-1][1] != len(data):
        problems.append("sentinel offset %d != file size %d" % (recs[-1][1], len(data)))
    if recs[0][1] != off:
        problems.append("first record offset %d != end of dictionary %d" % (recs[0][1], off))
    ids = [r[0] for r in recs[:-1]]
    if ids != sorted(ids):
        problems.append("static combo ids are not ascending (binary search would fail)")
    if len(set(ids)) != len(ids):
        problems.append("duplicate static combo ids")

    ncombo = 0
    nblocks = 0
    for i in range(len(recs) - 1):
        p = recs[i][1]
        end = recs[i + 1][1]
        seen = set()
        while p < end:
            bs = struct.unpack_from('<I', data, p)[0]
            p += 4
            if bs == 0xffffffff:
                break
            kind = bs & 0xc0000000
            size = bs & 0x3fffffff
            if kind == BLOCK_UNCOMPRESSED:
                blk = data[p:p + size]
            elif kind == BLOCK_LZMA:
                blk = lzma_unpack_check(data, p)
                if blk is None:
                    problems.append("combo %d: lzma block failed to decompress" % recs[i][0])
                    break
            else:
                problems.append("combo %d: block kind 0x%x unsupported by loader" % (recs[i][0], kind))
                break
            if len(blk) > MAX_SHADER_UNPACKED_BLOCK_SIZE:
                problems.append("combo %d: unpacked block %d exceeds max size" % (recs[i][0], len(blk)))
            q = 0
            while q < len(blk):
                cid = struct.unpack_from('<I', blk, q)[0]
                q += 4
                sz = struct.unpack_from('<I', blk, q)[0]
                q += 4
                code = blk[q:q + sz]
                q += sz
                if sz < 4 or len(code) != sz:
                    problems.append("combo %d/%d: truncated bytecode" % (recs[i][0], cid))
                    continue
                tok = struct.unpack_from('<I', code, 0)[0]
                # ps_* shaders start 0xffff.., vs_* start 0xfffe..
                if (tok >> 16) not in (0xffff, 0xfffe):
                    problems.append("combo %d/%d: bad shader token 0x%08x" % (recs[i][0], cid, tok))
                if cid >= dyn:
                    problems.append("combo %d: dynamic id %d >= dyn count %d" % (recs[i][0], cid, dyn))
                if cid in seen:
                    problems.append("combo %d: duplicate dynamic id %d" % (recs[i][0], cid))
                seen.add(cid)
                ncombo += 1
            p += size
            nblocks += 1

    print("  walked %d unique static combos + %d aliases = %d total, %d blocks, %d dynamic combos"
          % (len(recs) - 1, ndup, len(recs) - 1 + ndup, nblocks, ncombo))
    if problems:
        print("  FAIL (%d problems):" % len(problems))
        for p_ in problems[:10]:
            print("    %s" % p_)
        return 1
    print("  OK: dictionary, sentinel, block chain and bytecode tokens all consistent")
    return 0


def cmd_count(args):
    import time
    fxc = os.path.join(STDSHADERS, args.src)
    c = parse_fxc(fxc, args.target)
    dyn_mult, num_dyn, stat_mult, total = compute_multipliers(c)
    t0 = time.time()
    live, num_dyn, n_inv = enumerate_live(c)
    dt = time.time() - t0
    print("%s" % args.target)
    print("  static space      : %d" % (total // num_dyn))
    print("  dynamic combos    : %d" % num_dyn)
    print("  raw total combos  : %d" % total)
    print("  LIVE static combos: %d   (%.4f%% survive SKIPs)"
          % (len(live), 100.0 * len(live) / max(1, total // num_dyn)))
    print("  fxc invocations   : %d" % n_inv)
    print("  enumerated in %.1fs" % dt)
    return 0


def cmd_info(args):
    base = args.target
    src = args.src
    fxc = os.path.join(STDSHADERS, src)
    c = parse_fxc(fxc, base)
    dyn_mult, num_dyn, stat_mult, total = compute_multipliers(c)
    print("%s (from %s)" % (base, src))
    print("  dynamic combos: %d" % num_dyn)
    print("  static space  : %d  (total combos %d)" % (total // num_dyn, total))
    print("  centroid mask : 0x%x" % c.centroid_mask)
    print("  skips         : %d" % len(c.skips))
    for s in c.skips:
        print("      %s" % s)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("validate-inc")
    p.set_defaults(func=cmd_validate_inc)
    p = sub.add_parser("info")
    p.add_argument("src")
    p.add_argument("target")
    p.set_defaults(func=cmd_info)
    p = sub.add_parser("count")
    p.add_argument("src")
    p.add_argument("target")
    p.set_defaults(func=cmd_count)
    p = sub.add_parser("verify")
    p.add_argument("path")
    p.set_defaults(func=cmd_verify)
    p = sub.add_parser("compile")
    p.add_argument("src")
    p.add_argument("target")
    p.add_argument("--fxc", default=os.path.join(STDSHADERS, "..", "..", "dx9sdk",
                                                 "utilities", "fxc.exe"))
    p.add_argument("--out", default="shaderout")
    p.add_argument("--jobs", type=int, default=8)
    p.add_argument("--limit", type=int, default=0,
                   help="only compile the first N static combos (smoke test)")
    p.add_argument("--no-compress", action="store_true",
                   help="write uncompressed blocks (much larger; for debugging)")
    p.set_defaults(func=cmd_compile)
    args = ap.parse_args()
    if not getattr(args, "func", None):
        ap.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
