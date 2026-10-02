#!/usr/bin/env python3
"""Generate the bundled Unicode catalog from a local github/gemoji db/emoji.json.

Pinned source: https://github.com/github/gemoji/blob/fadaeaf1f1a9be82b321316a6c5502e43138b2f6/db/emoji.json
Usage: python3 tools/generate_emoji.py /path/to/emoji.json
When updating the source revision, also update licenses/gemoji.txt.
"""
import argparse
import json
from pathlib import Path
import re


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parents[1] / "src/client/emoji/catalog.tsv")
    args = parser.parse_args()
    aliases = {}
    for entry in json.loads(args.source.read_text(encoding="utf-8")):
        text = entry.get("emoji")
        if not text:
            continue  # Custom image emoji have no Unicode sequence.
        if text.isascii() or any(character in text for character in "\r\n\t\0"):
            raise ValueError(f"Invalid Unicode emoji: {text!r}")
        for name in entry["aliases"]:
            if not re.fullmatch(r"[a-zA-Z0-9_+\-]+", name) or name in aliases:
                raise ValueError(f"Invalid or duplicate shortcode: {name!r}")
            aliases[name] = text
    args.output.write_text("".join(f"{name}\t{text}\n" for name, text in sorted(aliases.items())),
                           encoding="utf-8")


if __name__ == "__main__":
    main()
