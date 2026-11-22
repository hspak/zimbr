"""Every drawn app frame, bounded PNG checkpoints, VFR video encoded off the UI thread."""
import json
from pathlib import Path
import subprocess
import time

from .errors import ExpectationFailed, Unsupported, ZrctError
from .environment import executable


class Recording:
    def __init__(self, app, name=None):
        self.app = app
        self.directory = app.bundle.root / (name or f"recording-{time.monotonic_ns()}")
        self.frames = []
        self.complete = False
        self.active = False
        self.owns_capture = True
        self.first_frame = 0

    def start(self):
        existing = getattr(self.app, "recording", None)
        if existing and existing.active:
            self.directory = existing.directory
            self.started_ns, self.offset_ns, self.uncertainty_ns = existing.started_ns, existing.offset_ns, existing.uncertainty_ns
            self.first_frame = self.app.request("record_status")["frame_id"] + 1
            self.owns_capture = False
            self.active = True
            return self
        self.directory.mkdir()
        before = time.monotonic_ns()
        response = self.app.act("record_start", path=str(self.directory))
        after = time.monotonic_ns()
        self.started_ns = after
        self.offset_ns = (before + after) // 2 - response["time_ns"]
        self.uncertainty_ns = (after - before) // 2
        self.active = True
        self.app.recording = self
        return self

    def stop(self):
        if not self.active:
            return self
        self.active = False
        try:
            response = self.app.act("record_stop" if self.owns_capture else "record_status")
            self.complete = response["recording_complete"]
        except Exception as error:
            self.app.bundle.manifest["collection_errors"].append(f"recording interrupted: {error}")
        journal = self.directory / "frames.jsonl"
        if journal.exists():
            for line in journal.read_text().splitlines():
                try:
                    frame = json.loads(line)
                    if frame["frame_id"] >= self.first_frame:
                        self.frames.append(frame)
                except ValueError:
                    self.complete = False
            self.app.bundle.artifact(journal, "frames", complete=self.complete,
                                     clock_offset_ns=self.offset_ns, uncertainty_ns=self.uncertainty_ns,
                                     coverage="every completed app frame", max_frames=1200, max_bytes=512 * 1024 * 1024)
        if not self.frames:
            self.complete = False
            return self
        self.complete = self.complete and all(f["ok"] for f in self.frames) and all(
            b["frame_id"] == a["frame_id"] + 1 for a, b in zip(self.frames, self.frames[1:]))
        try:
            if self.owns_capture:
                self.encode()
        except Exception as error:
            self.app.bundle.manifest["collection_errors"].append(f"video encoding: {error}")
        return self

    def encode(self):
        ffmpeg, ffprobe = executable("ffmpeg"), executable("ffprobe")
        if not ffmpeg or not ffprobe:
            raise Unsupported("FFmpeg and ffprobe are required for video; PNG evidence was retained")
        valid = [frame for frame in self.frames if frame["ok"]]
        if not valid:
            return
        concat = self.directory / "frames.ffconcat"
        rows = ["ffconcat version 1.0"]
        for index, frame in enumerate(valid):
            rows.append(f"file '{frame['index']:06}.png'")
            rows.append("option framerate 1000")
            next_time = valid[index + 1]["time_ns"] if index + 1 < len(valid) else frame["time_ns"] + 100_000_000
            rows.append(f"duration {max(.001, (next_time-frame['time_ns'])/1e9):.9f}")
        rows.append(f"file '{valid[-1]['index']:06}.png'")
        rows.append("option framerate 1000")
        concat.write_text("\n".join(rows) + "\n")
        movie = self.directory / "recording.mp4"
        result = subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
                                 "-i", str(concat), "-fps_mode", "vfr", "-c:v", "libx264", "-crf", "20",
                                 "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p", str(movie)],
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            log = self.directory / "ffmpeg.stderr.log"
            log.write_text(result.stderr)
            self.app.bundle.artifact(log, "log")
            raise ZrctError("Video encoding failed", stderr=result.stderr[:4096])
        probe = subprocess.run([ffprobe, "-v", "error", "-show_streams", "-show_frames", "-of", "json", str(movie)],
                               capture_output=True, text=True, timeout=10, check=True)
        info = self.directory / "ffprobe.json"
        info.write_text(probe.stdout)
        self.app.bundle.artifact(info, "video_metadata")
        self.app.bundle.artifact(movie, "video", started_ns=valid[0]["time_ns"] + self.offset_ns,
                                 complete=self.complete, clock_offset_ns=self.offset_ns,
                                 uncertainty_ns=self.uncertainty_ns,
                                 capture_overhead_ns=sum(f["capture_ns"] for f in self.frames))

    def __enter__(self):
        return self.start()

    def __exit__(self, *error):
        self.stop()

    def expect_anchor(self, target_id, *, axis="y", tolerance=1, expected=None, require_every_frame=True, visual=False):
        if self.active:
            self.stop()
        with self.app.step(f"{target_id} {axis} anchor remains within {tolerance}px"):
            if require_every_frame and not self.complete:
                raise ExpectationFailed("Inconclusive temporal capture: missing frames", complete=False)
            if not self.frames:
                raise ExpectationFailed("Temporal capture contains no frames")
            anchor = expected
            for frame in self.frames:
                matches = [t for t in frame["targets"] if t["id"] == target_id and t["visible"]]
                if frame.get("truncated") or len(matches) > 1:
                    raise ExpectationFailed("Inconclusive temporal anchor: truncated or ambiguous targets",
                                            first_bad_frame=frame["frame_id"])
                target = matches[0] if matches else None
                observed = target["bounds"][axis] if target else None
                if anchor is None:
                    anchor = observed
                if observed is None or anchor is None or abs(observed - anchor) > tolerance:
                    evidence = self.directory / f"{frame['index']:06}.png"
                    self.app.bundle.artifact(evidence, "screenshot", frame_id=frame["frame_id"])
                    raise ExpectationFailed("Temporal anchor changed", expected=anchor, observed=observed,
                                            first_bad_frame=frame["frame_id"], screenshot=str(evidence),
                                            time_ns=frame["time_ns"])
            if visual:
                from .visual import dimensions
                first = self.frames[0]
                target = next(t for t in first["targets"] if t["id"] == target_id)
                bounds = target["bounds"]
                baseline = self.directory / f"{first['index']:06}.png"
                width, height = dimensions(baseline)
                window = first.get("window")
                if not window or window["width"] <= 0 or window["height"] <= 0:
                    raise ExpectationFailed("Inconclusive temporal capture: missing frame window geometry")
                if any(f.get("window") != window for f in self.frames):
                    raise ExpectationFailed("Inconclusive temporal visual capture: window geometry changed")
                clip = target.get("clip")
                if clip:
                    right = min(bounds["x"] + bounds["width"], clip["x"] + clip["width"])
                    bottom = min(bounds["y"] + bounds["height"], clip["y"] + clip["height"])
                    x, y = max(bounds["x"], clip["x"]), max(bounds["y"], clip["y"])
                    bounds = dict(x=x, y=y, width=max(0, right - x), height=max(0, bottom - y))
                sx, sy = width / window["width"], height / window["height"]
                region = (round(bounds["x"] * sx), round(bounds["y"] * sy),
                          round(bounds["width"] * sx), round(bounds["height"] * sy))
                self.expect_region(baseline, region)
            return anchor

    def expect_region(self, expected, region, *, masks=(), max_changed_pixels=0):
        from .visual import compare
        if self.active:
            self.stop()
        if not self.complete or not self.frames:
            raise ExpectationFailed("Inconclusive temporal visual capture")
        for frame in self.frames:
            try:
                compare(self.directory / f"{frame['index']:06}.png", expected, self.app.bundle,
                        name=f"frame-{frame['frame_id']}", region=region, masks=masks,
                        max_changed_pixels=max_changed_pixels)
            except ExpectationFailed as error:
                error.details["first_bad_frame"] = frame["frame_id"]
                raise


def extract_frame(recording, seconds, output):
    if seconds < 0:
        raise ValueError("Frame time must be nonnegative")
    recording, output = Path(recording).resolve(), Path(output).resolve()
    if recording.is_dir():
        frames = [json.loads(line) for line in (recording / "frames.jsonl").read_text().splitlines()]
        frames = [f for f in frames if f["ok"]]
        if not frames:
            raise ZrctError("No captured frames")
        chosen = min(frames, key=lambda f: abs((f["time_ns"] - frames[0]["time_ns"]) / 1e9 - seconds))
        import shutil
        shutil.copyfile(recording / f"{chosen['index']:06}.png", output)
    else:
        ffmpeg = executable("ffmpeg")
        if not ffmpeg:
            raise Unsupported("FFmpeg is missing")
        subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-ss", str(seconds),
                        "-i", str(recording), "-frames:v", "1", str(output)], timeout=10, check=True)
    return output
