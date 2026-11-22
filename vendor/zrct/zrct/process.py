"""Bounded process-group supervision; descendants are killed even after parent exit."""
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
import uuid

from .errors import AppCrashed, DeadlineExceeded, ZrctError


class Process:
    log_limit = 8 * 1024 * 1024
    def __init__(self, name, argv, *, cwd, env, bundle, category="infrastructure", stdin=None):
        self.name, self.bundle, self.category = name, bundle, category
        self.stdout_path = bundle.root / f"{name}.stdout.log"
        self.stderr_path = bundle.root / f"{name}.stderr.log"
        self.files = [self.stdout_path.open("wb"), self.stderr_path.open("wb")]
        for path in (self.stdout_path, self.stderr_path):
            bundle.artifact(path, "log")
        try:
            owner = uuid.uuid4().hex
            env = {**env, "ZRCT_PROCESS_OWNER": owner}
            self.launch_ns = time.monotonic_ns()
            if "ZRCT_BENCHMARK_START" in env:
                env = {**env, "ZRCT_BENCHMARK_LAUNCH_NS": str(self.launch_ns)}
            self.child = subprocess.Popen([str(a) for a in argv], cwd=cwd, env=env,
                                          stdin=stdin if stdin is not None else subprocess.DEVNULL,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                          start_new_session=True)
        except BaseException:
            for stream in self.files:
                stream.close()
            raise
        self.closed = False
        self.truncated = [False, False]
        self.pumps = []
        for index, pipe in enumerate((self.child.stdout, self.child.stderr)):
            thread = threading.Thread(target=self._drain, args=(index, pipe), daemon=True)
            thread.start()
            self.pumps.append(thread)
        try:
            start_ticks = int(Path(f"/proc/{self.child.pid}/stat").read_text().rsplit(")", 1)[1].split()[19])
        except (OSError, ValueError, IndexError):
            start_ticks = None
        bundle.event("process_started", name=name, pid=self.child.pid, start_ticks=start_ticks, owner=owner,
                     argv=list(map(str, argv)))

    @staticmethod
    def owns_group(entry):
        """Verify a journaled Linux group without trusting a potentially reused PID.

        Descendants inherit an ownership marker so the watchdog can still identify
        the session after its leader has been reaped. Children that create their own
        sessions must be launched as separate managed processes.
        """
        pid = entry["pid"]
        try:
            stat = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        except FileNotFoundError:
            pass
        else:
            return entry.get("start_ticks") == int(stat[19])
        owner = entry.get("owner")
        if not owner:
            return False
        marker = f"ZRCT_PROCESS_OWNER={owner}".encode()
        for member in Path("/proc").iterdir():
            if not member.name.isdecimal():
                continue
            try:
                stat = (member / "stat").read_text().rsplit(")", 1)[1].split()
                if int(stat[2]) == pid and int(stat[3]) == pid:
                    if marker in (member / "environ").read_bytes().split(b"\0"):
                        return True
            except (OSError, ValueError, IndexError):
                continue
        return False

    def _drain(self, index, pipe):
        written = 0
        try:
            while chunk := os.read(pipe.fileno(), 65536):
                remaining = max(0, self.log_limit - written)
                retained = chunk[:remaining]
                self.files[index].write(retained)
                written += len(retained)
                if len(chunk) > remaining and not self.truncated[index]:
                    self.files[index].write(b"\n[Zrct: log size limit reached; remaining output discarded]\n")
                    self.truncated[index] = True
                self.files[index].flush()
        finally:
            pipe.close()

    def check(self):
        status = self.child.poll()
        if status is not None:
            error = AppCrashed if self.category == "application" else ZrctError
            raise error(f"{self.name} exited with status {status}", exit_code=status,
                        stderr=str(self.stderr_path), stdout=str(self.stdout_path))

    def wait(self, timeout):
        try:
            status = self.child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise DeadlineExceeded(f"{self.name} exceeded {timeout:g}s", pid=self.child.pid,
                                   stderr=str(self.stderr_path)) from None
        self.drain()
        if status:
            self.check()
        return status

    def drain(self):
        for thread in self.pumps:
            thread.join(timeout=.5)

    def stop(self, grace=1.0):
        if self.closed:
            return
        self.closed = True
        try:
            os.killpg(self.child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.child.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
        # A child may still hold sockets/files after its parent exits successfully.
        try:
            os.killpg(self.child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.child.wait(timeout=2)
        for thread in self.pumps:
            thread.join(timeout=2)
        for stream in self.files:
            stream.close()
        self.bundle.event("process_stopped", name=self.name, exit_code=self.child.returncode,
                          log_truncated=self.truncated)


def until(predicate, *, timeout, condition, health=lambda: None):
    deadline = time.monotonic() + timeout
    last = None
    while True:
        health()
        last = predicate()
        if last:
            return last
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise DeadlineExceeded(f"Timed out waiting for {condition}", condition=condition,
                                   last_observation=last)
        time.sleep(min(.02, remaining))
