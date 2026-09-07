#!/usr/bin/env python3
"""Encode synthetic method-13 probes and compare both forks with a decoder.

The optional unar oracle is a development tool, never bundled or linked.
All input and expected output are generated from the documented wire grammar.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent

def crc(data):
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0xA001 if value & 1 else 0)
    return value

def canonical(widths):
    result = {}
    value = 0
    for width in range(1, 33):
        for symbol, size in enumerate(widths):
            if size == width:
                result[symbol] = [(value >> bit) & 1 for bit in reversed(range(width))]
                value += 1
        value *= 2
    return result

class Probe:
    def __init__(self, preset):
        self.codes = [canonical(preset[key]) for key in ["literal", "match", "distance"]]
        self.bits = []
        self.output = bytearray()
        self.context = 0

    def low(self, value, width):
        self.bits.extend((value >> bit) & 1 for bit in range(width))

    def symbol(self, symbol):
        self.bits.extend(self.codes[self.context][symbol])

    def literal(self, value):
        self.symbol(value)
        self.output.append(value)
        self.context = 0

    def match(self, symbol, category=0, extra=0):
        self.symbol(symbol)
        length = symbol - 253
        if symbol in (318, 319):
            width = 10 if symbol == 318 else 15
            self.low((1 << width) - 1, width)
            length = 65 + (1 << width) - 1
        self.bits.extend(self.codes[2][category])
        width = max(0, category - 1)
        self.low(extra, width)
        distance = 1 if category == 0 else (1 << width) + extra + 1
        for _ in range(length):
            self.output.append(self.output[-distance] if distance <= len(self.output) else 0)
        self.context = 1

    def payload(self, number):
        self.symbol(320)
        data = bytearray([number << 4]) + bytearray((len(self.bits) + 7) // 8)
        for index, bit in enumerate(self.bits):
            data[1 + index // 8] |= bit << (index % 8)
        return bytes(data)

def make_probe(preset, number):
    probe = Probe(preset)
    # Initial zero history, overlap, every A literal, and every B literal.
    probe.match(256)
    for value in range(256):
        probe.literal(value)
    for value in range(256):
        probe.match(256)
        probe.literal(value)
    # Every A/B length token, including maximum extended lengths.
    for token in range(256, 320):
        probe.literal(167)
        probe.match(token)
        probe.match(token)
        probe.literal(92)
    # A deterministic nonperiodic history makes all distance categories and
    # both extra-bit endpoints observable in the expected output.
    value = 0x12345678
    for _ in range(1 << (len(preset["distance"]) - 1)):
        value ^= (value << 13) & 0xffffffff
        value ^= value >> 17
        value ^= (value << 5) & 0xffffffff
        probe.literal(value & 255)
    for category in range(len(preset["distance"])):
        for extra in [0, (1 << max(0, category - 1)) - 1]:
            probe.match(287, category, extra)
    expected = bytes(probe.output)
    payload = probe.payload(number)
    header = bytearray(112)
    header[:4] = bytes([13, 13, 1, 102])
    header[66:74] = b"TEXTttxt"
    struct.pack_into(">IIIIHH", header, 84, len(expected), len(expected), len(payload), len(payload), crc(expected), crc(expected))
    struct.pack_into(">H", header, 110, crc(header[:110]))
    body = bytes(header) + payload + payload
    archive = bytearray(22)
    archive[:4] = b"SIT!"
    struct.pack_into(">HI", archive, 4, 1, 22 + len(body))
    archive[10:15] = b"rLau\x01"
    return bytes(archive) + body, expected

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--reference", type=Path, help="Optional installed unar executable")
    parser.add_argument("--write-fixtures", action="store_true")
    args = parser.parse_args()
    data = json.loads((ROOT / "docs/format/method13-codebooks.json").read_text())
    manifest = {}
    with tempfile.TemporaryDirectory(prefix="unsit-codebooks-") as tmp:
        root = Path(tmp).resolve()
        for number, preset in enumerate(data["presets"], 1):
            archive, expected = make_probe(preset, number)
            name = "codebooks_preset_" + str(number)
            path = root / (name + ".sit")
            path.write_bytes(archive)
            manifest[name] = {"length": len(expected), "sha256": hashlib.sha256(expected).hexdigest(), "archive_sha256": hashlib.sha256(archive).hexdigest()}
            for label, binary in [("unsit", args.binary), ("reference", args.reference)]:
                if binary is None:
                    continue
                output = root / (name + "-" + label)
                command = [str(binary.resolve()), "--", str(path), str(output)] if label == "unsit" else [str(binary.resolve()), "-D", "-nr", "-k", "fork", "-o", str(output), str(path)]
                result = subprocess.run(command, capture_output=True, timeout=30)
                if result.returncode != 0:
                    raise SystemExit(label + " failed: " + result.stderr.decode(errors="replace") + result.stdout.decode(errors="replace"))
                for fork in [output / "f", output / "f/..namedfork/rsrc"]:
                    if fork.read_bytes() != expected:
                        raise SystemExit(label + " fork mismatch for " + name)
                print(label + ": preset " + str(number) + " passed both forks")
            if args.write_fixtures:
                (ROOT / "Tests/unsitTests/Fixtures" / (name + ".sit")).write_bytes(archive)
    target = ROOT / "Tests/unsitTests/Fixtures/codebooks.json"
    if args.write_fixtures:
        target.write_text(json.dumps(manifest, indent=2) + "\n")
    elif target.exists() and json.loads(target.read_text()) != manifest:
        raise SystemExit("Synthetic codebook fixture manifest differs")

if __name__ == "__main__":
    main()
