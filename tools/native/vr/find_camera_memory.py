"""Where the game keeps its camera: a native frame dump's camera matrix, found in guest memory.

usage: python3 find_camera_memory.py DUMP_DIR
DUMP_DIR is a frame dump taken with --gtav_native_dump_memory=true (draws.bin + physical.bin), e.g.
  dev_play_mac.sh --gtav_native_dump_after_load=600 --gtav_native_dump_memory=true

The camera's world matrix is vertex constants c12..c15 of the world draws (rows: right, up,
forward, position; world Z up; docs/VR_CAMERA.md). This finds every 16-byte-row copy of it in
physical memory (big-endian floats, with a little tolerance: the dump trails the frame) and lists
the copies outside the dense command-buffer regions, with the floats around them.
"""
import collections
import struct
import sys
import warnings

import numpy as np

warnings.filterwarnings('ignore')


def camera_from_draws(path):
    data = open(path, 'rb').read()
    rec = 4 * 2052  # {prim, count, ps ucode hash (u64), 2048 constant floats}
    cams = collections.Counter()
    for i in range(len(data) // rec):
        c = struct.unpack_from('<2048f', data, i * rec + 16)
        m = [c[4 * r:4 * r + 4] for r in (12, 13, 14, 15)]
        rows = [x[:3] for x in m[:3]]
        orthonormal = all(abs(sum(v * v for v in row) - 1) < 2e-3 for row in rows) and all(
            abs(sum(a * b for a, b in zip(rows[i], rows[j]))) < 2e-3 for i in range(3) for j in range(i + 1, 3))
        if orthonormal and abs(m[1][2]) > 0.5:  # up row mostly +Z
            cams[tuple(round(v, 4) for row in m for v in row[:3])] += 1
    if not cams:
        sys.exit('no camera matrix in vs c12..c15 of this frame (loading screen?)')
    cam, n = cams.most_common(1)[0]
    return np.array(cam).reshape(4, 3), n


def main():
    d = sys.argv[1]
    cam, n = camera_from_draws(d + '/draws.bin')
    print(f'camera (vs c12..c15) in {n} draws:')
    for name, row in zip(('right', 'up', 'forward', 'position'), cam):
        print(f'  {name:8s} ' + ' '.join(f'{v:10.4f}' for v in row))
    m = np.fromfile(d + '/physical.bin', dtype='>f4').astype(np.float64)
    count = len(m) - 16
    tol = (0.03, 0.03, 0.03, 1.5)
    ok = np.ones(count, bool)
    for r in range(4):
        for k in range(3):
            ok &= np.abs(m[4 * r + k:4 * r + k + count] - cam[r, k]) < tol[r]
    idx = np.where(ok)[0]
    regions = collections.Counter((i * 4) >> 20 for i in idx)
    print(f'{len(idx)} copies; per MB of physical memory:',
          ' '.join(f'{k:#05x}:{v}' for k, v in sorted(regions.items())))
    print('copies outside dense regions (8 floats before .. 24 after):')
    for i in idx:
        if regions[(i * 4) >> 20] > 16:
            continue
        print(f'  phys {i * 4:#010x}:', ' '.join(f'{v:.3f}' for v in m[i - 8:i + 24]))


if __name__ == '__main__':
    main()
