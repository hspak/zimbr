"""Run the native rendering and interaction regressions in a fresh Wayland session."""
import os
import sys
from pathlib import Path

from zrct import Suite, TestCase

SUITE = Suite("zimbr-native", timeout=240)


class Native(TestCase):
    def test_gui_contracts(self):
        process = self.context.desktop.launch(
            "gui-tests", [self.context.suite.executable],
            cwd=self.context.suite.repository, category="application",
            env={"PATH": str(Path(sys.executable).parent) + os.pathsep + os.environ.get("PATH", "")})
        code = process.child.wait(timeout=210)
        self.assertEqual(0, code, process.stderr_path.read_text())
