#!/usr/bin/env python3
"""Build a deterministic LWS candidate ZIP and a machine-readable receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ROOT_FILES = {
    "CHANGELOG.md",
    "README.md",
    "SOURCE_PROVENANCE.json",
    "THIRD_PARTY_NOTICES.md",
    "main.lua",
    "manifest.json",
    "weather_main.lua",
    "release-review/AUDIO-SOURCES.json",
    "release-review/AUDIO-PROVENANCE.json",
}
ROOT_DIRS = ("assets", "bootstrap", "compat", "lib", "media")
ZIP_TIME = (2026, 9, 12, 0, 0, 0)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def release_files() -> list[Path]:
    files = [ROOT / name for name in ROOT_FILES]
    for directory in ROOT_DIRS:
        files.extend(path for path in (ROOT / directory).rglob("*") if path.is_file())
    files = sorted(set(files), key=lambda path: path.relative_to(ROOT).as_posix())
    missing = [str(path.relative_to(ROOT)) for path in files if not path.exists()]
    if missing:
        raise SystemExit("missing release inputs: " + ", ".join(missing))
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    manifest = json.loads((ROOT / "manifest.json").read_text(encoding="utf-8"))
    version = manifest["version"]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    archive = args.output_dir / f"Lightweight-Weather-and-Skies-{version}.zip"
    files = release_files()

    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in files:
            relative = path.relative_to(ROOT).as_posix()
            info = zipfile.ZipInfo(relative, ZIP_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, path.read_bytes(), compresslevel=9)

    with zipfile.ZipFile(archive) as bundle:
        bad = bundle.testzip()
        names = bundle.namelist()
    if bad:
        raise SystemExit(f"ZIP CRC failed at {bad}")
    if names != [path.relative_to(ROOT).as_posix() for path in files]:
        raise SystemExit("ZIP inventory differs from the selected release inputs")

    receipt = {
        "artifact": archive.name,
        "version": version,
        "sha256": sha256(archive),
        "fileCount": len(files),
        "status": "PENDING EXACT-ARTIFACT AUDIT",
        "openChecks": [
            "owner reports the Gen 1 Quest checks passed in a private RC Lab; the final cloud-spacing adjustment was checked on PC, not separately on Quest",
            "owner reports the Gen 1 PC cloud, sky and rain comparisons passed; Gen 2 is beta and non-VR Android is alpha",
            "showcase controls intentionally leave some manual weather selected; return WEATHER to AUTO is documented",
            "permission is owner-reported and credited, without a blanket upstream license claim",
            "this generated ZIP still needs an exact-artifact inventory, provenance, naming and media audit before publication",
        ],
        "excludedDevelopmentFiles": [
            ".git/",
            "DISCORD-POST.txt",
            "FOREST_SAVANNAH_CLIMATES.md",
            "tests/",
            "tools/",
        ],
        "files": names,
    }
    receipt_path = args.output_dir / "RELEASE-RECEIPT.json"
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"archive": str(archive), "sha256": receipt["sha256"], "files": len(files)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
