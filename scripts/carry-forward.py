#!/usr/bin/env python3
"""carry-forward.py: fill packages/v3.24 with an already published tree.

Each CI run starts with an empty packages/ and publishes only what that run
holds. Without this step, each deploy would drop the previous package versions
and every package that the run cannot build. This script fetches the published
tree first. Then scripts/build.sh --skip-existing builds only the new
versions, and scripts/index.sh re-indexes and signs the merged result again.

  scripts/carry-forward.py [--from BASE_URL] [--seed URL_OR_FILE]
                           [--fallback-seed URL_OR_FILE] [--dest DIR]
                           [--keys DIR]

  --from BASE_URL        the published tree to fetch, as
                         BASE_URL/v3.24/<category>/<arch>/
                         (default https://tsx-aports.unexceptional.net).
                         The status 404 for an index means that nothing is
                         published yet. This is not an error. Any other
                         error fails the run.
  --seed X               a .tar.gz of a published tree (with v3.24/... inside)
                         at a URL or a local path. The script uses it INSTEAD
                         of --from. The file must exist.
  --fallback-seed X      like --seed, but the script uses it only if --from
                         published nothing (the first deploy). A missing
                         fallback gives a warning.
  --dest DIR             the destination (default packages/v3.24 in the repo).
  --keys DIR             the trusted public keys (default
                         common/tsx-keys/*.rsa.pub).

The script verifies every APKINDEX.tar.gz against the committed public keys
before it uses anything that the index lists. Every downloaded apk must match
the checksum (C: line) in its index. A failure stops the run. A tarball can
lack apks that its index lists (a trimmed seed). The script skips them,
because scripts/index.sh builds the published index again over the packages
that exist.
"""
import argparse
import base64
import glob
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
import zlib

CATEGORIES = ('common', 'xx60')
ARCHES = ('armv7',)
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def warn(msg):
    print(f'::warning title=carry-forward::{msg}', flush=True)


def log(msg):
    print(f'carry-forward: {msg}', flush=True)


def gz_members(buf):
    out = []
    while buf:
        d = zlib.decompressobj(31)
        d.decompress(buf)
        if not d.eof:
            raise SystemExit('truncated gzip member')
        n = len(buf) - len(d.unused_data)
        out.append(buf[:n])
        buf = d.unused_data
    return out


def tar_first_file(raw):
    """(name, content) of the first entry of a tar that may lack end blocks."""
    tf = tarfile.open(fileobj=io.BytesIO(raw))
    m = tf.next()
    return m.name.removeprefix('./'), tf.extractfile(m).read()


def verify_index(data, keys, what):
    """Verify an APKINDEX.tar.gz; return its APKINDEX text."""
    m = gz_members(data)
    if len(m) != 2:
        raise SystemExit(f'{what}: {len(m)} gzip members, expected 2 (signature, index)')
    name, sig = tar_first_file(zlib.decompress(m[0], 31))
    if name.startswith('.SIGN.RSA256.'):
        algo, keyname = 'sha256', name[len('.SIGN.RSA256.'):]
    elif name.startswith('.SIGN.RSA.'):
        algo, keyname = 'sha1', name[len('.SIGN.RSA.'):]
    else:
        raise SystemExit(f'{what}: unsigned index (first member is {name!r})')
    pub = keys.get(keyname)
    if pub is None:
        raise SystemExit(f'{what}: signed by {keyname}, not one of the committed keys ({", ".join(sorted(keys))})')
    with tempfile.TemporaryDirectory() as t:
        open(f'{t}/sig', 'wb').write(sig)
        open(f'{t}/idx', 'wb').write(m[1])
        r = subprocess.run(['openssl', 'dgst', f'-{algo}', '-verify', pub, '-signature', f'{t}/sig', f'{t}/idx'],
                           capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'{what}: BAD SIGNATURE ({keyname}): {r.stdout.strip()} {r.stderr.strip()}')
    tf = tarfile.open(fileobj=io.BytesIO(zlib.decompress(m[1], 31)))
    return tf.extractfile('APKINDEX').read().decode()


def parse_index(text):
    """[(filename, checksum)] from APKINDEX text."""
    out = []
    for stanza in text.strip().split('\n\n'):
        f = dict(l.split(':', 1) for l in stanza.splitlines() if ':' in l)
        out.append((f"{f['P']}-{f['V']}.apk", f['C']))
    return out


def apk_checksum(data):
    """apk's package id: Q1 + base64(sha1 of the control gzip member)."""
    m = gz_members(data)
    return 'Q1' + base64.b64encode(hashlib.sha1(m[1]).digest()).decode()


class Source:
    """Either an HTTP(S) base URL or a local directory holding v3.24/..."""

    def __init__(self, base, lenient):
        self.base, self.lenient = base, lenient

    def get(self, rel):
        """bytes, or None for "does not exist"."""
        if os.path.isdir(self.base):
            p = os.path.join(self.base, rel)
            return open(p, 'rb').read() if os.path.exists(p) else None
        req = urllib.request.Request(f'{self.base.rstrip("/")}/{rel}',
                                     headers={'User-Agent': 'tsx-aports-ci'})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return None
            raise SystemExit(f'{rel}: HTTP {e.code} from {self.base}')
        except OSError as e:
            raise SystemExit(f'{rel}: {e} ({self.base})')


def open_tarball(where, tmp):
    path = where
    if where.startswith(('http://', 'https://')):
        path = os.path.join(tmp, 'seed.tar.gz')
        req = urllib.request.Request(where, headers={'User-Agent': 'tsx-aports-ci'})
        try:
            with urllib.request.urlopen(req, timeout=600) as r, open(path, 'wb') as f:
                shutil.copyfileobj(r, f)
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return None
            raise SystemExit(f'seed {where}: HTTP {e.code}')
        except OSError as e:
            raise SystemExit(f'seed {where}: {e}')
    elif not os.path.isfile(path):
        return None
    root = os.path.join(tmp, 'seed')
    os.makedirs(root, exist_ok=True)
    with tarfile.open(path) as tf:
        for m in tf.getmembers():
            n = os.path.normpath(m.name)
            if n.startswith(('/', '..')) or not (m.isfile() or m.isdir()):
                raise SystemExit(f'seed {where}: refusing entry {m.name!r}')
        tf.extractall(root)
    return root


def carry(src, keys, dest):
    """Fetch every category/arch from src into dest; return the number of indexes found."""
    found = 0
    for cat in CATEGORIES:
        for arch in ARCHES:
            rel = f'v3.24/{cat}/{arch}'
            idx = src.get(f'{rel}/APKINDEX.tar.gz')
            if idx is None:
                log(f'{rel}: no index published')
                continue
            entries = parse_index(verify_index(idx, keys, f'{rel}/APKINDEX.tar.gz'))
            found += 1
            d = os.path.join(dest, cat, arch)
            os.makedirs(d, exist_ok=True)
            got = missing = 0
            for i, (fn, csum) in enumerate(entries, 1):
                target = os.path.join(d, fn)
                if os.path.exists(target) and apk_checksum(open(target, 'rb').read()) == csum:
                    got += 1
                    continue
                data = src.get(f'{rel}/{fn}')
                if data is None:
                    if src.lenient:
                        missing += 1
                        continue
                    raise SystemExit(f'{rel}/{fn}: listed in the signed index but not found')
                if apk_checksum(data) != csum:
                    raise SystemExit(f'{rel}/{fn}: does not match the checksum in the signed index')
                open(target, 'wb').write(data)
                got += 1
                log(f'{rel}: {i}/{len(entries)} {fn} ({len(data) / 1048576:.1f} MiB)')
            open(os.path.join(d, 'APKINDEX.tar.gz'), 'wb').write(idx)
            log(f'{rel}: {got} package(s) carried forward'
                + (f', {missing} listed but not in the seed (dropped by the re-index)' if missing else ''))
    return found


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--from', dest='base', default='https://tsx-aports.unexceptional.net')
    ap.add_argument('--seed')
    ap.add_argument('--fallback-seed')
    ap.add_argument('--dest', default=os.path.join(REPO, 'packages', 'v3.24'))
    ap.add_argument('--keys', default=os.path.join(REPO, 'common', 'tsx-keys'))
    a = ap.parse_args()

    keys = {os.path.basename(k): k for k in glob.glob(os.path.join(a.keys, '*.rsa.pub'))}
    if not keys:
        raise SystemExit(f'no *.rsa.pub in {a.keys}')
    tmp = tempfile.mkdtemp()
    try:
        if a.seed:
            root = open_tarball(a.seed, tmp)
            if root is None:
                raise SystemExit(f'seed {a.seed} not found')
            log(f'using seed {a.seed}')
            found = carry(Source(root, True), keys, a.dest)
        else:
            log(f'fetching the published tree from {a.base}')
            found = carry(Source(a.base, False), keys, a.dest)
            if found == 0 and a.fallback_seed:
                log('nothing published yet; trying the fallback seed')
                root = open_tarball(a.fallback_seed, tmp)
                if root is None:
                    warn(f'nothing is published and the seed {a.fallback_seed} does not exist: this run builds from scratch')
                else:
                    found = carry(Source(root, True), keys, a.dest)
        if found == 0:
            log('nothing carried forward (first publish)')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    main()
