#!/usr/bin/env python3
"""channels.py: the tree logic of the stable and the testing channel.

The site has two trees. Stable is v3.24/<category>/<arch>/. Testing is
testing/v3.24/<category>/<arch>/. Testing is complete: it holds all of stable
and, for each package, the testing build when that build is newer than the
newest stable version. This script works on plain directories of the form
<root>/<category>/<arch>/<name>-<ver>-r<rel>.apk. It reads no apk and no
index. scripts/index.sh builds and signs the indexes afterwards.

  scripts/channels.py assemble --stable DIR --testing DIR --out DIR
      Fill OUT (a new or empty directory) with every apk of the stable tree
      (the same bytes) and every apk of the testing tree whose version is
      newer than the newest stable version of the same package in the same
      category and architecture, or whose package stable does not have at
      all. A testing apk with the same or an older version than stable is
      dropped. A directory that does not exist counts as empty.

  scripts/channels.py promote --stable DIR --testing DIR --packages LIST
                              [--log FILE] [--run ID]
      Copy apks from the testing tree into the stable tree (the same bytes).
      LIST has words that a space, a comma or a line end separates. A word is
      "all" (every testing apk that is newer than stable), a package name
      (the newest testing apk of that name, in every architecture that has
      it), or the name of one apk (with or without .apk). A promote takes whole
      builds: with an apk it also takes every apk of the same origin and
      version (the subpackages, for example tsx-xx60-board-ha with
      tsx-xx60-board), and every apk that it pins with an exact depend
      (name=version) when stable lacks that version. The origin and the depends
      come from the APKINDEX.tar.gz of the testing tree. The command fails
      without that index, and when an exact depend is nowhere. The command
      checks every word first. It changes nothing and fails if a word names
      nothing that can be promoted. Each copied apk adds a line to FILE:
      "<UTC time> <run id> <category>/<arch>/<apk> <sha256>".

  scripts/channels.py same DIR DIR
      Exit 0 if both trees hold the same files with the same bytes.

  scripts/channels.py compare VERSION VERSION
      Print -1, 0 or 1 (apk version order).

  scripts/channels.py sort
      Read apk file names (name-ver-rN.apk, or without .apk) from the standard
      input, one for each line, and print them with the oldest version first
      (apk order). scripts/index.sh uses it to prune.
"""
import argparse
import datetime
import hashlib
import io
import os
import re
import shutil
import sys
import tarfile
import zlib

APK_RE = re.compile(r'^(?P<name>.+)-(?P<ver>[0-9][^-]*-r[0-9]+)\.apk$')

# apk version suffixes: a pre-release sorts before the plain version, a
# post-release after it.
_SUFFIX = {'alpha': -4, 'beta': -3, 'pre': -2, 'rc': -1,
           'cvs': 1, 'svn': 2, 'git': 3, 'hg': 4, 'p': 5}
_VER_RE = re.compile(r'^(?P<num>[0-9]+(?:\.[0-9]+)*)(?P<letter>[a-z])?'
                     r'(?P<suf>(?:_(?:alpha|beta|pre|rc|cvs|svn|git|hg|p)[0-9]*)*)'
                     r'(?:~[0-9a-f]+)?(?:-r(?P<rel>[0-9]+))?$')


def _parse(v):
    m = _VER_RE.match(v)
    if not m:
        raise ValueError(f'not an apk version: {v!r}')
    suf = [(_SUFFIX[s], int(n or 0)) for s, n in re.findall(r'_([a-z]+)([0-9]*)', m['suf'])]
    return m['num'].split('.'), m['letter'] or '', suf, int(m['rel'] or 0)


def _cmp(a, b):
    return (a > b) - (a < b)


def version_cmp(x, y):
    """Compare two apk versions (the order of apk-tools): -1, 0 or 1."""
    nx, lx, sx, rx = _parse(x)
    ny, ly, sy, ry = _parse(y)
    for i in range(max(len(nx), len(ny))):
        if i >= len(nx):
            return -1
        if i >= len(ny):
            return 1
        a, b = nx[i], ny[i]
        # A part after the first with a leading zero is a fraction (1.01 < 1.1).
        if i > 0 and (a.startswith('0') or b.startswith('0')):
            c = _cmp(a.rstrip('0'), b.rstrip('0'))
        else:
            c = _cmp(int(a), int(b))
        if c:
            return c
    if lx != ly:
        return _cmp(lx, ly)
    for i in range(max(len(sx), len(sy))):
        a = sx[i] if i < len(sx) else (0, 0)
        b = sy[i] if i < len(sy) else (0, 0)
        if a != b:
            return _cmp(a, b)
    return _cmp(rx, ry)


def scan(root):
    """{(category, arch, name): {version: filename}} for the apks under root."""
    out = {}
    if not root or not os.path.isdir(root):
        return out
    for cat in sorted(os.listdir(root)):
        for arch in sorted(os.listdir(os.path.join(root, cat))) if os.path.isdir(os.path.join(root, cat)) else []:
            d = os.path.join(root, cat, arch)
            if not os.path.isdir(d):
                continue
            for fn in sorted(os.listdir(d)):
                m = APK_RE.match(fn)
                if m:
                    out.setdefault((cat, arch, m['name']), {})[m['ver']] = fn
    return out


def newest(versions):
    best = None
    for v in versions:
        if best is None or version_cmp(v, best) > 0:
            best = v
    return best


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for blk in iter(lambda: f.read(1 << 20), b''):
            h.update(blk)
    return h.hexdigest()


def place(src, dst):
    """Copy a file with the same bytes. A hard link is fine: nothing writes to an apk."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copyfile(src, dst)


def newer_testing(stable, testing):
    """[(key, version)] of the testing apks that are newer than stable."""
    out = []
    for key, vers in sorted(testing.items()):
        sn = newest(stable.get(key, {}))
        for v in sorted(vers):
            if sn is None or version_cmp(v, sn) > 0:
                out.append((key, v))
    return out


def cmd_assemble(a):
    if os.path.isdir(a.out) and os.listdir(a.out):
        sys.exit(f'assemble: {a.out} is not empty')
    os.makedirs(a.out, exist_ok=True)
    stable, testing = scan(a.stable), scan(a.testing)
    n_s = n_t = n_d = 0
    for (cat, arch, name), vers in sorted(stable.items()):
        for v, fn in vers.items():
            place(os.path.join(a.stable, cat, arch, fn), os.path.join(a.out, cat, arch, fn))
            n_s += 1
    for key, v in newer_testing(stable, testing):
        cat, arch, name = key
        fn = testing[key][v]
        place(os.path.join(a.testing, cat, arch, fn), os.path.join(a.out, cat, arch, fn))
        sn = newest(stable.get(key, {}))
        print(f'assemble: testing {cat}/{arch}/{fn} ({"new package" if sn is None else "newer than stable " + sn})')
        n_t += 1
    for key, vers in sorted(testing.items()):
        sn = newest(stable.get(key, {}))
        for v, fn in sorted(vers.items()):
            if sn is not None and version_cmp(v, sn) <= 0:
                print(f'assemble: dropped {key[0]}/{key[1]}/{fn} (stable has {sn})')
                n_d += 1
    print(f'assemble: {n_s} from stable, {n_t} testing-only, {n_d} dropped')


def read_index(path):
    """[{field: value}] of an APKINDEX.tar.gz (signature member first); [] if absent."""
    if not os.path.isfile(path):
        return None
    buf = open(path, 'rb').read()
    members = []
    while buf:
        d = zlib.decompressobj(31)
        data = d.decompress(buf)
        members.append(data)
        buf = d.unused_data
    tf = tarfile.open(fileobj=io.BytesIO(members[-1]))
    text = tf.extractfile('APKINDEX').read().decode()
    out = []
    for stanza in text.strip().split('\n\n'):
        f = dict(l.split(':', 1) for l in stanza.splitlines() if ':' in l)
        if 'P' in f:
            out.append(f)
    return out


def closure(pick, testing, stable, root):
    """Add the apks of the same origin and version, and the exact pins, to pick."""
    idx = {}
    for (cat, arch) in {(k[0], k[1]) for k, _ in pick} | {(k[0], k[1]) for k in testing}:
        ent = read_index(os.path.join(root, cat, arch, 'APKINDEX.tar.gz'))
        if ent is not None:
            idx[(cat, arch)] = ent
    stable_have = {(k[2], v) for k, vs in stable.items() for v in vs}
    result = list(pick)
    seen = set(result)
    work = list(pick)
    while work:
        (cat, arch, name), v = work.pop()
        ent = idx.get((cat, arch))
        if ent is None:
            sys.exit(f'promote: no APKINDEX.tar.gz for {cat}/{arch} in the testing tree: the origin and the depends of {name} are unknown')
        me = [f for f in ent if f['P'] == name and f['V'] == v]
        if not me:
            sys.exit(f'promote: {name}-{v} is not in the index of testing/{cat}/{arch}')
        me = me[0]
        origin = me.get('o', name)
        related = [(( cat, arch, f['P']), f['V']) for f in ent if f.get('o', f['P']) == origin and f['V'] == v]
        for dep in me.get('D', '').split():
            if '=' not in dep or dep.startswith(('!', 'so:', 'cmd:', 'pc:')) or any(c in dep for c in '<>~'):
                continue
            dn, dv = dep.split('=', 1)
            if (dn, dv) in stable_have:
                continue
            # the same version in some category of the testing tree
            hit = [((c, ar, f['P']), f['V']) for (c, ar), e in idx.items() if ar == arch for f in e if f['P'] == dn and f['V'] == dv]
            if not hit:
                sys.exit(f'promote: {name}-{v} depends on {dn}={dv}, which is in neither stable nor testing')
            related += hit
        for r in related:
            key, rv = r
            if rv not in testing.get(key, {}):
                sys.exit(f'promote: {key[2]}-{rv} is in the index but its file is not in the testing tree')
            if r not in seen:
                seen.add(r)
                result.append(r)
                work.append(r)
    return result


def cmd_promote(a):
    stable, testing = scan(a.stable), scan(a.testing)
    cand = newer_testing(stable, testing)   # what can be promoted
    words = [w for w in re.split(r'[\s,]+', a.packages.strip()) if w]
    if not words:
        sys.exit('promote: the package list is empty')
    pick = []   # [(key, version)]
    for w in words:
        if w == 'all':
            hits = list(cand)
        else:
            base = w[:-4] if w.endswith('.apk') else w
            by_name = [(k, v) for (k, v) in cand if k[2] == base]
            by_file = [(k, v) for (k, v) in cand if f'{k[2]}-{v}' == base]
            if by_name:   # the newest candidate in each category and architecture
                best = {}
                for k, v in by_name:
                    if k not in best or version_cmp(v, best[k]) > 0:
                        best[k] = v
                hits = sorted(best.items())
            else:
                hits = by_file
        if not hits:
            known = any(k[2] == w or f'{k[2]}-{v}' == w.removesuffix('.apk') for k, vs in testing.items() for v in vs)
            sys.exit(f'promote: nothing to promote for "{w}"'
                     + (': stable has the same or a newer version' if known else ': testing has no such package'))
        for h in hits:
            if h not in pick:
                pick.append(h)
    chosen = list(pick)
    pick = closure(pick, testing, stable, a.testing)
    pick = [h for h in pick if h[1] not in stable.get(h[0], {})]
    for (cat, arch, name), v in pick:
        if ((cat, arch, name), v) not in chosen:
            print(f'promote: also {cat}/{arch}/{name}-{v} (same build: origin or exact depend)')
    when = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    lines = []
    for (cat, arch, name), v in pick:
        fn = testing[(cat, arch, name)][v]
        src = os.path.join(a.testing, cat, arch, fn)
        dst = os.path.join(a.stable, cat, arch, fn)
        if os.path.exists(dst):
            sys.exit(f'promote: {cat}/{arch}/{fn} is already in stable')
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        h = sha256(dst)
        if h != sha256(src):
            sys.exit(f'promote: {fn} differs after the copy')
        lines.append(f'{when} {a.run or "-"} {cat}/{arch}/{fn} {h}')
        print(f'promote: {cat}/{arch}/{fn} sha256 {h}')
    if a.log:
        os.makedirs(os.path.dirname(os.path.abspath(a.log)), exist_ok=True)
        with open(a.log, 'a') as f:
            f.write('\n'.join(lines) + '\n')


def tree_hashes(root):
    out = {}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root)] = sha256(p)
    return out


def cmd_same(a):
    x, y = tree_hashes(a.a), tree_hashes(a.b)
    bad = [f'only in {a.a}: {k}' for k in sorted(set(x) - set(y))] \
        + [f'only in {a.b}: {k}' for k in sorted(set(y) - set(x))] \
        + [f'differs: {k}' for k in sorted(set(x) & set(y)) if x[k] != y[k]]
    if bad:
        sys.exit('same: the trees differ\n' + '\n'.join(bad[:50]))
    print(f'same: {len(x)} files, identical')


def cmd_sort(a):
    names = [l.strip() for l in sys.stdin if l.strip()]

    def ver(n):
        m = APK_RE.match(n if n.endswith('.apk') else n + '.apk')
        return m['ver'] if m else '0-r0'
    import functools
    for n in sorted(names, key=functools.cmp_to_key(lambda x, y: version_cmp(ver(x), ver(y)))):
        print(n)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('assemble')
    p.add_argument('--stable', required=True)
    p.add_argument('--testing', required=True)
    p.add_argument('--out', required=True)
    p.set_defaults(f=cmd_assemble)
    p = sub.add_parser('promote')
    p.add_argument('--stable', required=True)
    p.add_argument('--testing', required=True)
    p.add_argument('--packages', required=True)
    p.add_argument('--log')
    p.add_argument('--run')
    p.set_defaults(f=cmd_promote)
    p = sub.add_parser('same')
    p.add_argument('a')
    p.add_argument('b')
    p.set_defaults(f=cmd_same)
    p = sub.add_parser('compare')
    p.add_argument('x')
    p.add_argument('y')
    p.set_defaults(f=lambda a: print(version_cmp(a.x, a.y)))
    p = sub.add_parser('sort')
    p.set_defaults(f=cmd_sort)
    a = ap.parse_args()
    a.f(a)


if __name__ == '__main__':
    main()
