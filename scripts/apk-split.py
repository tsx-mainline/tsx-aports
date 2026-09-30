#!/usr/bin/env python3
"""apk-split.py APK OUTDIR: split an apk v2 package into its gzip members
sig.tar.gz (the signature), control.tar.gz, and data.tar.gz (byte-exact).

scripts/resign.sh uses this script to re-sign a package that was built with
a different (throwaway) key. It splits the package and discards the old
sig.tar.gz. It signs control.tar.gz again with the real key, and joins
control and data into a package. An apk v2 package is the concatenation of
three gzip streams in this order. The split uses the gzip member boundaries
and needs no knowledge of the tar contents.
"""
import os
import sys
import zlib


def members(buf):
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


def main():
    apk, outdir = sys.argv[1:3]
    m = members(open(apk, 'rb').read())
    if len(m) != 3:
        raise SystemExit(f'{apk}: {len(m)} gzip members, expected 3 (sig, control, data)')
    sig = zlib.decompress(m[0], 31)
    if b'.SIGN.' not in sig[:512]:
        raise SystemExit(f'{apk}: first member is not a signature')
    os.makedirs(outdir, exist_ok=True)
    for name, b in zip(('sig.tar.gz', 'control.tar.gz', 'data.tar.gz'), m):
        open(os.path.join(outdir, name), 'wb').write(b)
    print(f'{os.path.basename(apk)}: old signature {sig[:100].split(bytes(1))[0].decode()}')


if __name__ == '__main__':
    main()
