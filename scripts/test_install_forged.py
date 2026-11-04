import os
from pathlib import Path
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).with_name("install-forged.sh")


class ForgedInstallerTest(unittest.TestCase):
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
        self.bin = self.root / "bin"
        self.data = self.root / "data"
        self.env = os.environ.copy()
        self.env.pop("CARGO_BUILD_JOBS", None)
        self.env.update(
            PATH=f"{self.tools}:{self.env['PATH']}",
            FORGED_SOURCE_DIR=str(self.source),
            FORGED_INSTALL_DIR=str(self.bin),
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
        self.tool("rustc", "printf 'host: x86_64-unknown-linux-gnu\\n'")
        self.tool("pkg-config", 'test "${FORGED_TEST_NO_LIBCAP:-0}" != 1')
        self.tool(
            "python3",
            """if [ "${FORGED_TEST_BUILD_FAIL:-0}" = 1 ]; then exit 42; fi
printf '%s' "$CARGO_BUILD_JOBS" > "${FORGED_DATA_DIR}/jobs-used"
while [ "$#" -gt 0 ]; do
  if [ "$1" = --package-dir ]; then shift; package=$1; fi
  shift
done
mkdir -p "$package/bin"
printf '#!/bin/sh\\nprintf "fake-forged\\\\n"\\n' > "$package/bin/forged"
chmod +x "$package/bin/forged"
""",
        )

    def tool(self, name, body):
        path = self.tools / name
        path.write_text(f"#!/bin/sh\nset -eu\n{body}\n")
        path.chmod(0o755)

    def run_installer(self, **extra_env):
        return subprocess.run(
            ["sh", str(INSTALLER)],
            cwd=self.root,
            env={**self.env, **extra_env},
            capture_output=True,
            text=True,
        )

    def test_installs_and_replaces_only_its_own_link(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        link = self.bin / "forged"
        self.assertTrue(link.is_symlink())
        self.assertEqual((self.data / "jobs-used").read_text(), "1")
        self.assertEqual(subprocess.check_output([str(link)], text=True), "fake-forged\n")
        first_target = link.resolve()
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(link.resolve(), first_target)
        self.assertTrue(first_target.is_file())

    def test_preserves_an_existing_executable(self):
        self.bin.mkdir()
        existing = self.bin / "forged"
        existing.write_text("keep me")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(existing.read_text(), "keep me")

    def test_explicit_cargo_job_count_is_respected(self):
        result = self.run_installer(CARGO_BUILD_JOBS="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.data / "jobs-used").read_text(), "3")

    def test_preserves_an_unrelated_symlink(self):
        self.bin.mkdir()
        existing = self.bin / "forged"
        existing.symlink_to(self.root / "another-command")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(os.readlink(existing), str(self.root / "another-command"))

    def test_clones_when_no_local_checkout_is_available(self):
        result = self.run_installer(FORGED_SOURCE_DIR="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Cloning Forged source", result.stdout)
        self.assertTrue((self.bin / "forged").is_symlink())

    def test_failed_build_keeps_previous_install(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        previous = (self.bin / "forged").resolve()
        result = self.run_installer(FORGED_TEST_BUILD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.bin / "forged").resolve(), previous)
        self.assertEqual(len(list((self.data / "releases").iterdir())), 1)

    def test_missing_linux_dependencies_stop_before_install(self):
        result = self.run_installer(FORGED_TEST_NO_LIBCAP="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("libcap development headers", result.stderr)
        self.assertFalse(self.bin.exists())


if __name__ == "__main__":
    unittest.main()
