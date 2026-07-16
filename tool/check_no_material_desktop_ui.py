"""Reject Material widgets and interaction behavior in desktop UI."""

from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SCOPE = ROOT / "lib" / "src"
EXCLUDED = {SCOPE / "app" / "ios_bootstrap.dart"}
FORBIDDEN = (
    "package:flutter/material.dart",
    "MaterialApp",
    "ThemeData",
    "Theme.of(",
    "Scaffold(",
    "InkWell",
    "InkResponse",
    "InkSparkle",
    "TextButton",
    "FilledButton",
    "DropdownButton",
    "PopupMenuButton",
    "AlertDialog",
    "showDialog",
)


def main() -> None:
    findings: list[str] = []
    for path in sorted(SCOPE.rglob("*.dart")):
        if path in EXCLUDED:
            continue
        text = path.read_text(encoding="utf-8")
        for line_number, line in enumerate(text.splitlines(), start=1):
            for token in FORBIDDEN:
                if token in line:
                    findings.append(
                        f"{path.relative_to(ROOT)}:{line_number}: {token}"
                    )
    if findings:
        raise SystemExit(
            "Material behavior found in desktop UI:\n"
            + "\n".join(findings)
        )
    print("Desktop UI is free of Material widgets and interaction behavior.")


if __name__ == "__main__":
    main()
