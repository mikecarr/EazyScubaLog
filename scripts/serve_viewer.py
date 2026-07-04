#!/usr/bin/env python3
"""Serve a local Perdix dive viewer backed by data/xml files."""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ET


REPO_ROOT = Path(__file__).resolve().parents[1]
VIEWER_DIR = REPO_ROOT / "viewer"
DEFAULT_XML_DIR = REPO_ROOT / "data" / "xml"
DEFAULT_RAW_DIR = REPO_ROOT / "data" / "raw"
DEFAULT_LOG_DIR = REPO_ROOT / "logs"
DIVE_FILE_RE = re.compile(r"perdix-ai\.(\d{4})\.([0-9A-Fa-f]+)\.xml$")
RAW_FILE_RE = re.compile(r"perdix-ai\.(\d{4})\.([0-9A-Fa-f]+)\.bin$")
DEFAULT_COMPUTER = "Shearwater Perdix AI"


def text(element: ET.Element | None, default: str = "") -> str:
    if element is None or element.text is None:
        return default
    return element.text.strip()


def number(value: str, default: float | None = None) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def parse_minutes(value: str) -> int | None:
    if not value or ":" not in value:
        return None
    minutes, seconds = value.split(":", 1)
    try:
        return int(minutes) * 60 + int(float(seconds))
    except ValueError:
        return None


def xml_files(xml_dir: Path) -> list[Path]:
    return sorted(xml_dir.rglob("perdix-ai.*.*.xml"))


def raw_count(raw_dir: Path) -> int:
    return len(list(raw_dir.rglob("perdix-ai.*.*.bin")))


def raw_numbers(raw_dir: Path) -> set[int]:
    numbers = set()
    for path in raw_dir.rglob("perdix-ai.*.*.bin"):
        match = RAW_FILE_RE.match(path.name)
        if match:
            numbers.add(int(match.group(1)))
    return numbers


def parse_dive_root(path: Path) -> ET.Element:
    root = ET.parse(path).getroot()
    dive = root.find("dive") if root.tag == "device" else root
    if dive is None:
        raise ValueError(f"No dive element found in {path}")
    return dive


def path_metadata(path: Path) -> tuple[int | None, str]:
    match = DIVE_FILE_RE.match(path.name)
    if not match:
        return None, ""
    return int(match.group(1)), match.group(2).upper()


def computer_from_path(path: Path, xml_dir: Path) -> str:
    relative = path.relative_to(xml_dir)
    if len(relative.parts) == 1:
        return DEFAULT_COMPUTER
    key = relative.parts[0]
    parts = key.replace("_", "-").split("-")
    serial = parts[-1].upper() if parts and re.fullmatch(r"[0-9A-Fa-f]{6,}", parts[-1]) else ""
    name_parts = parts[:-1] if serial else parts
    name = " ".join(part.capitalize() for part in name_parts)
    return f"{name} {serial}".strip()


def gasmix_label(gas: ET.Element) -> str:
    o2 = text(gas.find("o2"), "?")
    he = text(gas.find("he"), "0")
    usage = text(gas.find("usage"))
    label = f"{o2}/{he}"
    return f"{usage} {label}" if usage else label


def tank_summary(tank: ET.Element) -> dict[str, object]:
    begin = number(text(tank.find("beginpressure")))
    end = number(text(tank.find("endpressure")))
    volume = number(text(tank.find("volume")))
    gas_used = None
    if begin is not None and end is not None and volume is not None:
        gas_used = max(begin - end, 0) * volume

    return {
        "usage": text(tank.find("usage")) or "tank",
        "gasmix": text(tank.find("gasmix")),
        "beginPressure": begin,
        "endPressure": end,
        "gasUsedLiters": gas_used,
        "volume": volume,
        "workPressure": number(text(tank.find("workpressure"))),
    }


def deco_summary(samples: list[ET.Element]) -> dict[str, object]:
    last_deco = None
    max_tts = 0
    deco_samples = 0
    for sample in samples:
        tts = number(text(sample.find("tts")), 0) or 0
        max_tts = max(max_tts, int(tts))
        deco = sample.find("deco")
        if deco is None:
            continue
        kind = text(deco)
        last_deco = {
            "type": kind,
            "time": number(deco.get("time", "")),
            "depth": number(deco.get("depth", "")),
        }
        if kind in {"deco", "deep"}:
            deco_samples += 1
    return {
        "maxTts": max_tts,
        "last": last_deco,
        "hasDeco": deco_samples > 0,
    }


def sac_summary(tanks: list[dict[str, object]], divetime_seconds: int | None, avg_depth: float | None) -> dict[str, object]:
    gas_used = sum(
        tank["gasUsedLiters"]
        for tank in tanks
        if isinstance(tank.get("gasUsedLiters"), (int, float))
    )
    result = {
        "gasUsedLiters": gas_used if gas_used else None,
        "rmvLitersPerMin": None,
        "available": False,
        "note": "",
    }
    if not gas_used:
        result["note"] = "Tank volume unavailable; SAC/RMV cannot be calculated from pressure alone."
        return result
    if not divetime_seconds or not avg_depth:
        result["note"] = "Average depth or dive time unavailable."
        return result

    minutes = divetime_seconds / 60
    ambient = 1 + avg_depth / 10
    if minutes <= 0 or ambient <= 0:
        result["note"] = "Invalid duration or ambient pressure."
        return result

    result["rmvLitersPerMin"] = gas_used / minutes / ambient
    result["available"] = True
    return result


def average_sample_depth(samples: list[ET.Element]) -> float | None:
    points = [
        (parse_minutes(text(sample.find("time"))), number(text(sample.find("depth"))))
        for sample in samples
    ]
    points = [(time, depth) for time, depth in points if time is not None and depth is not None]
    if len(points) < 2:
        depths = [depth for _, depth in points]
        return sum(depths) / len(depths) if depths else None

    points.sort(key=lambda point: point[0])
    area = 0.0
    duration = 0
    previous_time, previous_depth = points[0]
    for current_time, current_depth in points[1:]:
        interval = current_time - previous_time
        if interval > 0:
            area += ((previous_depth + current_depth) / 2) * interval
            duration += interval
        previous_time, previous_depth = current_time, current_depth

    return area / duration if duration > 0 else None


def parse_summary(path: Path, xml_dir: Path = DEFAULT_XML_DIR) -> dict[str, object]:
    dive = parse_dive_root(path)
    file_number, fingerprint = path_metadata(path)
    number_text = text(dive.find("number"))
    dive_number = file_number if file_number is not None else int(number_text) if number_text.isdigit() else None
    samples = dive.findall("sample")

    tanks = [tank_summary(tank) for tank in dive.findall("tank")]
    gasmixes = [gasmix_label(gas) for gas in dive.findall("gasmix")]
    divetime_seconds = parse_minutes(text(dive.find("divetime")))
    avg_depth = number(text(dive.find("avgdepth"))) or average_sample_depth(samples)

    return {
        "id": path.relative_to(xml_dir).as_posix(),
        "number": dive_number,
        "computer": computer_from_path(path, xml_dir),
        "fingerprint": fingerprint,
        "file": path.relative_to(xml_dir).as_posix(),
        "datetime": text(dive.find("datetime")),
        "divetime": text(dive.find("divetime")),
        "divetimeSeconds": divetime_seconds,
        "maxDepth": number(text(dive.find("maxdepth"))),
        "avgDepth": avg_depth,
        "mode": text(dive.find("divemode")),
        "decoModel": text(dive.find("decomodel")),
        "gf": text(dive.find("gf")),
        "salinity": text(dive.find("salinity")),
        "atmospheric": number(text(dive.find("atmospheric"))),
        "gasmixes": gasmixes,
        "tanks": tanks,
        "deco": deco_summary(samples),
        "sac": sac_summary(tanks, divetime_seconds, avg_depth),
        "sampleCount": len(samples),
        "sizeBytes": number(text(dive.find("size"))),
    }


def parse_sample(sample: ET.Element) -> dict[str, object]:
    values: dict[str, object] = {
        "time": text(sample.find("time")),
        "timeSeconds": parse_minutes(text(sample.find("time"))),
        "depth": number(text(sample.find("depth"))),
        "temperature": number(text(sample.find("temperature"))),
        "setpoint": number(text(sample.find("setpoint"))),
        "cns": number(text(sample.find("cns"))),
        "tts": number(text(sample.find("tts"))),
        "gasmix": text(sample.find("gasmix")),
    }

    deco = sample.find("deco")
    if deco is not None:
        values["deco"] = {
            "type": text(deco),
            "time": number(deco.get("time", "")),
            "depth": number(deco.get("depth", "")),
        }

    pressures: dict[str, float | None] = {}
    for pressure in sample.findall("pressure"):
        tank = pressure.get("tank", "0")
        pressures[tank] = number(text(pressure))
    if pressures:
        values["pressures"] = pressures

    ppo2_values = []
    for ppo2 in sample.findall("ppo2"):
        ppo2_values.append({
            "sensor": ppo2.get("sensor"),
            "value": number(text(ppo2)),
        })
    if ppo2_values:
        values["ppo2"] = ppo2_values

    return {key: value for key, value in values.items() if value not in ("", None, {})}


def parse_detail(path: Path, xml_dir: Path = DEFAULT_XML_DIR) -> dict[str, object]:
    dive = parse_dive_root(path)
    summary = parse_summary(path, xml_dir)
    return {
        "summary": summary,
        "samples": [parse_sample(sample) for sample in dive.findall("sample")],
        "events": [
            {
                "time": parse_sample(sample).get("time"),
                "type": event.get("type"),
                "name": text(event),
                "value": event.get("value"),
            }
            for sample in dive.findall("sample")
            for event in sample.findall("event")
        ],
    }


def import_status(raw_dir: Path, log_dir: Path = DEFAULT_LOG_DIR) -> dict[str, object]:
    manifest_count = None
    failed: dict[int, str] = {}
    last_failure = ""
    for log_path in sorted(log_dir.glob("shearwater-download-*.log")):
        for line in log_path.read_text(errors="ignore").splitlines():
            manifest_match = re.search(r"Manifest contains (\d+) active dive records", line)
            if manifest_match:
                manifest_count = int(manifest_match.group(1))
            failed_match = re.search(r"Failed dive (\d+).*: (.+)$", line)
            if failed_match:
                dive_number = int(failed_match.group(1))
                reason = failed_match.group(2)
                failed[dive_number] = reason
                last_failure = reason

    downloaded = raw_numbers(raw_dir)
    missing = []
    if manifest_count:
        missing = [number for number in range(1, manifest_count + 1) if number not in downloaded]

    return {
        "manifestCount": manifest_count,
        "downloadedRawCount": len(downloaded),
        "missingRawCount": len(missing),
        "missingRaw": missing,
        "failedCount": len(failed),
        "failedDives": [{"number": number, "reason": reason} for number, reason in sorted(failed.items())],
        "lastFailure": last_failure,
    }


def summaries(xml_dir: Path, raw_dir: Path) -> dict[str, object]:
    dives = []
    errors = []
    for path in xml_files(xml_dir):
        try:
            dives.append(parse_summary(path, xml_dir))
        except Exception as exc:  # noqa: BLE001 - returned to local viewer.
            errors.append({"file": path.name, "error": str(exc)})

    dives.sort(key=lambda dive: dive.get("number") or 0)
    return {
        "dives": dives,
        "xmlCount": len(dives),
        "rawCount": raw_count(raw_dir),
        "status": import_status(raw_dir),
        "errors": errors,
    }


def find_xml_by_number(xml_dir: Path, dive_number: str) -> Path | None:
    try:
        value = int(dive_number)
    except ValueError:
        return None
    pattern = f"perdix-ai.{value:04d}.*.xml"
    matches = sorted(xml_dir.rglob(pattern))
    return matches[0] if matches else None


def find_xml_by_id(xml_dir: Path, dive_id: str) -> Path | None:
    path = (xml_dir / dive_id).resolve()
    if xml_dir.resolve() not in path.parents:
        return None
    return path if path.exists() and path.is_file() else None


class ViewerHandler(BaseHTTPRequestHandler):
    xml_dir: Path = DEFAULT_XML_DIR
    raw_dir: Path = DEFAULT_RAW_DIR

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"{self.address_string()} - {fmt % args}")

    def send_json(self, payload: object, status: HTTPStatus = HTTPStatus.OK) -> None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_file(self, path: Path) -> None:
        if not path.exists() or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        data = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
        parsed = urlparse(self.path)
        route = unquote(parsed.path)
        if route.startswith("/xml/"):
            relative = route.removeprefix("/xml/")
            path = (self.xml_dir / relative).resolve()
            if self.xml_dir.resolve() not in path.parents:
                self.send_error(HTTPStatus.FORBIDDEN)
                return
        else:
            path = VIEWER_DIR / "index.html" if route == "/" else VIEWER_DIR / route.lstrip("/")
        if not path.exists() or not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
        parsed = urlparse(self.path)
        route = unquote(parsed.path)

        if route == "/api/dives":
            self.send_json(summaries(self.xml_dir, self.raw_dir))
            return

        if route.startswith("/api/dives/"):
            dive_number = route.rsplit("/", 1)[-1]
            path = find_xml_by_number(self.xml_dir, dive_number)
            if path is None:
                self.send_json({"error": "Dive not found"}, HTTPStatus.NOT_FOUND)
                return
            try:
                self.send_json(parse_detail(path, self.xml_dir))
            except Exception as exc:  # noqa: BLE001 - returned to local viewer.
                self.send_json({"error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if route.startswith("/api/dive/"):
            dive_id = route.removeprefix("/api/dive/")
            path = find_xml_by_id(self.xml_dir, dive_id)
            if path is None:
                self.send_json({"error": "Dive not found"}, HTTPStatus.NOT_FOUND)
                return
            try:
                self.send_json(parse_detail(path, self.xml_dir))
            except Exception as exc:  # noqa: BLE001 - returned to local viewer.
                self.send_json({"error": str(exc)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if route.startswith("/xml/"):
            relative = route.removeprefix("/xml/")
            path = (self.xml_dir / relative).resolve()
            if self.xml_dir.resolve() not in path.parents:
                self.send_error(HTTPStatus.FORBIDDEN)
                return
            self.send_file(path)
            return

        if route == "/":
            self.send_file(VIEWER_DIR / "index.html")
            return

        static_path = (VIEWER_DIR / route.lstrip("/")).resolve()
        if VIEWER_DIR.resolve() not in static_path.parents and static_path != VIEWER_DIR.resolve():
            self.send_error(HTTPStatus.FORBIDDEN)
            return
        self.send_file(static_path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Serve the local Perdix dive viewer.")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--xml-dir", type=Path, default=DEFAULT_XML_DIR)
    parser.add_argument("--raw-dir", type=Path, default=DEFAULT_RAW_DIR)
    args = parser.parse_args()

    ViewerHandler.xml_dir = args.xml_dir.resolve()
    ViewerHandler.raw_dir = args.raw_dir.resolve()

    server = ThreadingHTTPServer((args.host, args.port), ViewerHandler)
    print(f"Serving viewer at http://{args.host}:{args.port}")
    print(f"XML directory: {ViewerHandler.xml_dir}")
    print(f"Raw directory: {ViewerHandler.raw_dir}")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
