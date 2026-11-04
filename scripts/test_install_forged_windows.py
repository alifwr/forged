import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).with_name("install-forged.ps1")
POWERSHELL = os.environ.get("FORGED_TEST_PWSH") or shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL and os.name != "nt", "requires PowerShell on Unix for mock tools")
class ForgedWindowsInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.source = self.root / "source"
        (self.source / "codex-rs/cli/src/bin").mkdir(parents=True)
        (self.source / "codex-rs/cli/src/bin/forged.rs").touch()
        (self.source / "scripts").mkdir()
        (self.source / "scripts/build_codex_package.py").touch()
        self.data = self.root / "data"
        self.env = os.environ.copy()
        self.env.pop("CARGO_BUILD_JOBS", None)
        self.env.update(
            PATH=f"{self.tools}:{self.env['PATH']}",
            OS="Windows_NT",
            LOCALAPPDATA=str(self.root),
            FORGED_SOURCE_DIR=str(self.source),
            FORGED_DATA_DIR=str(self.data),
        )
        self.tool(
            "git",
            """for arg in "$@"; do destination=$arg; done
mkdir -p "$destination/codex-rs/cli/src/bin" "$destination/scripts"
touch "$destination/codex-rs/cli/src/bin/forged.rs"
touch "$destination/scripts/build_codex_package.py"
""",
        )
        self.tool("cargo", "exit 0")
        self.tool("rustc", "printf 'host: x86_64-pc-windows-msvc\\n'")
        self.tool(
            "py",
            """if [ "$1" = -3 ]; then shift; fi
if [ "$1" = -c ]; then exit 0; fi
if [ "${FORGED_TEST_BUILD_FAIL:-0}" = 1 ]; then exit 42; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = --package-dir ]; then shift; package=$1; fi
  shift
done
mkdir -p "$package/bin"
printf '%s' "$CARGO_BUILD_JOBS" > "$package/bin/forged.exe"
printf '{"variant":"forged","entrypoint":"bin/forged.exe"}' > "$package/codex-package.json"
""",
        )

    def tool(self, name, body):
        path = self.tools / name
        path.write_text(f"#!/bin/sh\nset -eu\n{body}\n")
        path.chmod(0o755)

    def run_installer(self, **extra_env):
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-File", str(INSTALLER)],
            cwd=self.root,
            env={**self.env, **extra_env},
            capture_output=True,
            text=True,
        )

    def test_installs_and_preserves_the_previous_package_on_update(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        executable = self.data / "current/bin/forged.exe"
        self.assertEqual(executable.read_text(), "1")
        result = self.run_installer(CARGO_BUILD_JOBS="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(executable.read_text(), "3")
        backups = list((self.data / "releases").glob("previous-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "bin/forged.exe").read_text(), "1")

    def test_failed_build_keeps_existing_install(self):
        self.assertEqual(self.run_installer().returncode, 0)
        result = self.run_installer(FORGED_TEST_BUILD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.data / "current/bin/forged.exe").read_text(), "1")
        self.assertEqual(list((self.data / "releases").glob("build-*")), [])

    def test_refuses_unmanaged_existing_directory(self):
        current = self.data / "current"
        current.mkdir(parents=True)
        sentinel = current / "keep.txt"
        sentinel.write_text("keep me")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(sentinel.read_text(), "keep me")

    def test_clones_when_no_source_directory_is_supplied(self):
        result = self.run_installer(FORGED_SOURCE_DIR="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Cloning Forged source", result.stdout)
        self.assertTrue((self.data / "current/bin/forged.exe").is_file())

    def test_refuses_an_unmanaged_symlink(self):
        self.data.mkdir()
        other = self.root / "other"
        other.mkdir()
        sentinel = other / "keep.txt"
        sentinel.write_text("keep me")
        (self.data / "current").symlink_to(other, target_is_directory=True)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(sentinel.read_text(), "keep me")

    def test_rejects_non_windows(self):
        result = self.run_installer(OS="Linux")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires Windows", result.stderr)
        self.assertFalse(self.data.exists())


if __name__ == "__main__":
    unittest.main()
