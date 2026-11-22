"""Launch Python with the exact native tools produced by the Zig dependency graph."""
import argparse
import os
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uv", type=Path, required=True)
    for name in ("weston", "ffmpeg", "imagemagick"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("pass Python arguments after --")
    weston, ffmpeg, magick = (getattr(args, name).resolve() / "usr"
                              for name in ("weston", "ffmpeg", "imagemagick"))
    env = os.environ.copy()
    env.update(ZRCT_UV=str(args.uv.resolve()),
               ZRCT_WESTON=str(weston / "bin/weston"), ZRCT_WESTON_PREFIX=str(weston),
               ZRCT_FFMPEG=str(ffmpeg / "bin/ffmpeg"), ZRCT_FFPROBE=str(ffmpeg / "bin/ffprobe"),
               ZRCT_MAGICK=str(magick / "bin/magick"),
               MAGICK_CONFIGURE_PATH=str(args.imagemagick.resolve() / "etc/ImageMagick-7"))
    modules, = (magick / "lib").glob("ImageMagick-*/modules-*")
    env["MAGICK_CODER_MODULE_PATH"] = str(modules / "coders")
    env["MAGICK_FILTER_MODULE_PATH"] = str(modules / "filters")
    libraries = [str(prefix / "lib") for prefix in (weston, ffmpeg, magick)]
    libraries.append(str(weston / "lib/weston"))
    env["LD_LIBRARY_PATH"] = os.pathsep.join(libraries + ([env["LD_LIBRARY_PATH"]] if env.get("LD_LIBRARY_PATH") else []))
    bins = [str(args.uv.resolve().parent), *(str(prefix / "bin") for prefix in (weston, ffmpeg, magick))]
    env["PATH"] = os.pathsep.join(bins + [env.get("PATH", os.defpath)])
    env["ZRCT_MANAGED_TOOLS"] = "1"
    os.execve(sys.executable, [sys.executable, *command], env)


if __name__ == "__main__":
    main()
