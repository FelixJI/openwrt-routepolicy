import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "release_version", Path(__file__).resolve().parents[2] / "scripts/ci/release-version.py"
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseVersionTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for package in release.PACKAGES:
            (self.root / package).mkdir()
        self.reset_versions()

    def reset_versions(self):
        for package in release.PACKAGES:
            (self.root / package / "Makefile").write_text("PKG_VERSION:=0.3.4\nPKG_RELEASE:=2\n")

    def test_bumps_and_numeric_tag_order(self):
        for mode, expected in [("patch", "v0.10.1"), ("minor", "v0.11.0"), ("major", "v1.0.0")]:
            with self.subTest(mode=mode):
                self.reset_versions()
                self.assertEqual(release.resolve(self.root, mode, ["v0.9.9", "v0.10.0", "v9.0.0-rc1"]), expected)
                for package in release.PACKAGES:
                    self.assertEqual((self.root / package / "Makefile").read_text(), f"PKG_VERSION:={expected[1:]}\nPKG_RELEASE:=1\n")

    def test_source_baseline_without_tags(self):
        self.assertEqual(release.resolve(self.root, "patch", []), "v0.3.5")

    def test_existing_tag_does_not_modify_source(self):
        self.assertEqual(release.resolve(self.root, "patch", [], "v0.3.4"), "v0.3.4")
        self.assertIn("PKG_RELEASE:=2", (self.root / "routepolicy/Makefile").read_text())

    def test_invalid_tag_and_mismatched_packages(self):
        for tag in ("v0.3.3", "v0.3.4-rc1", "v00.3.4", "main", "v0.3.4\n"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.resolve(self.root, "patch", [], tag)
        (self.root / "routepolicy/Makefile").write_text("PKG_VERSION:=0.3.5\nPKG_RELEASE:=1\n")
        with self.assertRaises(ValueError):
            release.resolve(self.root, "patch", [])

    def test_invalid_mode_and_metadata_leave_files_unchanged(self):
        with self.assertRaises(ValueError):
            release.resolve(self.root, "unknown", [])
        path = self.root / "luci-app-routepolicy/Makefile"
        path.write_text("PKG_VERSION:=0.3.4\nPKG_VERSION:=0.3.4\nPKG_RELEASE:=1\n")
        before = (self.root / "routepolicy/Makefile").read_text()
        with self.assertRaises(ValueError):
            release.resolve(self.root, "patch", [])
        self.assertEqual((self.root / "routepolicy/Makefile").read_text(), before)


if __name__ == "__main__":
    unittest.main()
