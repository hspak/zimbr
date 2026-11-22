"""Physical key vocabulary shared by SDL event playback and compositor input."""
from pathlib import Path

KEYS = {name: dict(scancode=int(scancode), evdev=int(evdev))
        for name, scancode, evdev in (line.split() for line in
            Path(__file__).with_name("keys.tsv").read_text().splitlines())}


def chord_names(chord):
    names = chord.split("+")
    if not names or len(names) > 8 or len(names) != len(set(names)) or any(n not in KEYS for n in names):
        raise ValueError(f"Invalid key chord: {chord}. Supported keys: {', '.join(KEYS)}")
    return names
