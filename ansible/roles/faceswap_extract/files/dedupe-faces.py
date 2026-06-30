"""Thin near-identical faces via 64-bit dHash. Reads SRC/OUT/THRESH from env.

SRC/OUT are repo-relative (cwd = repo root, mounted at /fs in Docker). THRESH is
the Hamming-distance cutoff: drop a face whose hash is < THRESH bits from any kept
face. THRESH <= 0 copies everything.
"""
import os
import shutil

import numpy as np
from PIL import Image

src, out, thresh = os.environ["SRC"], os.environ["OUT"], int(os.environ["THRESH"])
os.makedirs(out, exist_ok=True)
files = sorted(f for f in os.listdir(src) if f.lower().endswith(".png"))


def dhash(path, size=8):
    # 9x8 grayscale -> 64-bit row-wise gradient hash (robust to tiny shifts/noise).
    img = Image.open(path).convert("L").resize((size + 1, size))
    a = np.asarray(img, dtype=np.int16)
    bits = a[:, 1:] > a[:, :-1]
    return np.packbits(bits.flatten())


kept_hashes, kept = [], 0
for f in files:
    if thresh > 0 and kept_hashes:
        h = dhash(os.path.join(src, f))
        if min(int(np.unpackbits(h ^ kh).sum()) for kh in kept_hashes) < thresh:
            continue  # too similar to something already kept -> drop
        kept_hashes.append(h)
    elif thresh > 0:
        kept_hashes.append(dhash(os.path.join(src, f)))
    shutil.copy2(os.path.join(src, f), os.path.join(out, f))
    kept += 1

print(f"Scanned {len(files)} faces -> kept {kept}, dropped {len(files) - kept} "
      f"(threshold {thresh} bits) -> {out}")
