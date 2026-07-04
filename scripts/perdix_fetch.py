#!/usr/bin/env python3
"""Small wrapper around dctool for Shearwater Perdix AI raw downloads."""

from __future__ import annotations

import argparse
import datetime as dt
import shutil
import subprocess
import sys
from pathlib import Path


DEVICE_NAME = "Shearwater Perdix AI"
RAW_TEMPLATE = "perdix-ai.%n.%f.bin"
RAW_TEMPLATE_HELP = RAW_TEMPLATE.replace("%", "%%")


def require_dctool() -> str:
    dctool = shutil.which("dctool")
    if not dctool:
        raise SystemExit(
            "dctool was not found on PATH. Install libdivecomputer first."
        )
    return dctool


def run(args: list[str]) -> int:
    print("+ " + " ".join(args))
    return subprocess.call(args)


def timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def scan(args: argparse.Namespace) -> int:
    dctool = require_dctool()
    return run([dctool, "scan", "-t", args.transport])


def download(args: argparse.Namespace) -> int:
    dctool = require_dctool()
    raw_dir = Path(args.output_dir)
    log_dir = Path(args.log_dir)
    raw_dir.mkdir(parents=True, exist_ok=True)
    log_dir.mkdir(parents=True, exist_ok=True)

    output_template = raw_dir / args.template
    logfile = log_dir / f"perdix-ai-download-{timestamp()}.log"

    command = [
        dctool,
        "-d",
        args.device,
        "-l",
        str(logfile),
        "-v",
        "-v",
        "download",
        "-t",
        args.transport,
        "-f",
        "raw",
        "-o",
        str(output_template),
    ]

    if args.fingerprint:
        command.extend(["-p", args.fingerprint])

    command.append(args.devname)
    return run(command)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Retrieve Shearwater Perdix AI dives as per-dive raw files."
    )
    parser.set_defaults(func=None)
    subcommands = parser.add_subparsers(dest="command")

    scan_parser = subcommands.add_parser("scan", help="scan for BLE dive computers")
    scan_parser.add_argument(
        "-t",
        "--transport",
        default="ble",
        help="dctool transport name; default: ble",
    )
    scan_parser.set_defaults(func=scan)

    download_parser = subcommands.add_parser(
        "download", help="download dives as one raw file per dive"
    )
    download_parser.add_argument("devname", help="device name/address from scan output")
    download_parser.add_argument(
        "-d",
        "--device",
        default=DEVICE_NAME,
        help=f"dctool device descriptor; default: {DEVICE_NAME!r}",
    )
    download_parser.add_argument(
        "-t",
        "--transport",
        default="ble",
        help="dctool transport name; default: ble",
    )
    download_parser.add_argument(
        "-o",
        "--output-dir",
        default="data/raw",
        help="directory for raw dive files; default: data/raw",
    )
    download_parser.add_argument(
        "--log-dir",
        default="logs",
        help="directory for dctool logs; default: logs",
    )
    download_parser.add_argument(
        "--template",
        default=RAW_TEMPLATE,
        help=f"raw output filename template; default: {RAW_TEMPLATE_HELP!r}",
    )
    download_parser.add_argument(
        "-p",
        "--fingerprint",
        help="hex fingerprint of the newest already-imported dive",
    )
    download_parser.set_defaults(func=download)

    return parser


def main(argv: list[str]) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.func is None:
        parser.print_help()
        return 2
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
