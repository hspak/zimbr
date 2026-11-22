"""Crash-readable journals and one manifest for humans and automation."""
from contextlib import contextmanager
import html
import json
from pathlib import Path
import time
import traceback


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def write_junit(result, path):
    """Publish every attempted scenario, including unsupported and build failures."""
    from xml.etree.ElementTree import Element, SubElement, ElementTree
    suite = Element("testsuite", name="zrct", tests=str(len(result["results"])))
    counts = dict(failures=0, errors=0, skipped=0)
    for row in result["results"]:
        case = SubElement(suite, "testcase", name=row["scenario"], classname="zrct")
        status = row["status"]
        if status != "passed":
            kind = "skipped" if status == "unsupported_capability" else "failure" if status == "assertion_failure" else "error"
            counts[{"skipped": "skipped", "failure": "failures", "error": "errors"}[kind]] += 1
            message = str(row.get("error", status))
            message = "".join(c for c in message if c in "\t\n\r" or ord(c) >= 32)
            SubElement(case, kind, message=message, type=status)
        SubElement(case, "system-out").text = "\n".join(
            f"{key}: {row[key]}" for key in ("manifest", "report", "reproduction") if key in row)
    suite.attrib.update({k: str(v) for k, v in counts.items()})
    path = Path(path)
    temporary = path.with_suffix(".xml.tmp")
    ElementTree(suite).write(temporary, encoding="utf-8", xml_declaration=True)
    temporary.replace(path)
    return path


class Bundle:
    def __init__(self, root, scenario, reproduction, boundary="application_input"):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.manifest = dict(schema_version=1, scenario=scenario, status="running",
                             boundary=boundary, started_ns=time.monotonic_ns(),
                             reproduction=reproduction, steps=[], artifacts=[],
                             collection_errors=[], metadata={})
        self._deferred = 0
        self._events = []
        self.save()

    def save(self):
        if self._deferred:
            return
        atomic_json(self.root / "manifest.json", self.manifest)

    def input_contract(self, declared, required):
        self.manifest.update(declared_boundary=declared, required_boundaries=sorted(required),
                             observed_boundaries=[], boundary="none")
        self.save()

    def observe_boundary(self, boundary, *, operation):
        observed = self.manifest.setdefault("observed_boundaries", [])
        new_boundary = boundary not in observed
        if new_boundary:
            observed.append(boundary)
            observed.sort()
        self.manifest["boundary"] = "+".join(observed) or "none"
        self.event("input_boundary", boundary=boundary, operation=operation)
        if new_boundary:
            self.save()

    def validate_boundaries(self):
        from .errors import Unsupported
        missing = set(self.manifest.get("required_boundaries", ())) - set(self.manifest.get("observed_boundaries", ()))
        if missing:
            raise Unsupported(f"Required input boundaries were not exercised: {', '.join(sorted(missing))}",
                              observed=self.manifest.get("observed_boundaries", []))

    @contextmanager
    def defer_writes(self):
        """Keep the measured path free of journal/manifest disk writes."""
        self._deferred += 1
        try:
            yield
        finally:
            self._deferred -= 1
            if not self._deferred:
                with (self.root / "events.jsonl").open("a") as stream:
                    stream.writelines(self._events)
                self._events.clear()
                self.save()

    def event(self, kind, **data):
        """Append crash-readable evidence; manifest mutations checkpoint explicitly."""
        line = json.dumps(dict(kind=kind, time_ns=time.monotonic_ns(), **data), ensure_ascii=False) + "\n"
        if self._deferred:
            if len(self._events) >= 8192:
                raise RuntimeError("Deferred benchmark journal exceeded 8192 events")
            self._events.append(line)
            return
        with (self.root / "events.jsonl").open("a") as stream:
            stream.write(line)
            stream.flush()

    def artifact(self, path, kind, **data):
        path = Path(path).resolve()
        relative = str(path.relative_to(self.root))
        entry = dict(path=relative, kind=kind, **data)
        if not any(item["path"] == relative for item in self.manifest["artifacts"]):
            self.manifest["artifacts"].append(entry)
            self.save()
        return path

    @contextmanager
    def step(self, name, **details):
        step = dict(name=name, started_ns=time.monotonic_ns(), status="running", **details)
        self.manifest["steps"].append(step)
        self.event("step_started", step=step)
        self.save()
        try:
            yield step
        except BaseException as error:
            step.update(status="failed", error=str(error),
                        details=getattr(error, "details", {}))
            self.manifest.setdefault("first_failed_step", name)
            raise
        else:
            step["status"] = "passed"
        finally:
            step["ended_ns"] = time.monotonic_ns()
            self.event("step_finished", step=step)
            self.save()

    def finish(self, error=None):
        if "observed_boundaries" in self.manifest:
            self.manifest["boundary"] = "+".join(self.manifest["observed_boundaries"]) or "none"
        self.manifest["ended_ns"] = time.monotonic_ns()
        if error is None:
            self.manifest["status"] = "passed"
        else:
            category = getattr(error, "category", "assertion_failure" if isinstance(error, AssertionError)
                               else "infrastructure_failure")
            self.manifest.update(status=category, error=str(error),
                                 details=getattr(error, "details", {}))
            self.manifest.setdefault("first_failed_step", self.manifest["scenario"])
            (self.root / "traceback.txt").write_text("".join(traceback.format_exception(error)))
            self.artifact(self.root / "traceback.txt", "log")
        self.save()
        render_report(self.root)
        return self.manifest


def render_report(root):
    root = Path(root).resolve()
    data = json.loads((root / "manifest.json").read_text())
    esc = html.escape
    parts = ["<!doctype html><html lang=en><meta charset=utf-8>",
             "<meta name=viewport content='width=device-width,initial-scale=1'>",
             "<title>Zrct report</title><style>body{font:16px system-ui;max-width:1100px;",
             "margin:2rem auto;padding:0 1rem;background:#141820;color:#e1e6ed}",
             "a{color:#8ac8ff}pre{white-space:pre-wrap;overflow-wrap:anywhere}",
             "img,video{max-width:100%}li{margin:.5em 0}.failed{color:#ffa7a7}</style>",
             f"<h1>{esc(data['scenario'])}</h1><p>{esc(data['status'])} · {esc(data['boundary'])}</p>",
             f"<pre>{esc(data.get('reproduction', ''))}</pre>"]
    if "observed_boundaries" in data:
        parts.append(f"<p>Required input boundaries: {esc(', '.join(data.get('required_boundaries', [])) or 'none')}. "
                     f"Observed input boundaries: {esc(', '.join(data['observed_boundaries']) or 'none')}.</p>")
    if data.get("error"):
        parts.append(f"<pre class=failed>{esc(data['error'])}</pre>")
    parts.append("<ol>")
    recording = next((a for a in data["artifacts"] if a["kind"] == "video"), None)
    for step in data["steps"]:
        seek = ""
        if recording:
            seconds = max(0, (step["started_ns"] - recording["started_ns"]) / 1e9)
            seek = f' <button data-seek="{seconds:.3f}">video</button>'
        parts.append(f"<li>{esc(step['name'])} — {esc(step['status'])}{seek}")
        if "error" in step:
            parts.append(f"<pre>{esc(step['error'])}</pre>")
        parts.append("</li>")
    parts.append("</ol>")
    for item in data["artifacts"]:
        # Refuse links outside the bundle, including malicious manually edited manifests.
        path = Path(item["path"])
        if path.is_absolute() or ".." in path.parts:
            continue
        link = esc(path.as_posix(), quote=True)
        parts.append(f'<p><a href="{link}">{esc(item["kind"])}: {link}</a></p>')
        if item["kind"] in ("screenshot", "diff", "crop", "baseline", "mask"):
            parts.append(f'<a href="{link}"><img loading=lazy src="{link}" alt="{link}"></a>')
        if item["kind"] == "video":
            parts.append(f'<video id=recording controls preload=metadata src="{link}"></video>')
    if data["collection_errors"]:
        parts.append(f"<pre>Evidence collection: {esc(str(data['collection_errors']))}</pre>")
    parts.append("<details><summary>Environment and result</summary><pre>" +
                 esc(json.dumps(data, indent=2, ensure_ascii=False)) + "</pre></details>")
    parts.append("<script>document.querySelectorAll('[data-seek]').forEach(b=>b.onclick=()=>{"
                 "const v=document.getElementById('recording');v.currentTime=Number(b.dataset.seek);"
                 "v.scrollIntoView({block:'center'});});</script></html>")
    (root / "report.html").write_text("\n".join(parts))
    return root / "report.html"
