"""Portable native executable lookup (python -m unittest discover -s examples)."""
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from _common import executable_path


class ExecutablePathTests(unittest.TestCase):
    def test_platform_and_generator_layouts(self):
        for platform in ("win32", "linux", "darwin"):
            for directory in ("", "Debug"):
                with self.subTest(platform=platform, directory=directory):
                    with tempfile.TemporaryDirectory() as tmp, patch("_common.sys.platform", platform):
                        root = Path(tmp)
                        name = "sample.exe" if platform == "win32" else "sample"
                        binary = root / directory / name
                        binary.parent.mkdir(exist_ok=True)
                        binary.touch()
                        self.assertEqual(executable_path(root / "sample"), binary)

    def test_missing_debug_does_not_select_another_configuration(self):
        with tempfile.TemporaryDirectory() as tmp, patch("_common.sys.platform", "win32"):
            root = Path(tmp)
            (root / "Release").mkdir()
            (root / "Release" / "sample.exe").touch()
            self.assertEqual(executable_path(root / "sample"), root / "sample.exe")


if __name__ == "__main__":
    unittest.main()
