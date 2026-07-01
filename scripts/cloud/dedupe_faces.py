"""Thin near-identical faces via 64-bit dHash. Reads SRC/OUT/THRESH from env.

Shipped to the serverless worker by `serverless_extract.py` (Image.copy) so the
dedupe step works regardless of which faceswap repo the worker clones. THRESH is
the Hamming-distance cutoff: drop a face whose hash is < THRESH bits from any kept
face. THRESH <= 0 copies everything.
"""
import os
import shutil

import numpy as np
from PIL import Image


def dhash(path, size=8):
    # 9x8 grayscale -> 64-bit row-wise gradient hash (robust to tiny shifts/noise).
    img = Image.open(path).convert("L").resize((size + 1, size))
    a = np.asarray(img, dtype=np.int16)
    bits = a[:, 1:] > a[:, :-1]
    return np.packbits(bits.flatten())


def main() -> None:
    try:
        src = os.environ["SRC"]
        out = os.environ["OUT"]
        thresh = int(os.environ["THRESH"])
    except KeyError as exc:
        raise SystemExit(f"dedupe_faces: missing required env var {exc}") from exc
    except ValueError as exc:
        raise SystemExit(f"dedupe_faces: THRESH must be an integer — {exc}") from exc

    os.makedirs(out, exist_ok=True)
    files = sorted(f for f in os.listdir(src) if f.lower().endswith(".png"))

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


if __name__ == "__main__":
    main()
