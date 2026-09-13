#!/usr/bin/env python3
"""Typecheck guide snippets and the Combine Realtime sample on macOS."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def run(root, *arguments):
    result = subprocess.run(
        arguments, cwd=root, capture_output=True, text=True
    )
    if result.returncode:
        sys.stderr.write(result.stdout + result.stderr)
        raise SystemExit(result.returncode)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("documents", nargs="*", type=Path)
    arguments = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("Run on macOS so the Combine Realtime example is compiled.")
    root = Path(__file__).resolve().parents[1]
    documents = arguments.documents or [
        root / "docs" / name
        for name in ("azure.md", "gpt-oss.md", "lmstudio.md", "tool-system-migration.md")
    ]
    bin_path = Path(run(root, "swift", "build", "--show-bin-path").strip())
    module_paths = [bin_path / "Modules", bin_path]
    if not any((path / "Tachikoma.swiftmodule").exists() for path in module_paths):
        parser.error("Build the debug package with `swift build` before checking examples.")

    imports = {"import Tachikoma"}
    snippets = []
    for document in documents:
        document = document.resolve()
        text = document.read_text(encoding="utf-8")
        for match in re.finditer(r"```swift[^\S\n]*\n(.*?)```", text, re.DOTALL):
            lines = match.group(1).splitlines()
            for index, line in enumerate(lines):
                if line.strip().startswith(("import ", "@testable import ")):
                    imports.add(line.strip())
                    lines[index] = ""
            line_number = text[: match.start(1)].count("\n") + 1
            location = json.dumps(str(document), ensure_ascii=False)
            snippets.append(
                f"func documentationExample{len(snippets)}() async throws {{\n"
                f"#sourceLocation(file: {location}, line: {line_number})\n"
                + "\n".join(lines)
                + "\n#sourceLocation()\n}"
            )
    if not snippets:
        parser.error("No Swift snippets found in the selected documents.")

    command = ["swiftc", "-typecheck", "-swift-version", "6"]
    for path in module_paths:
        command.extend(["-I", str(path)])
    for dependency, module in (
        ("swift-numerics", "_NumericsShims"), ("swift-system", "CSystem")
    ):
        headers = root / ".build/checkouts" / dependency / "Sources" / module / "include"
        command.extend(["-I", str(headers)])
    package = json.loads(run(root, "swift", "package", "dump-package"))
    minimum = next(
        p["version"] for p in package["platforms"] if p["platformName"] == "macos"
    )
    target = json.loads(run(root, "swift", "-print-target-info"))["target"]
    command.extend(["-target", target["unversionedTriple"] + minimum])

    with tempfile.TemporaryDirectory(prefix="tachikoma-docs-") as directory:
        source = Path(directory) / "GuideExamples.swift"
        source.write_text("\n".join(sorted(imports)) + "\n\n" + "\n\n".join(snippets), encoding="utf-8")
        run(root, *command, str(source), str(root / "Examples/RealtimeExample.swift"))
    print(f"Typechecked {len(snippets)} Swift guide snippets and the Realtime example.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
