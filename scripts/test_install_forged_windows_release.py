import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile


INSTALLER = Path(__file__).with_name("install-forged.ps1")
POWERSHELL = os.environ.get("FORGED_TEST_PWSH") or shutil.which("pwsh")


@unittest.skipUnless(POWERSHELL and os.name != "nt", "requires PowerShell on Unix")
class ForgedWindowsReleaseInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.archive = self.root / "package.zip"
        self.checksum = self.root / "package.sha256"
        self.helper = self.root / "run.ps1"
        self.helper.write_text(
            """function Invoke-WebRequest {
    param([switch]$UseBasicParsing, [string]$Uri, [string]$OutFile)
    if ($env:FORGED_TEST_DOWNLOAD_FAIL) { throw 'simulated download failure' }
    $source = if ($Uri.EndsWith('.sha256')) { $env:FORGED_TEST_CHECKSUM } else { $env:FORGED_TEST_ARCHIVE }
    Copy-Item -LiteralPath $source -Destination $OutFile
}
& $env:FORGED_TEST_INSTALLER
"""
        )
        self.env = os.environ.copy()
        self.env.pop("PROCESSOR_ARCHITEW6432", None)
        self.env.update(
            OS="Windows_NT",
            PROCESSOR_ARCHITECTURE="AMD64",
            LOCALAPPDATA=str(self.root),
            FORGED_DATA_DIR=str(self.data),
            FORGED_TEST_ARCHIVE=str(self.archive),
            FORGED_TEST_CHECKSUM=str(self.checksum),
            FORGED_TEST_INSTALLER=str(INSTALLER),
        )
        self.make_package()

    def make_package(self, *, omit=None, unsafe=False, version="one"):
        files = {
            "bin/forged.exe": version,
            "bin/codex-code-mode-host.exe": "host",
            "bin/codex-exec-server.exe": "executor",
            "codex-path/rg.exe": "search",
            "codex-resources/codex-command-runner.exe": "runner",
            "codex-resources/codex-windows-sandbox-setup.exe": "sandbox",
            "codex-package.json": json.dumps({
                "variant": "forged", "entrypoint": "bin/forged.exe", "version": "0.1.1",
                "target": "x86_64-pc-windows-msvc",
            }),
        }
        if omit:
            del files[omit]
        if unsafe:
            files["../escape"] = "bad"
        with zipfile.ZipFile(self.archive, "w") as archive:
            for path, content in files.items():
                archive.writestr(path, content)
        digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.checksum.write_text(f"{digest}  forged-windows-x86_64.zip\n")

    def run_installer(self, **extra_env):
        return subprocess.run(
            [POWERSHELL, "-NoProfile", "-File", str(self.helper)],
            env={**self.env, **extra_env}, capture_output=True, text=True,
        )

    def test_installs_and_preserves_previous_package(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        executable = self.data / "current/bin/forged.exe"
        self.assertEqual(executable.read_text(), "one")
        self.assertEqual((self.data / "current/bin/codex.exe").read_text(), "one")
        metadata = json.loads((self.data / "current/codex-package.json").read_text(encoding="utf-8-sig"))
        self.assertEqual(metadata["entrypoint"], "bin/codex.exe")
        self.assertEqual(metadata["version"], "0.0.0")
        self.assertEqual(metadata["forgedReleaseVersion"], "0.1.1")
        self.make_package(version="two")
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(executable.read_text(), "two")
        backups = list((self.data / "releases").glob("previous-*"))
        self.assertEqual((backups[0] / "bin/forged.exe").read_text(), "one")

    def test_rejects_bad_checksum_without_replacing_install(self):
        self.assertEqual(self.run_installer().returncode, 0)
        self.checksum.write_text("0" * 64)
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("checksum", result.stderr)
        self.assertEqual((self.data / "current/bin/forged.exe").read_text(), "one")

    def test_rejects_missing_helper_and_unsafe_paths(self):
        for args in ({"omit": "codex-path/rg.exe"}, {"unsafe": True}):
            with self.subTest(args=args):
                self.make_package(**args)
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.data / "current").exists())

    def test_rejects_unsupported_architecture_and_download_failure(self):
        result = self.run_installer(PROCESSOR_ARCHITECTURE="ARM64")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No prebuilt", result.stderr)
        result = self.run_installer(FORGED_TEST_DOWNLOAD_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not download", result.stderr)

    def test_preserves_unmanaged_directory(self):
        current = self.data / "current"
        current.mkdir(parents=True)
        (current / "keep").write_text("untouched")
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((current / "keep").read_text(), "untouched")


if __name__ == "__main__":
    unittest.main()
