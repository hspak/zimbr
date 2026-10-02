"""Run the native rendering and interaction regressions in a fresh Wayland session."""
import os
import sys
from pathlib import Path

from zrct import Suite, TestCase

from support import configure_rendering

SUITE = Suite("zimbr-native", timeout=240, display=os.environ.get("ZRCT_DISPLAY_SMOKE") == "1",
              sdl_renderer=os.environ.get("SDL_RENDER_DRIVER", "vulkan"))


class Native(TestCase):
    def test_gui_contracts(self):
        configure_rendering(self.context)
        process = self.context.desktop.launch(
            "gui-tests", [self.context.suite.executable],
            cwd=self.context.suite.repository, category="application",
            env={"PATH": str(Path(sys.executable).parent) + os.pathsep + os.environ.get("PATH", "")})
        code = process.child.wait(timeout=210)
        self.assertEqual(0, code, process.stderr_path.read_text())
