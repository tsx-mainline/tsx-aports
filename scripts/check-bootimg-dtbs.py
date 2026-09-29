#!/usr/bin/env python3
"""check-bootimg-dtbs.py IMG DTB_DIR: does the packed xx60 boot image carry
the board DTBs of DTB_DIR, byte for byte, where U-Boot looks for them?

The vendor U-Boot takes the DTB from the Android boot image's "second"
payload: a plain FDT (booted on any panel) or an Amlogic AML_ multi-DTB
container, searched for the env aml_dt. With a TSW-760 DTB in DTB_DIR
(meson8m2-crestron-tsw760.dtb) the image must be a container whose
yushan_one_10inch entry is the TSW-1060 DTB and whose yushan_one_7inch entry
is the TSW-760 DTB (the vendor's old10inch/old7inch entries, if present, the
same per size). Without it, the second payload must be the TSW-1060 DTB
itself. Exit 0 = OK, 1 = mismatch (one line per problem), 2 = usage."""
import os
import struct
import sys

D1060, D760 = 'meson8m2-crestron-tsw1060.dtb', 'meson8m2-crestron-tsw760.dtb'


def second_of(img):
    if img[:8] != b'ANDROID!':
        raise SystemExit('not an Android boot image')
    ks, rs, ss, ps = (struct.unpack_from('<I', img, o)[0] for o in (8, 16, 24, 36))
    up = lambda n: (n + ps - 1) // ps * ps
    o = ps + up(ks) + up(rs)
    return img[o:o + ss]


def swap4(b):
    return b''.join(b[i:i + 4][::-1] for i in range(0, len(b), 4))


def entries(sec):
    n = struct.unpack_from('<I', sec, 8)[0]
    out = {}
    for i in range(n):
        e = 12 + i * 56
        ids = [swap4(sec[e + k * 16:e + k * 16 + 16]).rstrip(b' \0').decode() for k in range(3)]
        off = struct.unpack_from('<I', sec, e + 48)[0]
        size = struct.unpack_from('>I', sec, off + 4)[0]    # FDT totalsize
        out['_'.join(ids)] = sec[off:off + size]
    return out


def main():
    if len(sys.argv) != 3:
        print(__doc__); return 2
    img, d = open(sys.argv[1], 'rb').read(), sys.argv[2]
    sec = second_of(img)
    dtb10 = open(os.path.join(d, D1060), 'rb').read()
    p760 = os.path.join(d, D760)
    bad = []
    if not os.path.exists(p760):
        if sec != dtb10:
            bad.append('second payload is not the plain TSW-1060 DTB')
    elif sec[:4] != b'AML_':
        bad.append('second payload is not an AML_ multi-DTB container (a TSW-760 would not get its DTB)')
    else:
        dtb7 = open(p760, 'rb').read()
        ent = entries(sec)
        want = {'yushan_one_10inch': dtb10, 'yushan_one_7inch': dtb7}
        for name, blob in want.items():
            if ent.get(name) != blob:
                bad.append(f'{name} entry is {"missing" if name not in ent else "not byte-identical to the board DTB"}')
        for name, blob in (('yushan_one_old10inch', dtb10), ('yushan_one_old7inch', dtb7)):
            if name in ent and ent[name] != blob:
                bad.append(f'{name} entry does not match the {name[-6:]} board DTB')
        print('container entries: ' + ', '.join(sorted(ent)))
    for b in bad:
        print('check-bootimg-dtbs: ' + b)
    if not bad:
        print('check-bootimg-dtbs: OK (' + ('TSW-1060 + TSW-760 container' if os.path.exists(p760) else 'plain TSW-1060 DTB') + ')')
    return 1 if bad else 0


sys.exit(main())
