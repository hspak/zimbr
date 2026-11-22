"""Fetch verified native packages for Zig build steps; never install into the host."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request


def verified(path, package):
    if not path.is_file() or path.stat().st_size != package["size"]:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == package["sha256"]


def fetch(package, cache):
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / (package["sha256"] + ".tar.zst")
    if verified(archive, package):
        return archive
    # Independent temporary downloads can run concurrently; publish only verified bytes.
    fd, name = tempfile.mkstemp(prefix="download-", dir=cache)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as output:
            with urllib.request.urlopen(package["url"], timeout=60) as response:
                size = 0
                while chunk := response.read(1024 * 1024):
                    size += len(chunk)
                    if size > package["size"]:
                        raise ValueError(f"Download exceeds pinned size: {package['url']}")
                    output.write(chunk)
        if not verified(temporary, package):
            raise ValueError(f"Download does not match pinned SHA-256/size: {package['url']}")
        temporary.replace(archive)
        return archive
    finally:
        temporary.unlink(missing_ok=True)


def provision(package, output, cache):
    archive = fetch(package, cache)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="extract-", dir=output.parent) as directory:
        extracted = Path(directory) / "package"
        # Python 3.14 provides zstd decompression; no host tar/zstd executable is needed.
        with tarfile.open(archive, "r:zst") as source:
            source.extractall(extracted, filter="data")
        (extracted / "zrct-package.json").write_text(json.dumps(package, indent=2) + "\n")
        # Zig supplies a fresh output directory (possibly already created but empty).
        if output.exists():
            output.rmdir()
        shutil.move(str(extracted), output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--tool", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    package = manifest["tools"][args.tool]
    base_cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    cache = Path(os.environ.get("ZRCT_TOOL_CACHE", base_cache / "zrct/downloads"))
    provision(package, args.output.resolve(), cache)


if __name__ == "__main__":
    main()
