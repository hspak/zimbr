#!/usr/bin/env python3
"""Export the shared SVG as PNG, macOS ICNS, and a light/dark preview.

Requires rsvg-convert (librsvg); no Python packages or macOS tools are needed.
The committed exports let ordinary application builds skip this step.
"""
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'packaging/linux/zimbr.svg'
OUTPUT = ROOT / 'packaging/icons'
MAC_ICON = ROOT / 'packaging/macos/zimbr.icns'

# Standard and Retina representations, stored as lossless PNG payloads.
ICNS_SIZES = (
    (b'icp4', 16), (b'ic11', 32),
    (b'icp5', 32), (b'ic12', 64),
    (b'ic07', 128), (b'ic13', 256),
    (b'ic08', 256), (b'ic14', 512),
    (b'ic09', 512), (b'ic10', 1024),
)


def render(source, width, height):
    return subprocess.check_output([
        'rsvg-convert', '--width', str(width), '--height', str(height), str(source),
    ])


def main():
    if not shutil.which('rsvg-convert'):
        raise SystemExit('Install librsvg (rsvg-convert) to regenerate the icons.')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    images = {size: render(SOURCE, size, size) for size in sorted({s for _, s in ICNS_SIZES})}
    (OUTPUT / 'zimbr-1024.png').write_bytes(images[1024])
    chunks = b''.join(kind + struct.pack('>I', len(images[size]) + 8) + images[size]
                      for kind, size in ICNS_SIZES)
    MAC_ICON.write_bytes(b'icns' + struct.pack('>I', len(chunks) + 8) + chunks)

    # Embed the master so the preview has no external artwork dependencies.
    ET.register_namespace('', 'http://www.w3.org/2000/svg')
    svg = ET.parse(SOURCE).getroot()
    artwork = ''.join(ET.tostring(child, encoding='unicode') for child in svg)
    samples = ''.join(
        f'<use href="#icon" x="{x}" y="{666 - size}" width="{size}" height="{size}"/>'
        f'<text x="{x + size / 2}" y="696" text-anchor="middle">{size}</text>'
        for x, size in ((292, 16), (376, 24), (468, 32), (568, 48), (684, 64), (816, 96))
    )
    preview = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1120" height="752" viewBox="0 0 1120 752">
      <defs><symbol id="icon" viewBox="0 0 512 512">{artwork}</symbol></defs>
      <rect width="1120" height="752" fill="#EDE9F0"/>
      <g font-family="sans-serif" fill="#25202D">
        <text x="56" y="72" font-size="36" font-weight="bold">Zimbr</text>
        <text x="1064" y="68" text-anchor="end" font-size="16">One design · Linux + macOS</text>
        <rect x="40" y="108" width="512" height="448" rx="24" fill="#FFFFFF"/>
        <rect x="568" y="108" width="512" height="448" rx="24" fill="#1C1D22"/>
        <use href="#icon" x="144" y="164" width="304" height="304"/>
        <use href="#icon" x="672" y="164" width="304" height="304"/>
        <text x="296" y="516" text-anchor="middle" font-size="16">Light</text>
        <text x="824" y="516" text-anchor="middle" font-size="16" fill="#ACA5B4">Dark</text>
        <g font-size="13" fill="#77717F">
          <text x="64" y="654" font-size="16">At a glance</text>
          {samples}
        </g>
      </g>
    </svg>'''
    with tempfile.TemporaryDirectory(prefix='zimbr-icons-') as temporary:
        preview_source = Path(temporary) / 'preview.svg'
        preview_source.write_text(preview)
        (OUTPUT / 'preview.png').write_bytes(render(preview_source, 1120, 752))
    print('Exported packaging/icons/{zimbr-1024,preview}.png and packaging/macos/zimbr.icns')


if __name__ == '__main__':
    main()
