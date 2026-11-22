#!/usr/bin/env python3
"""Build the explicitly versioned Weston 15 test module and Wayland drop client."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import shutil

root = Path(__file__).resolve().parent
prefix = Path(os.environ.get("ZRCT_WESTON_PREFIX", "/usr"))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=Path, default=Path(os.environ.get("ZRCT_PLATFORM_DIR", root.parent / "zig-out/lib")))
output = parser.parse_args().output.resolve()
output.mkdir(parents=True, exist_ok=True)

def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def identity(dependencies):
    paths = [__file__, *root.glob("*.c"), *root.glob("*.h"),
             "/usr/share/wayland-protocols/staging/fractional-scale/fractional-scale-v1.xml",
             "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml", *dependencies]
    paths += [shutil.which(tool) for tool in ("cc", "wayland-scanner", "pkg-config")]
    packages = ["wayland-server", "wayland-client", "xkbcommon", "pixman-1", "libdrm"]
    return dict(files={str(path): digest(path) for path in paths}, prefix=str(prefix.resolve()),
                flags=subprocess.check_output(["pkg-config", "--cflags", "--libs", *packages], text=True),
                versions=subprocess.check_output(["pkg-config", "--modversion", *packages], text=True))


# Multiple Zig invocations can share this directory. Never expose a partially
# rebuilt helper to another invocation, and do not reuse missing/modified outputs.
lock = (output / ".build.lock").open("a")
fcntl.flock(lock, fcntl.LOCK_EX)
stamp = output / "build.json"
try:
    cached = json.loads(stamp.read_text())
    if cached["identity"] == identity(cached["dependencies"]) and all(
            digest(output / name) == value for name, value in cached["outputs"].items()):
        raise SystemExit(0)
except (OSError, ValueError, KeyError):
    pass

def compile_sources(sources, flags):
    objects = []
    for source in sources:
        obj = output / (Path(source).stem + ".o")
        subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-O2",
                        *flags, "-MD", "-MF", str(obj.with_suffix(".d")),
                        "-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    return objects


def link(arguments, name):
    # Running scenarios can dlopen/exec these paths while another build runs.
    # Replacing the inode keeps both new readers and existing mappings intact.
    temporary = output / (name + ".tmp")
    try:
        subprocess.run(["cc", *arguments, "-o", str(temporary)], check=True)
        temporary.replace(output / name)
    finally:
        temporary.unlink(missing_ok=True)


scale_protocol = Path("/usr/share/wayland-protocols/staging/fractional-scale/fractional-scale-v1.xml")
scale_header = output / "fractional-scale-v1-server-protocol.h"
scale_source = output / "fractional-scale-v1-protocol.c"
for mode, destination in (("server-header", scale_header), ("private-code", scale_source)):
    subprocess.run(["wayland-scanner", mode, str(scale_protocol), str(destination)], check=True)
flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "wayland-server", "xkbcommon", "pixman-1", "libdrm"], text=True))
objects = compile_sources([root / "weston_input.c", root / "weston_scale.c", scale_source],
                          ["-fPIC", f"-I{prefix}/include/libweston-15", f"-I{output}",
                           *shlex.split(subprocess.check_output(["pkg-config", "--cflags", "wayland-server", "xkbcommon", "pixman-1", "libdrm"], text=True))])
link(["-shared", *objects, f"-L{prefix}/lib", "-lweston-15", *flags], "zrct-weston-input.so")
print(output / "zrct-weston-input.so")
protocol = Path("/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml")
header = output / "xdg-shell-client-protocol.h"
source = output / "xdg-shell-protocol.c"
for mode, destination in (("client-header", header), ("private-code", source)):
    subprocess.run(["wayland-scanner", mode, str(protocol), str(destination)], check=True)
objects = compile_sources([root / "drop_client.c", source], [f"-I{output}"])
link([*objects, "-lwayland-client"], "zrct-drop-client")

# -MD includes system headers as well as the explicitly versioned Weston headers.
# Generated files in this output directory are recreated from the hashed XML.
dependencies = set()
for depfile in output.glob("*.d"):
    text = depfile.read_text().replace("\\\n", " ")
    for name in shlex.split(text.split(":", 1)[1]):
        path = Path(name).resolve()
        if not path.is_relative_to(output):
            dependencies.add(str(path))
outputs = {path.name: digest(path) for path in output.iterdir()
           if path.is_file() and path.suffix in (".so", ".h", ".c", ".d")}
outputs["zrct-drop-client"] = digest(output / "zrct-drop-client")
value = dict(identity=identity(sorted(dependencies)), dependencies=sorted(dependencies), outputs=outputs)
temporary = stamp.with_suffix(".tmp")
temporary.write_text(json.dumps(value))
temporary.replace(stamp)
