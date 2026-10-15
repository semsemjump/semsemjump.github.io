"""Build dist/semsem-jump.html: one self-contained page with the font, sprites and sounds embedded,
plus the home-screen icons and web app manifest beside it.

    python3 build.py
"""
import base64
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).parent
ASSETS = ROOT / "assets"
OUT = ROOT / "dist" / "semsem-jump.html"

SFX = ["step", "milestone", "wrong", "tick", "toggle", "start", "gameover", "record",
       "coin", "hit", "bossin", "bossdown", "buy", "item", "nope"]
MUSIC = ["title", "main", "boss"]


def b64(path: Path) -> str:
    return base64.b64encode(path.read_bytes()).decode()


def main() -> None:
    assets = {
        "tiles": "data:image/png;base64," + b64(ASSETS / "sprites/tilemap_packed.png"),
        "chars": "data:image/png;base64," + b64(ASSETS / "sprites/tilemap-characters_packed.png"),
        "bgs": "data:image/png;base64," + b64(ASSETS / "sprites/tilemap-backgrounds_packed.png"),
    }
    for name in SFX:
        assets["snd_" + name] = "data:audio/wav;base64," + b64(ASSETS / f"sfx/{name}.wav")
    for name in MUSIC:
        assets["mus_" + name] = "data:audio/mp4;base64," + b64(ASSETS / f"music/mus_{name}.m4a")

    page = (ROOT / "src/game.html").read_text(encoding="utf-8")
    page = page.replace("__GALMURI__", b64(ASSETS / "font/Galmuri11-Bold.woff2"))
    page = page.replace("__ASSETS__", json.dumps(assets))
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(page, encoding="utf-8")
    # home-screen icons and the web app manifest sit next to the page
    for name in ("apple-touch-icon.png", "icon-192.png", "icon-512.png", "manifest.webmanifest"):
        shutil.copyfile(ASSETS / "icons" / name, OUT.parent / name)
    print(f"{OUT.relative_to(ROOT)}  {len(page) / 1e6:.2f} MB")


if __name__ == "__main__":
    main()
