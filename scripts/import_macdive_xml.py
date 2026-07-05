#!/usr/bin/env python3
"""Import a MacDive XML export into the local viewer XML layout."""

from __future__ import annotations

import argparse
import hashlib
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


FEET_PER_METER = 3.280839895
PSI_PER_BAR = 14.503773773


def text(element: ET.Element | None, default: str = "") -> str:
    if element is None or element.text is None:
        return default
    return element.text.strip()


def number(value: str, default: float | None = None) -> float | None:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def slug(value: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9]+", "-", value.strip().lower()).strip("-")
    return cleaned or "unknown"


def seconds_to_mmss(value: float | None) -> str:
    if value is None:
        return ""
    total = max(int(round(value)), 0)
    return f"{total // 60}:{total % 60:02d}"


def maybe_metric_depth(value: float | None, units: str) -> float | None:
    if value is None:
        return None
    return value / FEET_PER_METER if units.lower() == "imperial" else value


def maybe_metric_pressure(value: float | None, units: str) -> float | None:
    if value is None:
        return None
    return value / PSI_PER_BAR if units.lower() == "imperial" else value


def maybe_metric_temperature(value: float | None, units: str) -> float | None:
    if value is None:
        return None
    return (value - 32) * 5 / 9 if units.lower() == "imperial" else value


def add_text(parent: ET.Element, tag: str, value: object | None) -> ET.Element:
    child = ET.SubElement(parent, tag)
    if value is not None:
        child.text = str(value)
    return child


def format_float(value: float | None, digits: int = 2) -> str:
    return "" if value is None else f"{value:.{digits}f}"


def gas_label(gas: ET.Element) -> str:
    oxygen = text(gas.find("oxygen"), "21")
    helium = text(gas.find("helium"), "0")
    return f"{oxygen}/{helium}"


def fingerprint_for(dive: ET.Element, sequence: int) -> str:
    identity = "|".join(
        [
            text(dive.find("identifier")),
            text(dive.find("date")),
            text(dive.find("computer")),
            text(dive.find("serial")),
            text(dive.find("diveNumber")),
            str(sequence),
        ]
    )
    return hashlib.sha1(identity.encode("utf-8")).hexdigest()[:8].upper()


def convert_dive(dive: ET.Element, sequence: int, units: str) -> ET.Element:
    computer = text(dive.find("computer"), "Unknown Computer")
    serial = text(dive.find("serial"))
    source_name = f"MacDive - {computer}{f' {serial}' if serial else ''}"
    duration_seconds = number(text(dive.find("duration")))
    max_depth = maybe_metric_depth(number(text(dive.find("maxDepth"))), units)
    avg_depth = maybe_metric_depth(number(text(dive.find("averageDepth"))), units)

    root = ET.Element("device")
    out = ET.SubElement(root, "dive")
    add_text(out, "number", text(dive.find("diveNumber")) or sequence)
    add_text(out, "source", "MacDive")
    add_text(out, "computer", source_name)
    add_text(out, "datetime", text(dive.find("date")))
    add_text(out, "divetime", seconds_to_mmss(duration_seconds))
    add_text(out, "maxdepth", format_float(max_depth))
    add_text(out, "avgdepth", format_float(avg_depth))

    for gas in dive.findall("./gases/gas"):
        mix = ET.SubElement(out, "gasmix")
        add_text(mix, "he", text(gas.find("helium"), "0"))
        add_text(mix, "o2", text(gas.find("oxygen"), "21"))
        oxygen = number(text(gas.find("oxygen")), 21) or 21
        helium = number(text(gas.find("helium")), 0) or 0
        nitrogen = max(0, 100 - oxygen - helium)
        add_text(mix, "n2", format_float(nitrogen, 1))

        tank = ET.SubElement(out, "tank")
        add_text(tank, "usage", text(gas.find("supplyType")) or "tank")
        add_text(tank, "gasmix", gas_label(gas))
        add_text(tank, "beginpressure", format_float(maybe_metric_pressure(number(text(gas.find("pressureStart"))), units)))
        add_text(tank, "endpressure", format_float(maybe_metric_pressure(number(text(gas.find("pressureEnd"))), units)))
        tank_size = number(text(gas.find("tankSize")))
        if tank_size is not None and tank_size > 0:
            add_text(tank, "volume", format_float(tank_size, 1))
        add_text(tank, "workpressure", format_float(maybe_metric_pressure(number(text(gas.find("workingPressure"))), units)))

    add_text(out, "divemode", text(dive.find("gasModel")).lower())
    add_text(out, "decomodel", text(dive.find("decoModel")))
    add_text(out, "cns", text(dive.find("cns")))

    for sample in dive.findall("./samples/sample"):
        out_sample = ET.SubElement(out, "sample")
        sample_time = number(text(sample.find("time")))
        add_text(out_sample, "time", seconds_to_mmss(sample_time))
        add_text(out_sample, "depth", format_float(maybe_metric_depth(number(text(sample.find("depth"))), units)))
        add_text(out_sample, "temperature", format_float(maybe_metric_temperature(number(text(sample.find("temperature"))), units)))
        pressure = maybe_metric_pressure(number(text(sample.find("pressure"))), units)
        if pressure is not None:
            pressure_element = add_text(out_sample, "pressure", format_float(pressure))
            pressure_element.set("tank", "0")
        ppo2 = number(text(sample.find("ppo2")))
        if ppo2 is not None:
            add_text(out_sample, "ppo2", format_float(ppo2, 2))
        ndt = number(text(sample.find("ndt")))
        if ndt is not None:
            deco = add_text(out_sample, "deco", "ndl")
            deco.set("time", str(int(max(ndt, 0) * 60)))
            deco.set("depth", "0.00")

    return root


def output_path(dive: ET.Element, sequence: int, units: str, output_dir: Path) -> Path:
    computer = text(dive.find("computer"), "Unknown Computer")
    serial = text(dive.find("serial"))
    directory = output_dir / slug(f"{computer}-{serial}" if serial else computer)
    fingerprint = fingerprint_for(dive, sequence)
    return directory / f"macdive.{sequence:06d}.{fingerprint}.xml"


def import_macdive(input_file: Path, output_dir: Path, overwrite: bool) -> tuple[int, int]:
    units = "Metric"
    imported = 0
    skipped = 0

    for event, element in ET.iterparse(input_file, events=("end",)):
        if element.tag == "units":
            units = text(element, "Metric")
            continue
        if element.tag != "dive":
            continue

        sequence = imported + skipped + 1
        destination = output_path(element, sequence, units, output_dir)
        if destination.exists() and not overwrite:
            skipped += 1
            element.clear()
            continue

        destination.parent.mkdir(parents=True, exist_ok=True)
        root = convert_dive(element, sequence, units)
        ET.indent(root, space="  ")
        ET.ElementTree(root).write(destination, encoding="utf-8", xml_declaration=True)
        imported += 1
        element.clear()

    return imported, skipped


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Import MacDive XML into the local viewer XML layout.")
    parser.add_argument("input", type=Path, help="MacDive XML export")
    parser.add_argument("-o", "--output-dir", type=Path, default=Path("data/xml/macdive"))
    parser.add_argument("--overwrite", action="store_true", help="overwrite existing imported XML files")
    args = parser.parse_args(argv)

    if not args.input.exists():
        print(f"Missing input: {args.input}", file=sys.stderr)
        return 1

    imported, skipped = import_macdive(args.input, args.output_dir, args.overwrite)
    print(f"MacDive import complete: {imported} imported, {skipped} skipped into {args.output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
