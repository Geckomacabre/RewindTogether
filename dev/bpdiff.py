"""After a Retro Rewind update: what changed in the game's Blueprints, and which of
the names the mod calls or reads are gone or have a new signature.

Dump the same classes from the new pak first (bpdump, in the decomp folder - see
PROJECT.md "After a game update"), then:

    py -I dev/bpdiff.py OLD_BP_DIR NEW_BP_DIR Mods/RewindTogether/Scripts native/RewindNative/RewindNative.cpp report.txt

It prints, per changed class, the properties and functions removed, added or
re-typed, then every string in the mod (Lua and the native helper) that names a
removed member or a function whose parameters changed. Body-only changes show as
a bare "== Class" line: read those classes' new pseudo-code by hand.
"""
import os, re, sys, glob, hashlib, collections

old_dir, new_dir, mod_dir, native_cpp, out_path = sys.argv[1:6]

FUNC_RE = re.compile(r'^function (\S+?)::(.+?)\((.*)\)\s{3}\[(.*)\]\s*$')
PROP_RE = re.compile(r'^    (\S+(?:<[^>]*>)?(?:<[^>]*>>)?)\s+(.+?)(?:\s{2}\[(.*)\])?\s*$')


def parse(path):
    cls = None
    props = {}
    funcs = {}
    in_props = False
    body = []
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.rstrip('\n')
            if line.startswith('class ') and cls is None:
                cls = line.split()[1]
                continue
            if line == '  properties:':
                in_props = True
                continue
            if in_props:
                if line.startswith('    ') and not line.startswith('     '):
                    m = PROP_RE.match(line)
                    if m:
                        typ, name = m.group(1), m.group(2)
                        props[name] = typ
                    continue
                else:
                    in_props = False
            m = FUNC_RE.match(line)
            if m:
                funcs[m.group(2)] = m.group(3)
            # bytecode body without offsets (so a shifted offset is not a change)
            body.append(re.sub(r'\b[LR]?\d+\b', '#', line))
    h = hashlib.sha1('\n'.join(body).encode()).hexdigest()
    return cls, props, funcs, h


def load(d):
    out = {}
    for p in glob.glob(os.path.join(d, '*.txt')):
        n = os.path.basename(p)
        if n.startswith('_'):
            continue
        n = n.replace('UI_SaveSlot__Save.txt', 'UI_SaveSlot.txt')
        out[n] = parse(p)
    return out


old = load(old_dir)
new = load(new_dir)

lines = []
P = lines.append
changed_assets = []
all_removed_names = collections.defaultdict(list)   # name -> [where]
sig_changed = collections.defaultdict(list)
for n in sorted(set(old) | set(new)):
    if n not in new:
        P(f'ASSET GONE: {n}')
        continue
    if n not in old:
        P(f'ASSET NEW: {n}')
        continue
    oc, op, of, oh = old[n]
    nc, np_, nf, nh = new[n]
    if oh == nh:
        continue
    changed_assets.append(n)
    rem_p = sorted(set(op) - set(np_))
    add_p = sorted(set(np_) - set(op))
    typ_p = sorted(k for k in set(op) & set(np_) if op[k] != np_[k])
    rem_f = sorted(set(of) - set(nf))
    add_f = sorted(set(nf) - set(of))
    sig_f = sorted(k for k in set(of) & set(nf) if of[k] != nf[k])
    P(f'== {n} ({oc})')
    for k in rem_p:
        P(f'   - prop  {op[k]} {k}')
        all_removed_names[k].append(f'{oc} prop')
    for k in add_p:
        P(f'   + prop  {np_[k]} {k}')
    for k in typ_p:
        P(f'   ~ prop  {k}: {op[k]} -> {np_[k]}')
        sig_changed[k].append(f'{oc} prop type')
    for k in rem_f:
        P(f'   - func  {k}({of[k]})')
        all_removed_names[k].append(f'{oc} func')
    for k in add_f:
        P(f'   + func  {k}({nf[k]})')
    for k in sig_f:
        P(f'   ~ func  {k}\n        old({of[k]})\n        new({nf[k]})')
        sig_changed[k].append(f'{oc} func sig')

P('')
P(f'{len(changed_assets)} of {len(old)} assets changed')

# ---- names the mod uses ----
strings = collections.defaultdict(set)
str_re = re.compile(r'"((?:[^"\\]|\\.)*)"|\'((?:[^\'\\]|\\.)*)\'')
for p in glob.glob(os.path.join(mod_dir, '*.lua')) + [native_cpp]:
    with open(p, encoding='utf-8', errors='replace') as f:
        for i, line in enumerate(f, 1):
            s = line.strip()
            if s.startswith('--') or s.startswith('//'):
                continue
            for m in str_re.finditer(line):
                v = m.group(1) if m.group(1) is not None else m.group(2)
                if v:
                    strings[v].add(f'{os.path.basename(p)}:{i}')
                    # names inside paths like Class:Function or "/Script/..:Func"
                    for part in re.split(r'[:.]', v):
                        if part and part != v:
                            strings[part].add(f'{os.path.basename(p)}:{i}')

P('')
P('==== NAMES THE MOD USES THAT DISAPPEARED OR CHANGED ====')
hits = 0
# names present in old dump anywhere
old_names = collections.defaultdict(set)
new_names = collections.defaultdict(set)
for n, (c, pr, fu, h) in old.items():
    for k in list(pr) + list(fu):
        old_names[k].add(c)
for n, (c, pr, fu, h) in new.items():
    for k in list(pr) + list(fu):
        new_names[k].add(c)
for v, where in sorted(strings.items()):
    if v in old_names:
        gone_from = old_names[v] - new_names.get(v, set())
        if gone_from:
            hits += 1
            P(f'GONE  "{v}" from {sorted(gone_from)}  used at {sorted(where)[:6]}')
    if v in sig_changed:
        hits += 1
        P(f'SIG   "{v}" {sig_changed[v]}  used at {sorted(where)[:6]}')
P(f'{hits} hit(s)')

with open(out_path, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
print('\n'.join(lines[-80:]))
