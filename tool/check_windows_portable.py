"""Audit a Windows portable ZIP before it is published."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import stat
import sys
import zipfile


REQUIRED_ENTRIES = {
    "data/flutter_assets/NOTICES.Z",
    "data/flutter_assets/assets/brand/symbol.svg",
    "data/flutter_assets/assets/brand/wordmark.svg",
    "flutter_windows.dll",
    "yandex_keyboard_desktop.exe",
}
FORBIDDEN_BASENAMES = {
    ".env",
    "config.json",
    "credentials.json",
    "secrets.json",
    "flutter_acrylic_plugin.dll",
    "materialicons-regular.otf",
}
MAX_ENTRIES = 10_000
MAX_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path, help="portable Windows ZIP")
    return parser.parse_args()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    args = _arguments()
    if not args.path.is_file():
        print(f"Portable archive is missing: {args.path}", file=sys.stderr)
        return 2

    issues: list[str] = []
    try:
        with zipfile.ZipFile(args.path) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ENTRIES:
                issues.append("archive contains too many entries")
            if sum(entry.file_size for entry in entries) > MAX_UNCOMPRESSED_BYTES:
                issues.append("archive is too large when extracted")

            names = [entry.filename for entry in entries]
            name_set = set(names)
            if len(names) != len(name_set):
                issues.append("archive contains duplicate paths")

            folded: dict[str, str] = {}
            for entry in entries:
                name = entry.filename
                if "\\" in name:
                    issues.append(f"non-canonical archive path: {name}")
                path = PurePosixPath(name.replace("\\", "/"))
                normalized = path.as_posix()
                prior = folded.setdefault(normalized.casefold(), normalized)
                if prior != normalized:
                    issues.append(f"case-colliding paths: {prior} and {normalized}")
                has_drive = bool(path.parts) and ":" in path.parts[0]
                if path.is_absolute() or has_drive or ".." in path.parts:
                    issues.append(f"unsafe archive path: {name}")
                if entry.flag_bits & 0x1:
                    issues.append(f"encrypted payload is forbidden: {name}")
                if stat.S_IFMT(entry.external_attr >> 16) == stat.S_IFLNK:
                    issues.append(f"symbolic link is forbidden: {name}")

                basename = path.name.casefold()
                parts = {part.casefold() for part in path.parts}
                if basename in FORBIDDEN_BASENAMES or basename.startswith(".env."):
                    issues.append(f"forbidden payload entry: {name}")
                if parts.intersection({"secret", "secrets", "credentials"}):
                    issues.append(f"forbidden private-data path: {name}")
                if basename.endswith(
                    (".appinstaller", ".cer", ".exp", ".ilk", ".lib", ".msix", ".pdb")
                ):
                    issues.append(f"build-only payload leaked into archive: {name}")

            for required in sorted(REQUIRED_ENTRIES - name_set):
                issues.append(f"required payload entry is missing: {required}")
    except (OSError, zipfile.BadZipFile) as error:
        print(f"Portable archive is invalid: {error}", file=sys.stderr)
        return 1

    if issues:
        print("Windows portable payload audit failed:", file=sys.stderr)
        for issue in issues:
            print(f"- {issue}", file=sys.stderr)
        return 1

    print(
        f"Windows portable payload is clean: {len(entries)} entries; "
        f"sha256={_sha256(args.path)}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
