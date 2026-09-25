# Zimbr icon

One shared mark for the Wayland client and macOS relay: an abstract bridge viewed
at an angle, so its soft supports and broad curved span suggest a Z. The support
tips hint at speech tails. A shallow extrusion, shaded lavender side walls, a
fine highlighted contour, and a soft cast shadow give the bridge depth.

Colors are based on [`src/client/theme.zig`](../../src/client/theme.zig): the tile
runs vertically from `accent_hover` (`#9A6CBE`) through `accent` (`#875CAB`) to a
deeper violet (`#714F90`, a blend of `accent` and `selected`). A broad, soft
`focus`-colored highlight lights the upper left, and a fine inset rim gives the
tile a gently rounded edge. The bridge face shades
from `on_accent` white through `ink` (`#EDE9F0`) to a lavender tint (`#D5C7E1`).
The sides use `focus` (`#B39ACB`) and `accent`; the shadow uses `rail` (`#21182B`).
The dark preview uses the app's `paper` (`#1C1D22`).

The bridge path is defined once in the SVG and reused for the face, extrusion,
and shadow. Depth is 14 units on the 512-unit canvas; lighting and contours
remain vector artwork, with only the cast shadow using a blur filter.

## Background study

Reviewed official app artwork and guidance on September 25, 2026. The visual
observations below inform the background; they are not claims about how those
apps implement their icons.

| Reference | Observed treatment | Application to Zimbr |
| --- | --- | --- |
| [Bear's Mac icon examples](https://bear.app/faq/bear-app-icons/) | Quiet single-hue gradients behind a dimensional white symbol | Keep the violet field simple and let the bridge be the focal point |
| [Things' OS 26 icon](https://culturedcode.com/things/blog/2025/09/things-for-os-26/) | Lit blue edges and a darker inset give the container depth | Use a restrained highlight along the tile's top edge |
| [Raycast's desktop icon](https://www.raycast.com/press) | A pronounced beveled border, textured dark face, and illuminated inset | Borrow only the edge definition, at a much lower intensity |
| [Apple's app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons) | Recommends simple backgrounds and subtle light-to-dark vertical gradients | Give the tile consistent top lighting and a deeper lower edge |

These effects target the shared static SVG/ICNS artwork. A future native
[Icon Composer](https://developer.apple.com/documentation/Xcode/creating-your-app-icon-using-icon-composer)
version would use separate layers and let the system apply its lighting effects.

![Shared icon on light and dark backgrounds, with small-size samples](preview.png)

- **Editable master:** [`../linux/zimbr.svg`](../linux/zimbr.svg), installed by the Linux build and installer.
- **PNG:** [`zimbr-1024.png`](zimbr-1024.png), 1024 × 1024 with transparent corners.
- **macOS:** [`../macos/zimbr.icns`](../macos/zimbr.icns), 16–1024 px with standard and Retina representations.

Both platforms use identical artwork and padding. The Mac installer copies the
ICNS into the app's `Contents/Resources` and sets `CFBundleIconFile`, following
[Apple's bundle convention](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconfile).

After editing the SVG, regenerate the committed exports from the repository root:

```sh
python3 tools/render-icons.py
```

Exporting requires `rsvg-convert` from librsvg. Normal builds and installations
use the committed files and do not require an image renderer.
