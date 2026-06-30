"""Drop blurry faces by Laplacian variance. Reads SRC/OUT/THRESH from env.

SRC/OUT are repo-relative (cwd = repo root, mounted at /fs in Docker). THRESH is
the minimum variance to keep; THRESH <= 0 = REPORT only (print distribution, copy
nothing) so you can pick a value.
"""
import os
import shutil

import cv2

src, out, thresh = os.environ["SRC"], os.environ["OUT"], float(os.environ["THRESH"])
files = sorted(f for f in os.listdir(src) if f.lower().endswith(".png"))


def sharpness(path):
    # Variance of the Laplacian: low = blurry / out of focus, high = crisp edges.
    g = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
    return float(cv2.Laplacian(g, cv2.CV_64F).var())


vals = [(f, sharpness(os.path.join(src, f))) for f in files]
vs = sorted(v for _, v in vals)
pct = lambda p: vs[min(len(vs) - 1, int(p * len(vs)))] if vs else 0.0
print(f"Blur (Laplacian variance) over {len(vals)} faces:")
print(f"  min={vs[0]:.0f}  p10={pct(.10):.0f}  p25={pct(.25):.0f}  "
      f"median={pct(.50):.0f}  p75={pct(.75):.0f}  max={vs[-1]:.0f}")

if thresh > 0:
    os.makedirs(out, exist_ok=True)
    kept = 0
    for f, v in vals:
        if v >= thresh:
            shutil.copy2(os.path.join(src, f), os.path.join(out, f))
            kept += 1
    print(f"threshold={thresh:.0f} -> kept {kept}, dropped {len(vals) - kept} -> {out}")
else:
    print("REPORT only (fs_blur_threshold=0). Pick ~p10-p25 then set fs_blur_threshold=<n>.")
