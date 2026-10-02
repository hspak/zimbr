#!/usr/bin/env python3
"""Repeat the synthetic production-renderer benchmark on the current Wayland desktop."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WORKLOADS = ("cached", "scroll", "cold_text", "image_upload", "rich_anchor", "caret", "reflow",
             "resize_width", "resize_height")


def command_output(command):
    try:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=15)
        return dict(code=result.returncode, stdout=result.stdout, stderr=result.stderr)
    except (OSError, subprocess.TimeoutExpired) as error:
        return dict(error=str(error))


def distribution(values):
    ordered = sorted(values)
    return dict(mean=statistics.mean(ordered),
                **{f"p{percent}": ordered[math.ceil(len(ordered) * percent / 100) - 1]
                   for percent in (50, 95, 99)}, maximum=ordered[-1])


def summarize(records):
    result = {}
    for record in records[1:]:
        samples = record["frames"]
        total = [(sample["draw_ns"] + sample["present_ns"]) / 1e6 for sample in samples]
        result[record["name"]] = dict(
            frames=len(samples), frame_ms=distribution(total),
            interval_ms=distribution([sample["interval_ns"] / 1e6 for sample in samples]),
            draw_ms=distribution([sample["draw_ns"] / 1e6 for sample in samples]),
            present_ms=distribution([sample["present_ns"] / 1e6 for sample in samples]),
            cpu_ms=distribution([sample["cpu_ns"] / 1e6 for sample in samples]),
            over_120hz_budget_percent=100 * sum(value > 1000 / 120 for value in total) / len(total))
        if record["name"] == "reflow":
            cycles, current = [], None
            for sample in samples:
                if sample["reflow_started"]:
                    current = []
                if current is not None:
                    current.append(sample)
                    if not sample["layout_pending"]:
                        assert sample["measured_rows"] == 1000
                        cycles.append(current)
                        current = None
            if cycles:
                result[record["name"]]["convergence"] = dict(
                    cycles=len(cycles), frames=distribution([len(cycle) for cycle in cycles]),
                    work_ms=distribution([sum(s["draw_ns"] + s["present_ns"] for s in cycle) / 1e6
                                          for cycle in cycles]))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "zig-out/bin/render-bench")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--drivers", nargs="+", choices=("opengl", "vulkan", "gpu", "default"),
                        default=("opengl", "vulkan"))
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--frames", type=int, default=600)
    parser.add_argument("--pacing", choices=("unpaced", "vsync", "timer", "capped_vsync"), default="unpaced",
                        help="throughput, renderer VSync, a display-rate timer, or both")
    parser.add_argument("--workload", choices=("all", *WORKLOADS),
                        default="all", help="isolate one workload for timing or CPU profiling")
    parser.add_argument("--avatars", choices=("shared", "distinct"), default="shared",
                        help="shared initials stress colored-glyph reuse; distinct initials isolate it")
    args = parser.parse_args()
    if args.runs < 1 or not 100 <= args.frames <= 100000:
        parser.error("runs must be positive and frames must be between 100 and 100000")
    binary = args.binary.resolve(strict=True)
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = dict(
        created_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        binary=str(binary), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        revision=command_output(["git", "rev-parse", "HEAD"]),
        diff=command_output(["git", "diff", "--stat"]), platform=platform.platform(),
        cpu=command_output(["lscpu"]), vulkan=command_output(["vulkaninfo", "--summary"]),
        graphics_environment={key: value for key, value in os.environ.items()
                              if key.startswith(("SDL_", "VK_", "MESA_", "GALLIUM_", "LIBGL_", "LD_"))},
        runs=args.runs, frames=args.frames, avatars=args.avatars, workload=args.workload,
        pacing=args.pacing,
        timing="CPU wall time through SDL_RenderPresent and frame start intervals; not GPU timestamps or display latency")
    (args.output / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    summaries = []
    for repeat in range(args.runs):
        # Alternate driver order to reduce systematic warm-up and thermal bias.
        drivers = args.drivers if repeat % 2 == 0 else list(reversed(args.drivers))
        for driver in drivers:
            name = f"{repeat + 1:02}-{driver}"
            env = os.environ.copy()
            if driver == "default":
                env.pop("SDL_RENDER_DRIVER", None)
            else:
                env["SDL_RENDER_DRIVER"] = driver
            if driver == "gpu":
                env["SDL_GPU_DRIVER"] = "vulkan"
            print(f"Running {name} ({args.frames} frames per workload)", flush=True)
            with (args.output / f"{name}.jsonl").open("w") as out, \
                    (args.output / f"{name}.stderr.log").open("w") as err:
                command = [str(binary), str(args.frames), args.avatars, args.workload, args.pacing]
                process = subprocess.run(command, env=env,
                                         stdout=out, stderr=err, timeout=600)
            errors = (args.output / f"{name}.stderr.log").read_text()
            if process.returncode or "error:" in errors or "error(" in errors:
                raise RuntimeError(f"{name} failed ({process.returncode}): {errors}")
            records = [json.loads(line) for line in (args.output / f"{name}.jsonl").read_text().splitlines()]
            workloads = (set(WORKLOADS) if args.workload == "all"
                         else {args.workload})
            assert len(records) == len(workloads) + 1 and records[0]["kind"] == "metadata", records
            header = records[0]
            assert driver == "default" or header["renderer"] == driver, header
            if driver == "gpu":
                assert header["gpu_driver"] == "vulkan", header
            assert header["vsync"] == int(args.pacing in ("vsync", "capped_vsync")) and header["optimize"] != "Debug", header
            assert header["pacing"] == args.pacing, header
            assert header["avatars"] == args.avatars, header
            if summaries:
                assert header["window"] == summaries[0]["metadata"]["window"], "Window geometry changed"
            assert {record["name"] for record in records[1:]} == workloads
            assert all(len(record["frames"]) == args.frames for record in records[1:])
            for record in records[1:]:
                if record["name"] in ("resize_width", "resize_height"):
                    widths = {s["width"] for s in record["frames"]}
                    heights = {s["height"] for s in record["frames"]}
                    if record["name"] == "resize_width":
                        assert len(widths) > 1 and len(heights) == 1, "Width resize did not reach the window"
                    else:
                        assert len(heights) > 1 and len(widths) == 1, "Height resize did not reach the window"
            summary = dict(run=repeat + 1, requested=driver, metadata=header,
                           workloads=summarize(records))
            summaries.append(summary)
            (args.output / "summary.json").write_text(json.dumps(summaries, indent=2) + "\n")
            for workload, metrics in summary["workloads"].items():
                wall = metrics["frame_ms"]
                print(f"  {workload:12} p50 {wall['p50']:.3f} ms  p95 {wall['p95']:.3f} ms  "
                      f"p99 {wall['p99']:.3f} ms  CPU mean {metrics['cpu_ms']['mean']:.3f} ms",
                      flush=True)
                interval = metrics["interval_ms"]
                print(f"    frame intervals: p50 {interval['p50']:.3f} ms  p95 {interval['p95']:.3f} ms  "
                      f"p99 {interval['p99']:.3f} ms", flush=True)


if __name__ == "__main__":
    main()
