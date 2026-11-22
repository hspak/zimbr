"""Lossless region comparisons. Baselines change only through an explicit command."""
import math
from pathlib import Path
import shutil
import struct
import subprocess
import time

from .errors import ExpectationFailed, Unsupported, ZrctError
from .environment import executable


def dimensions(path):
    with Path(path).open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ZrctError(f"Not a PNG: {path}")
    width, height = struct.unpack("!II", header[16:24])
    if not width or not height or width * height > 64_000_000:
        raise ZrctError(f"Invalid or excessive PNG dimensions: {width}x{height}")
    return width, height


def command(args, *, accept=(0,), timeout=15):
    magick = executable("magick")
    if not magick:
        raise Unsupported("ImageMagick is required for visual assertions")
    result = subprocess.run([magick, *map(str, args)], capture_output=True, text=True, timeout=timeout)
    if result.returncode not in accept:
        raise ZrctError("Image comparison tool failed", argv=list(map(str, args)),
                        returncode=result.returncode, stderr=result.stderr[:4096])
    return result


def crop(source, target, region):
    geometry = crop_geometry(region, dimensions(source))
    command([source, "-crop", geometry, "+repage", target])
    return Path(target)


def crop_geometry(region, size):
    width, height = size
    x, y, w, h = map(int, region)
    if x < 0 or y < 0 or w <= 0 or h <= 0 or x + w > width or y + h > height:
        raise ZrctError("Crop is outside the image", region=region, dimensions=(width, height))
    return f"{w}x{h}+{x}+{y}"


def metric(result):
    try:
        changed = float(result.stderr.strip().split()[0])
        if not math.isfinite(changed) or changed < 0 or not changed.is_integer():
            raise ValueError("invalid metric")
        return int(changed)
    except (ValueError, IndexError) as error:
        raise ZrctError("ImageMagick returned an invalid pixel-count metric", stderr=result.stderr[:4096]) from error


def compare(actual, expected, bundle, *, name="visual", region=None, masks=(), max_changed_pixels=0):
    if not isinstance(max_changed_pixels, int) or max_changed_pixels < 0:
        raise ValueError("max_changed_pixels must be a nonnegative integer")
    actual, expected = Path(actual).resolve(), Path(expected).resolve()
    if not expected.exists():
        raise ExpectationFailed(f"Missing baseline: {expected}; create it with zrct baseline --accept",
                                actual=str(actual), expected=str(expected))
    directory = bundle.root / f"{name}-{time.monotonic_ns()}"
    with bundle.step(f"compare {name}", expected=str(expected), tolerance_pixels=max_changed_pixels) as step:
        actual_size, expected_size = dimensions(actual), dimensions(expected)
        if actual_size == expected_size and not masks:
            extract = ["-extract", crop_geometry(region, actual_size)] if region else []
            # PDC counts differing pixels in the pinned ImageMagick; AE measures
            # difference magnitude and can undercount small color changes.
            changed = metric(command(["compare", "-metric", "PDC", *extract, expected, actual, "null:"], accept=(0, 1)))
            step["changed_pixels"] = changed
            if changed <= max_changed_pixels:
                return changed
        # Successful comparisons need the metric, not duplicate crops and enlarged
        # zero-difference images. Retain full diagnostic artifacts on a mismatch.
        directory.mkdir()
        local_actual, local_expected = directory / "actual.png", directory / "expected.png"
        if region:
            crop(actual, local_actual, region)
            crop(expected, local_expected, region)
        else:
            shutil.copyfile(actual, local_actual)
            shutil.copyfile(expected, local_expected)
        bundle.artifact(local_actual, "crop")
        bundle.artifact(local_expected, "baseline")
        if actual_size != expected_size:
            raise ExpectationFailed("Screenshot dimensions differ", expected=expected_size, observed=actual_size)
        size = dimensions(local_actual)
        compare_actual, compare_expected = local_actual, local_expected
        if masks:
            draw = []
            for x, y, w, h in masks:
                if min(x, y) < 0 or min(w, h) <= 0 or x + w > size[0] or y + h > size[1]:
                    raise ValueError("Mask must be inside the compared region")
                draw.extend(["-draw", f"rectangle {x},{y} {x+w-1},{y+h-1}"])
            mask = directory / "mask.png"
            command(["-size", f"{size[0]}x{size[1]}", "xc:white", "-fill", "black", *draw, mask])
            bundle.artifact(mask, "mask")
            compare_actual, compare_expected = directory / "masked-actual.png", directory / "masked-expected.png"
            command([local_actual, "-fill", "black", *draw, compare_actual])
            command([local_expected, "-fill", "black", *draw, compare_expected])
        difference = directory / "difference.png"
        result = command(["compare", "-metric", "PDC", compare_expected, compare_actual, difference], accept=(0, 1))
        changed = metric(result)
        step["changed_pixels"] = changed
        bundle.artifact(difference, "diff", changed_pixels=changed)
        enlarged = directory / "magnified.png"
        command([difference, "-filter", "point", "-resize", "300%", enlarged])
        bundle.artifact(enlarged, "crop")
        if changed > max_changed_pixels:
            raise ExpectationFailed(f"{name}: {changed:g} changed pixels (allowed {max_changed_pixels})",
                                    expected=str(local_expected), actual=str(local_actual), diff=str(difference),
                                    changed_pixels=changed, tolerance=max_changed_pixels)
        return changed


def update_baseline(actual, expected):
    actual, expected = Path(actual).resolve(), Path(expected).resolve()
    dimensions(actual)
    expected.parent.mkdir(parents=True, exist_ok=True)
    if expected.exists():
        previous = expected.with_suffix(".previous.png")
        shutil.copyfile(expected, previous)
        command(["compare", previous, actual, expected.with_suffix(".update-diff.png")], accept=(0, 1))
    shutil.copyfile(actual, expected)
    profile = actual.with_suffix(".profile.json")
    if profile.exists():
        shutil.copyfile(profile, expected.with_suffix(".profile.json"))
    return expected
