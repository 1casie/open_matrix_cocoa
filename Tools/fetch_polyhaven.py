"""Fetch the CC0 Poly Haven textures used by matrix_cocoa.

Usage:  python Tools/fetch_polyhaven.py

Textures -> Assets/ThirdParty/PolyHaven/Textures/<id>/<id>_{diff,nor_gl}_<res>.jpg
They are packed into Texture2DArrays by Matrix Cocoa > Rebuild Texture Arrays
(Assets/MatrixCocoa/Editor/CityTextures.cs); the ORDER below is the array slice index the
city shader uses (see FACADE_TEX_* in Shaders/Include/CityParams.cginc).

Everything on Poly Haven is CC0 (https://polyhaven.com/license).
Re-running is cheap: files that already exist with the right size are skipped.
"""
import json
import os
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(ROOT, "Assets", "ThirdParty", "PolyHaven")
UA = {"User-Agent": "matrix_cocoa-vrchat-world-fetcher/1.0"}
RES = "1k"   # the city is seen from tens to thousands of metres away; 1k is plenty

# slice order matters (see docstring)
TEXTURES = [
    "concrete",               # 0: bare weathered panels - the default megablock skin
    "concrete_wall_006",      # 1: rough board-marked, stained - monolith walls / undercity
    "concrete_slab_wall_02",  # 2: precast slab panels - residential grids
    "concrete_tile_facade",   # 3: grooved square tiles - institute / ministry facades
]


def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA)) as r:
        return json.load(r)


def download(url, dest, size=None):
    if os.path.exists(dest) and (size is None or os.path.getsize(dest) == size):
        return "skip"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".part"
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA)) as r, open(tmp, "wb") as f:
        while chunk := r.read(1 << 16):
            f.write(chunk)
    os.replace(tmp, dest)
    return "ok"


def texture_jobs(asset_id):
    files = get_json(f"https://api.polyhaven.com/files/{asset_id}")
    jobs = []
    for key, suffix in (("Diffuse", "diff"), ("nor_gl", "nor_gl")):
        node = files[key][RES]["jpg"]
        dest = os.path.join(OUT, "Textures", asset_id, f"{asset_id}_{suffix}_{RES}.jpg")
        jobs.append((node["url"], dest, node.get("size")))
    return jobs


def main():
    jobs = [j for t in TEXTURES for j in texture_jobs(t)]
    with ThreadPoolExecutor(8) as ex:
        for (url, dest, _), status in zip(jobs, ex.map(lambda j: download(*j), jobs)):
            print(f"[{status}] {os.path.relpath(dest, ROOT)}")
    lines = ["# Poly Haven assets (CC0)", "",
             "All assets below are CC0 from https://polyhaven.com - no attribution required, but thanks!", ""]
    for tid in TEXTURES:
        info = get_json(f"https://api.polyhaven.com/info/{tid}")
        authors = ", ".join(info.get("authors", {}).keys())
        lines.append(f"- texture `{tid}` ({info.get('name', tid)}) by {authors} - https://polyhaven.com/a/{tid}")
    with open(os.path.join(OUT, "CREDITS.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
