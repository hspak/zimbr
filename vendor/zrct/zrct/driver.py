from contextlib import nullcontext
from copy import deepcopy
import hashlib
import json
import math
from pathlib import Path
import time
import warnings

from .artifacts import atomic_json
from .errors import ExpectationFailed, MissingTarget, Unsupported, ProtocolError, DeadlineExceeded
from .protocol import Connection
from .keys import KEYS, chord_names

_UNSET = object()
_INPUT_OPERATIONS = frozenset(("click", "double_click", "press", "key_down", "key_up",
                              "key_repeat", "type_text", "text_editing", "drag", "scroll", "drop"))
_PROPERTIES = frozenset(("id", "role", "label", "bounds", "clip", "parent", "enabled",
                         "selected", "expanded", "visible", "obscured", "status", "value", "interactive"))
_TEXT_FIELDS = frozenset(("label", "status", "value"))


class App:
    def __init__(self, socket, *, bundle=None, process=None, timeout=5, relaunch=None, before_close=None, health=None):
        self.connection = Connection(socket, timeout)
        self.bundle, self.process, self.timeout, self.relaunch = bundle, process, timeout, relaunch
        self.last = None
        self.before_close, self.health_check = before_close, health
        self.hello_before = time.monotonic_ns()
        self.handshake = self.connection.request("hello")
        self.hello_after = time.monotonic_ns()
        self.capabilities = set(self.handshake["operations"])
        if bundle:
            bundle.manifest["metadata"]["application"] = self.handshake
            bundle.save()

    def health(self):
        if self.health_check:
            self.health_check()
        if self.process:
            self.process.check()

    def request(self, operation, **params):
        self.health()
        if operation not in self.capabilities:
            raise Unsupported(f"{operation} is not supported by this application")
        deadline = getattr(self, "_expectation_deadline", None)
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DeadlineExceeded("Expectation deadline exceeded", operation=operation)
            params["timeout"] = min(params.get("timeout") or self.connection.timeout, remaining)
        try:
            result = self.connection.request(operation, **params)
        except Exception:
            self.health()
            raise
        if self.bundle and operation in _INPUT_OPERATIONS:
            boundary = self.handshake.get("drop_boundary" if operation == "drop" else "boundary", "application_input")
            self.bundle.observe_boundary(boundary, operation=operation)
        return result

    def step(self, name, **details):
        return self.bundle.step(name, **details) if self.bundle else nullcontext({})

    def inspect(self, *, id=None, role=None, text=None, text_contains=None, within=None):
        if text is not None and text_contains is not None:
            raise ValueError("Use either text (exact label) or text_contains (substring)")
        substring = text if text is not None else text_contains
        # Native query matches previews. Send an exact query's bounded prefix,
        # then compare the full value (or its digest) locally in the same frame.
        wire_text = text.encode()[:4096].decode("utf-8", errors="ignore") if text is not None else text_contains
        digest = hashlib.sha256(text.encode()).hexdigest() if text is not None else None
        query = {key: value for key, value in dict(id=id, role=role, text=wire_text, within=within).items()
                 if value is not None}
        filtered = bool(query) and "query" in self.capabilities
        self.last = self.request("query", query=query) if filtered else self.request("inspect")
        if self.last.get("truncated"):
            raise ProtocolError("Semantic snapshot is incomplete", frame_id=self.last.get("frame_id"))
        targets = self.last["targets"]
        if not filtered and within:
            parents = {within}
            while True:
                expanded = parents | {t["id"] for t in targets if t.get("parent") in parents}
                if expanded == parents:
                    break
                parents = expanded
            targets = [t for t in targets if t.get("parent") in parents]
        def label_matches(target):
            if text is None:
                return substring is None or substring in target.get("label", "")
            info = target.get("strings", {}).get("label", {})
            return info.get("sha256") == digest if info.get("truncated") else target.get("label") == text
        return [t for t in targets if (id is None or t["id"] == id)
                and (role is None or t["role"] == role)
                and label_matches(t)]

    def target(self, id=None, *, role=None, text=None, text_contains=None, within=None):
        if text is not None and text_contains is not None:
            raise ValueError("Use either text (exact label) or text_contains (substring)")
        return Target(self, dict(id=id, role=role, text=text, text_contains=text_contains, within=within))

    def targets(self, id=None, *, role=None, text=None, text_contains=None, within=None):
        """Explicit collection assertions over registered targets in the current snapshot."""
        return Targets(self, self.target(id, role=role, text=text, text_contains=text_contains, within=within).query)

    def expect(self, condition, predicate, *, timeout=None):
        timeout = self.timeout if timeout is None else timeout
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("timeout must be finite and positive")
        previous = getattr(self, "_expectation_deadline", None)
        deadline = time.monotonic() + timeout
        if previous is not None:
            deadline = min(deadline, previous)
        with self.step(condition):
            self._expectation_deadline = deadline
            try:
                def timed_out():
                    return ExpectationFailed(f"Timed out: {condition}", expected=condition,
                                             observed=self.last, frame_id=(self.last or {}).get("frame_id"),
                                             process_status=self.process.child.poll() if self.process else None)
                while True:
                    self.health()
                    if time.monotonic() >= deadline:
                        raise timed_out()
                    try:
                        last = predicate()
                    except MissingTarget:
                        last = None
                    except DeadlineExceeded:
                        if time.monotonic() >= deadline:
                            raise timed_out() from None
                        raise
                    remaining = deadline - time.monotonic()
                    if remaining < 0:
                        raise timed_out()
                    if last:
                        return last
                    time.sleep(min(.025, remaining))
            finally:
                self._expectation_deadline = previous

    def act(self, operation, **params):
        with self.step(f"{operation} {params.get('target', '')}".strip(), arguments=params) as step:
            result = self.request(operation, **params)
            step["result"] = result
            return result

    def press(self, chord):
        chord_names(chord)
        return self.act("press", text=chord)

    @property
    def keys(self):
        return tuple(k["name"] for k in self.handshake.get("keys", [])) or tuple(KEYS)

    def key_down(self, chord):
        chord_names(chord)
        return self.act("key_down", text=chord)

    def key_up(self, chord):
        names = chord_names(chord)
        return self.act("key_up", text="+".join(reversed(names)))

    def key_repeat(self, key):
        chord_names(key)
        return self.act("key_repeat", text=key)

    def text_editing(self, text, *, start=0, length=0):
        """Deliver SDL preedit (empty text cancels); this does not exercise a system IME."""
        return self.act("text_editing", text=text, start=start, length=length)

    def expect_always(self, condition, predicate, *, duration, interval=.025, timeout=None):
        """Sample an invariant through the entire window, including its final boundary."""
        if not math.isfinite(duration) or duration <= 0 or not math.isfinite(interval) or interval <= 0:
            raise ValueError("duration and interval must be finite and positive")
        if timeout is not None and (not math.isfinite(timeout) or timeout < duration):
            raise ValueError("timeout must be finite and at least the observation duration")
        with self.step(condition, assertion="invariant", duration=duration, interval=interval) as step:
            started = time.monotonic()
            samples = 0
            while True:
                self.health()
                samples += 1
                try:
                    value = predicate()
                except ExpectationFailed as error:
                    elapsed = time.monotonic() - started
                    error.details.update(elapsed=elapsed, sample=samples)
                    step.update(samples=samples, elapsed=elapsed, observed=error.details.get("observed"))
                    raise
                self.health()
                elapsed = time.monotonic() - started
                step.update(samples=samples, elapsed=elapsed, observed=value)
                if not value:
                    raise ExpectationFailed(f"Invariant violated: {condition}", expected=condition,
                                            observed=value, elapsed=elapsed, sample=samples,
                                            frame_id=(self.last or {}).get("frame_id"))
                if timeout is not None and elapsed > timeout:
                    raise ExpectationFailed(f"Observation deadline exceeded: {condition}",
                                            duration=duration, elapsed=elapsed, samples=samples)
                if elapsed >= duration:
                    return value
                time.sleep(min(interval, duration - elapsed))

    def expect_unchanged(self, condition, observe, *, duration, interval=.025, timeout=None, expected=_UNSET):
        self.health()
        initial = deepcopy(observe() if expected is _UNSET else expected)
        with self.step(condition, assertion="unchanged", expected=initial) as step:
            def unchanged():
                value = deepcopy(observe())
                step["observed"] = value
                if value != initial:
                    raise ExpectationFailed(f"Value changed: {condition}", expected=initial, observed=value)
                return True
            return self.expect_always(condition, unchanged, duration=duration, interval=interval, timeout=timeout)

    def expect_count(self, condition, count, expected, *, duration, timeout=None, interval=.025):
        """Wait for a cumulative event count, then detect duplicates throughout duration."""
        def reached():
            observed = count()
            if observed > expected:
                raise ExpectationFailed(f"Too many events: {condition}", expected=expected, observed=observed)
            return observed == expected
        self.expect(condition, reached, timeout=timeout)
        return self.expect_unchanged(condition, count, expected=expected, duration=duration, interval=interval)

    def expect_drawing_idle(self, *, quiet=.2, timeout=5):
        """Observe no completed drawing for a quiet interval; this is not network readiness."""
        if not math.isfinite(quiet) or quiet <= 0:
            raise ValueError("quiet must be finite and positive")
        frame, changed = None, time.monotonic()
        def idle():
            nonlocal frame, changed
            self.inspect()
            current = self.last["frame_id"]
            if current != frame:
                frame, changed = current, time.monotonic()
            return time.monotonic() - changed >= quiet
        return self.expect(f"drawing becomes idle for {quiet:g}s", idle, timeout=timeout)

    def expect_idle(self, **kwargs):
        warnings.warn("Use expect_drawing_idle(); drawing inactivity does not establish network readiness",
                      DeprecationWarning, stacklevel=2)
        return self.expect_drawing_idle(**kwargs)

    def type_text(self, text):
        return self.act("type_text", text=text)

    def resize(self, width, height):
        return self.act("resize", width=width, height=height)

    def screenshot(self, path=None, *, target=""):
        if path is None:
            if not self.bundle:
                raise ValueError("A screenshot path is required outside a run")
            path = self.bundle.root / f"frame-{time.monotonic_ns()}.png"
        path = Path(path).resolve()
        result = self.act("screenshot", path=str(path), target=target)
        self.last_capture = result
        if not path.is_file():
            raise ProtocolError("Application acknowledged capture without producing a PNG")
        if self.bundle:
            self.bundle.artifact(path, "screenshot", **result)
        return path

    def capture_failure(self):
        if not self.bundle:
            return
        self.connection.timeout = min(self.connection.timeout, 1)
        for name, operation in (("snapshot", lambda: self.inspect()),
                                ("screenshot", lambda: self.screenshot(self.bundle.root / "failure.png"))):
            try:
                operation()
                if name == "snapshot":
                    atomic_json(self.bundle.root / "failure-ui.json", self.last)
                    self.bundle.artifact(self.bundle.root / "failure-ui.json", "snapshot")
            except Exception as error:
                self.bundle.manifest["collection_errors"].append(f"{name}: {error}")
        self.bundle.save()

    def restart(self):
        if not self.relaunch:
            raise Unsupported("Session does not provide restart")
        with self.step("restart application"):
            self.close()
            self.process.wait(3)
            replacement = self.relaunch()
            self.__dict__.update(replacement.__dict__)
        return self

    def close(self):
        if self.before_close:
            self.before_close()
        return self.act("close")


class Target:
    def __init__(self, app, query):
        self.app, self.query = app, query

    def _find(self):
        targets = self.app.inspect(**self.query)
        if len(targets) > 1:
            raise ExpectationFailed(f"Expected one target {self.query}; found {len(targets)}",
                                    expected=self.query, observed=targets)
        return targets[0] if targets else None

    def resolve(self):
        target = self._find()
        if target is None:
            raise MissingTarget(f"No target matches {self.query}", expected=self.query, observed=[])
        return target

    def action_now(self, operation, **params):
        """Resolve once and send once; the server still enforces hit testing."""
        target = self.resolve()
        return self.app.act(operation, target=target["id"], frame_id=self.app.last["frame_id"], **params)

    def action(self, operation, *, timeout=None, **params):
        """Wait only for preconditions. Never retry input after sending it."""
        endpoint = params.pop("to_target", None)
        if endpoint is not None:
            endpoint = endpoint if isinstance(endpoint, Target) else self.app.target(endpoint)
            if endpoint.app is not self.app:
                raise ValueError("Drag endpoints must belong to the same application")
        def ready():
            source = self._ready(scroll=operation == "scroll")
            if source is None:
                return None
            if endpoint is not None:
                destination = endpoint._ready()
                if destination is None:
                    return None
                source["to_target"] = destination["target"]
                source["frame_id"] = destination["frame_id"]
            return source
        resolved = self.app.expect(f"target {self.query} ready for {operation}", ready, timeout=timeout)
        return self.app.act(operation, **resolved, **params)

    def click(self, *, timeout=None):
        return self.action("click", timeout=timeout)

    def click_now(self):
        return self.action_now("click")

    def double_click(self, *, timeout=None):
        return self.action("double_click", timeout=timeout)

    def type_text(self, text, *, timeout=None):
        self.click(timeout=timeout)
        return self.app.type_text(text)

    def scroll(self, dy, dx=0, modifiers="", *, timeout=None):
        return self.action("scroll", dy=dy, dx=dx, text=modifiers, timeout=timeout)

    def drag(self, dx, dy, frames=8, modifiers="", *, timeout=None):
        return self.action("drag", dx=dx, dy=dy, frames=frames, text=modifiers, timeout=timeout)

    def drag_to(self, target, *, frames=8, modifiers="", timeout=None):
        return self.action("drag", to_target=target, frames=frames, text=modifiers, timeout=timeout)

    def read_text(self, field="value", *, max_bytes=65536):
        """Read complete content from the current snapshot, or fail explicitly at the bound."""
        if field not in _TEXT_FIELDS:
            raise ValueError(f"Unknown text field: {field}")
        target = self.resolve()
        result = self.app.request("content", target=target["id"], field=field, max_bytes=max_bytes)
        return result["text"]

    def expect_digest(self, digest, *, field="value", timeout=None):
        if field not in _TEXT_FIELDS:
            raise ValueError(f"Unknown text field: {field}")
        if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
            raise ValueError("digest must be a lowercase SHA-256 hex string")
        def matches():
            target = self._find()
            if target is None or field not in target:
                return False
            info = target.get("strings", {}).get(field, {})
            actual = info.get("sha256") if info.get("truncated") else hashlib.sha256(target[field].encode()).hexdigest()
            return actual == digest
        return self.app.expect(f"target {self.query} {field} SHA-256 is {digest}", matches, timeout=timeout)

    def hit_point(self):
        target = self.resolve()
        return self.app.request("resolve", target=target["id"])["point"]

    def _ready(self, *, scroll=False):
        target = self._find()
        if target is None:
            return None
        try:
            resolved = self.app.request("resolve_scroll" if scroll else "resolve", target=target["id"])
            self._point = resolved["point"]
            return dict(target=target["id"], frame_id=resolved["frame_id"])
        except ProtocolError as error:
            if error.details.get("code") != "target" or str(error) not in (
                    "MissingTarget", "DisabledTarget", "OffscreenTarget", "ObscuredTarget"):
                raise
            self.app.last["hit_test_failure"] = str(error)
            return None

    def _interactable(self):
        return self._point if self._ready() is not None else False

    def expect_interactable(self, *, timeout=None):
        return self.app.expect(f"target {self.query} has an unobscured hit region", self._interactable, timeout=timeout)

    def expect_fully_visible(self, *, timeout=None):
        def visible():
            target = self._find()
            return target is not None and self._fully_visible(target)
        return self.app.expect(f"target {self.query} is fully visible", visible, timeout=timeout)

    @staticmethod
    def _fully_visible(target):
        if not target.get("visible") or target.get("obscured"):
            return False
        box, clip = target["bounds"], target.get("clip") or target["bounds"]
        return (box["x"] >= clip["x"] and box["y"] >= clip["y"]
                and box["x"] + box["width"] <= clip["x"] + clip["width"]
                and box["y"] + box["height"] <= clip["y"] + clip["height"])

    def drop(self, paths, *, timeout=None):
        return self.action("drop", paths=[str(Path(p).resolve()) for p in paths], timeout=timeout)

    def expect_visible(self, *, timeout=None):
        return self.app.expect(f"target {self.query} is visible",
                               lambda: (self._find() or {}).get("visible", False), timeout=timeout)

    def expect_absent_from_snapshot(self, *, timeout=None):
        """Absence from registration does not establish absence from application data."""
        return self.app.expect(f"target {self.query} is absent from snapshot",
                               lambda: not self.app.inspect(**self.query), timeout=timeout)

    def expect_absent(self, **kwargs):
        warnings.warn("Use expect_absent_from_snapshot(); virtualized items may still exist in application data",
                      DeprecationWarning, stacklevel=2)
        return self.expect_absent_from_snapshot(**kwargs)

    def expect(self, *, timeout=None, **properties):
        if not properties or properties.keys() - _PROPERTIES:
            raise ValueError(f"Supply supported target properties; unknown: {sorted(properties.keys() - _PROPERTIES)}")
        def matches():
            target = self._find()
            return target is not None and all(
                not target.get("strings", {}).get(k, {}).get("truncated", False)
                and k in target and target[k] == v for k, v in properties.items())
        return self.app.expect(f"target {self.query} has {properties}", matches, timeout=timeout)

    def scroll_into_view(self, container, *, direction=-1, max_scrolls=30, fully_visible=False):
        for attempt in range(max_scrolls + 1):
            ready = self._interactable()
            if ready and (not fully_visible or self._fully_visible(self.resolve())):
                return self
            if attempt < max_scrolls:
                self.app.target(container).scroll(direction)
        raise ExpectationFailed(f"Target {self.query} not interactable in {container} after {max_scrolls} scrolls",
                                observed=self.app.last)

    def screenshot(self, name="region"):
        from .visual import crop, dimensions
        target = self.resolve()
        whole = self.app.screenshot(target=target["id"])
        width, height = dimensions(whole)
        window = self.app.last_capture["window"]
        sx, sy = width / window["width"], height / window["height"]
        box = self.app.last_capture["bounds"]
        clip = dict(x=0, y=0, width=window["width"], height=window["height"])
        x, y = max(box["x"], clip["x"]), max(box["y"], clip["y"])
        w = min(box["x"] + box["width"], clip["x"] + clip["width"]) - x
        h = min(box["y"] + box["height"], clip["y"] + clip["height"]) - y
        path = self.app.bundle.root / f"{name}-{time.monotonic_ns()}.png"
        crop(whole, path, (round(x * sx), round(y * sy), round(w * sx), round(h * sy)))
        self.app.bundle.artifact(path, "crop", target=target["id"], frame_id=self.app.last_capture["frame_id"])
        profile = dict(fonts=self.app.bundle.manifest["metadata"].get("fonts"),
                       rendering=self.app.bundle.manifest["metadata"].get("rendering_profile"),
                       renderer=self.app.handshake["renderer"],
                       image_tool=next((t["version"] for t in self.app.bundle.manifest["metadata"]["tools"]["checks"] if t["name"] == "magick"), None))
        atomic_json(path.with_suffix(".profile.json"), profile)
        return path

    def expect_screenshot(self, baseline, *, masks=(), max_changed_pixels=0):
        from .visual import compare
        actual = self.screenshot()
        expected_profile = Path(baseline).with_suffix(".profile.json")
        if not expected_profile.exists():
            raise ExpectationFailed(f"Missing baseline profile: {expected_profile}", actual=str(actual))
        if json.loads(expected_profile.read_text()) != json.loads(actual.with_suffix(".profile.json").read_text()):
            raise Unsupported("Visual baseline rendering profile differs", expected=str(expected_profile),
                              actual=str(actual.with_suffix(".profile.json")))
        return compare(actual, baseline, self.app.bundle, masks=masks, max_changed_pixels=max_changed_pixels)


class Targets:
    def __init__(self, app, query):
        self.app, self.query = app, query

    def expect_count(self, count, *, timeout=None):
        """Eventual snapshot cardinality; use App.expect_count for cumulative events."""
        if type(count) is not int or count < 0:
            raise ValueError("count must be a nonnegative integer")
        return self.app.expect(f"targets {self.query} have count {count}",
                               lambda: len(self.app.inspect(**self.query)) == count, timeout=timeout)

    def expect_any_visible(self, *, timeout=None):
        return self.app.expect(f"any target {self.query} is visible", lambda: any(
            t.get("visible", False) for t in self.app.inspect(**self.query)), timeout=timeout)
