# Finds orthonormal 3x3 blocks (rows = 3 consecutive float4 registers, xyz) in a native frame dump's
# per-draw constants (draws.bin: {prim, count, ps ucode hash, 2048 floats} per draw; floats 0..1023
# = 256 vs registers, 1024..2047 = 256 ps registers). Groups by register and values.
import struct, sys, collections, math
data = open(sys.argv[1], 'rb').read(); rec = 4 * 2052
draws = [struct.unpack_from('<2048f', data, i * rec + 16) for i in range(len(data) // rec)]
def ortho(m):
    for i in range(3):
        if abs(sum(m[i][k]*m[i][k] for k in range(3)) - 1) > 2e-3: return False
        for j in range(i+1, 3):
            if abs(sum(m[i][k]*m[j][k] for k in range(3))) > 2e-3: return False
    return True
hits = collections.Counter(); sample = {}
for d in draws:
    for bank, base in (('vs', 0), ('ps', 1024)):
        for r in range(0, 253):
            rows = [d[base + 4*(r+i): base + 4*(r+i) + 4] for i in range(3)]
            if not all(all(math.isfinite(x) for x in row) for row in rows): continue
            if ortho([row[:3] for row in rows]):
                key = (bank, r, tuple(round(x, 4) for row in rows for x in row[:3]))
                hits[key] += 1; sample[key] = [d[base + 4*(r+i): base + 4*(r+i)+4] for i in range(4)]
print(len(draws), 'draws')
for (bank, r, vals), n in hits.most_common(12):
    if n < 20: break
    print(f'{bank} c{r}: {n} draws')
    for row in sample[(bank, r, vals)]: print('   ', ' '.join(f'{x:9.4f}' for x in row))
