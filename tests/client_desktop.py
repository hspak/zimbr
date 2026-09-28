#!/usr/bin/env python3
"""Check the GUI's Wayland application ID against its installed desktop identity.

Run after building the client, inside a Wayland session. The temporary client
has no credentials and never connects to a relay.
"""
import argparse
import configparser
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=ROOT / 'zig-out/bin/zimbr')
    options = parser.parse_args()
    desktop = ROOT / 'packaging/linux/zimbr.desktop'
    entry = configparser.ConfigParser(interpolation=None)
    entry.read(desktop)
    app_id = desktop.stem
    icon = entry['Desktop Entry']['Icon']
    assert (ROOT / 'packaging/linux' / (icon + '.svg')).is_file()

    with tempfile.TemporaryDirectory(prefix='zimbr-desktop-') as temporary:
        root = Path(temporary)
        result = subprocess.run(
            [str(options.binary.resolve()), '--data-dir', str(root / 'client'),
             '--frames', '2'],
            env={**os.environ, 'WAYLAND_DEBUG': 'client',
                 'XDG_CONFIG_HOME': str(root / 'config')},
            capture_output=True, text=True, timeout=30,
        )
        assert result.returncode == 0, result.stderr
        reported = re.findall(r'xdg_toplevel[^\n]*\.set_app_id\("([^"\n]*)"\)', result.stderr)
        assert reported, 'Window never reported a Wayland application ID'
        assert set(reported) == {app_id}, f'Expected {app_id!r}; window reported {reported!r}'
    print(f'PASS: Wayland app ID {app_id!r} matches {desktop.name} and icon {icon!r}')


if __name__ == '__main__':
    main()
