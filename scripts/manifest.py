#!/usr/bin/env python3
"""manifest.py: the list of every file that a deploy publishes, with sha256.

Every deploy writes manifest.txt at the root of the site and keeps a copy as
the artifact live-manifest of its run (see .github/workflows/build.yml). The
next run uses the copy as the truth about the live site. It does not trust what
the CDN of Pages returns, because the CDN can answer with the tree of an older
deploy for up to 10 minutes, whatever the request says.

Format: a first line "# manifest run=<id>", then one line
"<sha256>  <path>" for each file, sorted by path. The manifest does not list
itself.

  scripts/manifest.py make --tree DIR --run ID --out FILE
  scripts/manifest.py wait --manifest FILE --base URL [--timeout S] [--interval S]
      Poll the small files of the manifest (indexes, promoted.txt, CNAME) at
      URL until each one has the sha256 of the manifest. Exit 1 at the timeout.
  scripts/manifest.py verify --manifest FILE --stable DIR [--testing DIR]
      The fetched trees must be the trees of the manifest: DIR holds the files
      of v3.24/ (<category>/<arch>/...), the testing DIR those of
      testing/v3.24/. The same files, the same bytes. A missing file (a 404 for
      a whole category) or an extra file is an error.
  scripts/manifest.py check-file --manifest FILE --path PATH --file FILE
      The file must have the sha256 that the manifest lists for PATH.
  scripts/manifest.py check-tree --manifest FILE --prefix PATH --dir DIR
      The same, for one subtree: DIR must equal the files under PATH.
"""
import argparse
import hashlib
import os
import sys
import time
import urllib.error
import urllib.request


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for blk in iter(lambda: f.read(1 << 20), b''):
            h.update(blk)
    return h.hexdigest()


def read_manifest(path):
    out = {}
    for line in open(path):
        if line.startswith('#') or not line.strip():
            continue
        h, _, p = line.rstrip('\n').partition('  ')
        if len(h) != 64 or not p:
            sys.exit(f'manifest: bad line {line!r}')
        out[p] = h
    if not out:
        sys.exit(f'manifest: {path} lists no file')
    return out


def tree(root):
    out = {}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root)] = sha256(p)
    return out


def cmd_make(a):
    t = tree(a.tree)
    t.pop('manifest.txt', None)
    with open(a.out, 'w') as f:
        f.write(f'# manifest run={a.run}\n')
        for p in sorted(t):
            f.write(f'{t[p]}  {p}\n')
    print(f'manifest: {len(t)} files -> {a.out}')


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'tsx-aports-ci'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.read()
    except (urllib.error.URLError, OSError):
        return None


def cmd_wait(a):
    m = read_manifest(a.manifest)
    small = {p: h for p, h in m.items() if not p.endswith('.apk')}
    deadline = time.time() + a.timeout
    while True:
        bad = []
        for p, h in sorted(small.items()):
            data = fetch(f'{a.base.rstrip("/")}/{p}')
            if data is None or hashlib.sha256(data).hexdigest() != h:
                bad.append(p)
        if not bad:
            print(f'manifest: the live site matches the manifest ({len(small)} index files)')
            return
        if time.time() >= deadline:
            sys.exit('manifest: the live site does not match the manifest after '
                     f'{a.timeout} s: ' + ', '.join(bad[:10]))
        print(f'manifest: {len(bad)} file(s) are not the files of the last deploy yet ({bad[0]}); '
              f'waiting {a.interval} s', flush=True)
        time.sleep(a.interval)


def compare(want, got, label):
    bad = [f'{label}: missing {p}' for p in sorted(set(want) - set(got))] \
        + [f'{label}: unexpected {p}' for p in sorted(set(got) - set(want))] \
        + [f'{label}: differs {p}' for p in sorted(set(want) & set(got)) if want[p] != got[p]]
    return bad


def subtree(m, prefix):
    pre = prefix.rstrip('/') + '/'
    return {p[len(pre):]: h for p, h in m.items() if p.startswith(pre)}


def cmd_check_tree(a):
    bad = compare(subtree(read_manifest(a.manifest), a.prefix), tree(a.dir), a.prefix)
    if bad:
        sys.exit('manifest: the tree is not the tree of the last deploy\n' + '\n'.join(bad[:30]))
    print(f'manifest: {a.dir} is the tree {a.prefix} of the manifest')


def cmd_check_file(a):
    m = read_manifest(a.manifest)
    if a.path not in m:
        sys.exit(f'manifest: {a.path} is not in the manifest')
    if sha256(a.file) != m[a.path]:
        sys.exit(f'manifest: {a.file} is not the file {a.path} of the last deploy')
    print(f'manifest: {a.path} matches')


def cmd_verify(a):
    m = read_manifest(a.manifest)
    bad = compare(subtree(m, 'v3.24'), tree(a.stable), 'stable')
    if a.testing:
        bad += compare(subtree(m, 'testing/v3.24'), tree(a.testing), 'testing')
    if bad:
        sys.exit('manifest: the fetched trees are not the trees of the last deploy\n' + '\n'.join(bad[:30]))
    print('manifest: the fetched trees are the trees of the last deploy')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('make'); p.add_argument('--tree', required=True); p.add_argument('--run', default='-'); p.add_argument('--out', required=True); p.set_defaults(f=cmd_make)
    p = sub.add_parser('wait'); p.add_argument('--manifest', required=True); p.add_argument('--base', required=True)
    p.add_argument('--timeout', type=int, default=700); p.add_argument('--interval', type=int, default=30); p.set_defaults(f=cmd_wait)
    p = sub.add_parser('verify'); p.add_argument('--manifest', required=True); p.add_argument('--stable', required=True); p.add_argument('--testing'); p.set_defaults(f=cmd_verify)
    p = sub.add_parser('check-tree'); p.add_argument('--manifest', required=True); p.add_argument('--prefix', required=True); p.add_argument('--dir', required=True); p.set_defaults(f=cmd_check_tree)
    p = sub.add_parser('check-file'); p.add_argument('--manifest', required=True); p.add_argument('--path', required=True); p.add_argument('--file', required=True); p.set_defaults(f=cmd_check_file)
    a = ap.parse_args()
    a.f(a)


if __name__ == '__main__':
    main()
