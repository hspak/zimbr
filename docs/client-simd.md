# Client SIMD trials, September 24

Two candidates were retained: compiler-vectorized opaque text conversion and
libjpeg-turbo's direct RGBA output. The printable-ASCII validation fast path was
removed because it did not materially improve complete layout time.

The baseline is `42b694369fe728d8db23b8700fc11e5912336500`, which already includes
the earlier relay/client performance pass. Each candidate was tested separately,
using the earlier retained changes as its baseline. Each experiment ran three
pairs in alternating order: before/after, after/before, before/after. A process
warms up for one batch, then measures 15 batches. The figures below are medians
of the three per-process medians; the range uses each pair's reduction.

The retention threshold was approximately 10% less time for a complete CPU
operation, repeated across representative inputs, with identical output checksums.
These are synthetic Linux x86_64 measurements on an AMD Ryzen AI Max+ 395, using
Zig 0.16.0 `cc -O3 -march=native`, Pango 1.58.2, and libjpeg-turbo 3.2.0. They
exclude GPU upload/presentation and network transfer, and are not M1 measurements.

| Operation | Before | After | Time reduction | Three-pair range | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| Short opaque text raster | 4.125 µs | 2.948 µs | 28.5% | 26.7–31.3% | Keep |
| Multiline Unicode opaque raster | 53.525 µs | 36.438 µs | 31.9% | 30.7–32.7% | Keep |
| Long opaque raster at 2× scale | 830.409 µs | 453.302 µs | 45.4% | 43.0–46.8% | Keep |
| 128×128 JPEG | 37.022 µs | 34.043 µs | 8.0% | 0.5–26.4% | Inconclusive alone |
| 1920×1080 JPEG | 5.450 ms | 4.110 ms | 24.6% | 23.1–26.8% | Keep |
| 2560×1440 JPEG | 9.746 ms | 7.250 ms | 25.6% | 23.6–27.6% | Keep |
| 1024×768 grayscale JPEG | 1.759 ms | 1.404 ms | 20.2% | 19.9–22.8% | Keep |
| Short ASCII layout | 9.823 µs | 9.564 µs | 2.6% | 1.4–3.0% | Drop |
| Approximately 4 KiB ASCII layout | 1.000 ms | 0.977 ms | 2.3% | 1.2–2.5% | Drop |
| Long ASCII draft layout | 62.098 ms | 61.726 ms | 0.6% | 0.5–1.3% | Drop |
| Mixed Unicode layout | 1.675 ms | 1.725 ms | −3.0% | −4.7–0.9% | Drop |

Opaque raster measurements include Cairo surface creation, glyph rasterization,
channel conversion, and surface destruction, reusing a measured Pango layout.
Whole-pixel loads and bit operations let LLVM generate SIMD byte shuffles; native
assembly contains `vpshufb` operating on 16 pixels per instruction. The source
does not require a particular SIMD instruction set. The unchanged transparent
path was a control: 88.008 to 83.294 µs, a 5.4% shift that is not counted as a gain.

JPEG measurements include opening and validating a cached file, reading its
bytes, decoding, updating its access timestamp, and freeing the pixels. Direct
RGBA output eliminates the intermediate RGB row and expansion pass. It uses
`JCS_ALPHA_EXTENSIONS` to preserve the existing RGB fallback for other libjpeg
builds. See libjpeg-turbo's [color-space extension contract](https://github.com/libjpeg-turbo/libjpeg-turbo/blob/main/README.md#colorspace-extensions).

Layout measurements include UTF-8 validation, the safety scan, Pango shaping and
measurement, and destruction. The discarded candidate checked printable ASCII
in 16-byte vectors and skipped Unicode classification for those bytes, retaining
word-wrap, line, and combining-mark limits. Full layout costs made the gain too
small to justify the extra code.

All trial image/tile checksums matched their baselines, including transparent
text, emoji, bidirectional text, RGB JPEGs, and grayscale JPEGs. The saved
[raw results](client-simd-2026-09-24.json) include every run, source hashes, library
versions, and the discarded ASCII patch. JPEG fixtures are synthetic gradients
with deterministic noise; there is no account data.

Verification passed: 53 client tests, 38 tests in the isolated Wayland GUI suite,
the authenticated media transport suite, and a release client build. Coverage
includes channel order on colored backgrounds, fractional-scale tiled text,
selection and bidirectional text, and rejection of JPEGs with a missing end marker.

## Reproduce

Install the normal client build dependencies. Save `bridge.c` and `media.c` from
the baseline in a directory, then compare each operation separately:

```sh
mkdir -p /tmp/zimbr-simd-baseline
git show 42b694369fe728d8db23b8700fc11e5912336500:src/client/bridge.c > /tmp/zimbr-simd-baseline/bridge.c
git show 42b694369fe728d8db23b8700fc11e5912336500:src/client/media.c > /tmp/zimbr-simd-baseline/media.c
python3 tests/client_simd.py --baseline /tmp/zimbr-simd-baseline --case raster --output /tmp/raster.json
python3 tests/client_simd.py --baseline /tmp/zimbr-simd-baseline --case jpeg --output /tmp/jpeg.json
```

The runner compiles both variants from source and compares three pairs, failing
if output checksums differ. `--candidate` selects another directory containing
the two C files. For the discarded layout experiment, use the retained source as
the baseline and apply the patch stored in the JSON to a separate candidate copy,
then run `--case layout`. Run benchmarks without concurrent builds or tests.
