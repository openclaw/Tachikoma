#!/usr/bin/env python3
"""Exercise the hosted credential guard with synthetic values only."""

import pathlib
import subprocess
import tempfile
import textwrap
import unittest


class LiveProviderWorkflowTests(unittest.TestCase):
    def run_guard(self, credential=None):
        workflow = (pathlib.Path(__file__).resolve().parents[1] /
                    ".github/workflows/live-providers.yml").read_text()
        step = workflow.split("      - name: Detect live provider credentials\n", 1)[1]
        step = step.split("      - name: Select Xcode 27\n", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        environment = {"PATH": "/usr/bin:/bin"}
        if credential is not None:
            environment["OPENAI_API_KEY"] = credential
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "output"
            environment["GITHUB_OUTPUT"] = str(output)
            result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail"], input=script,
                                    text=True, capture_output=True, env=environment)
            return result, output.read_text() if output.exists() else ""

    def test_skips_absent_or_placeholder_credentials(self):
        for credential in (None, "env-key", "cred-key", "test-key", "TEST-placeholder"):
            with self.subTest(credential=credential):
                result, output = self.run_guard(credential)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("No live provider credential is configured", result.stdout)
                self.assertEqual(output, "available=false\n")

    def test_accepts_configured_credential_without_printing_it(self):
        result, output = self.run_guard("synthetic-provider-credential")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Live credential configured: OPENAI_API_KEY", result.stdout)
        self.assertNotIn("synthetic-provider-credential", result.stdout + result.stderr)
        self.assertEqual(output, "available=true\n")

    def test_build_and_smoke_steps_require_credentials(self):
        workflow = (pathlib.Path(__file__).resolve().parents[1] /
                    ".github/workflows/live-providers.yml").read_text()
        for name in ("Select Xcode 27", "Run live provider smoke tests"):
            step = workflow.split(f"      - name: {name}\n", 1)[1].split("\n      - ", 1)[0]
            self.assertIn("if: steps.credentials.outputs.available == 'true'", step)


if __name__ == "__main__":
    unittest.main()
