#!/usr/bin/env python3
"""Convert downloaded Shearwater raw dive files to libdivecomputer XML."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


DEVICE_NAME = "Shearwater Perdix AI"


DEFAULT_RAW_DIR = Path("data/raw")


def output_name(raw_file: Path, output_dir: Path) -> Path:
    try:
        relative = raw_file.relative_to(DEFAULT_RAW_DIR)
    except ValueError:
        relative = Path(raw_file.name)
    return output_dir / relative.parent / (raw_file.stem + ".xml")


def convert_file(raw_file: Path, output_dir: Path, device: str, overwrite: bool) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    xml_file = output_name(raw_file, output_dir)
    if xml_file.exists() and not overwrite:
        print(f"Skipping existing {xml_file}")
        return 0

    command = [
        "dctool",
        "-d",
        device,
        "parse",
        "-o",
        str(xml_file),
        str(raw_file),
    ]
    print("+ " + " ".join(command))
    return subprocess.call(command)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Convert Shearwater Perdix AI raw .bin dives to XML."
    )
    parser.add_argument(
        "inputs",
        nargs="*",
        type=Path,
        help="raw .bin files to convert; defaults to data/raw/**/*.bin",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        type=Path,
        default=Path("data/xml"),
        help="directory for XML files; default: data/xml",
    )
    parser.add_argument(
        "--device",
        default=DEVICE_NAME,
        help=f"dctool device name; default: {DEVICE_NAME}",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="overwrite existing XML files",
    )
    args = parser.parse_args(argv)

    inputs = args.inputs or sorted(DEFAULT_RAW_DIR.rglob("*.bin"))
    if not inputs:
        print("No raw .bin files found.", file=sys.stderr)
        return 1

    failed = 0
    for raw_file in inputs:
        if not raw_file.exists():
            print(f"Missing input: {raw_file}", file=sys.stderr)
            failed += 1
            continue
        rc = convert_file(raw_file, args.output_dir, args.device, args.overwrite)
        if rc:
            failed += 1

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
