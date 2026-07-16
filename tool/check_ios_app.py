"""Audit the unsigned offline iOS host and embedded keyboard extension."""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import zipfile


EXPECTED_HOST_IDENTIFIER = "io.github.oniel.yandexKeyboardDesktop"
EXPECTED_EXTENSION_IDENTIFIER = f"{EXPECTED_HOST_IDENTIFIER}.Keyboard"
TRUTHY = {"1", "true", "yes"}
FORBIDDEN_BASENAMES = {
    ".env",
    "config.json",
    "credentials.json",
    "secrets.json",
    "embedded.mobileprovision",
}
REQUIRED_HOST_PAYLOADS = {
    "Frameworks/App.framework/flutter_assets/NOTICES.Z",
    "Frameworks/App.framework/flutter_assets/assets/brand/symbol.svg",
    "Frameworks/App.framework/flutter_assets/assets/brand/wordmark.svg",
    "PrivacyInfo.xcprivacy",
}
MAX_ARCHIVE_ENTRIES = 10_000
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 1024 * 1024 * 1024
MAX_ARCHIVE_ENTRY_BYTES = 512 * 1024 * 1024


def _project_version() -> tuple[str, str]:
    pubspec = Path(__file__).resolve().parent.parent / "pubspec.yaml"
    match = re.search(
        r"^version:\s*([^+\s]+)\+([^\s]+)",
        pubspec.read_text(encoding="utf-8"),
        flags=re.MULTILINE,
    )
    if match is None:
        raise RuntimeError("pubspec.yaml has no semantic version and build number")
    return match.group(1), match.group(2)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _arguments() -> argparse.Namespace:
    version, build = _project_version()
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path, help="Runner.app or its ZIP archive")
    parser.add_argument("--host-identifier", default=EXPECTED_HOST_IDENTIFIER)
    parser.add_argument(
        "--extension-identifier", default=EXPECTED_EXTENSION_IDENTIFIER
    )
    parser.add_argument("--version", default=version)
    parser.add_argument("--build", default=build)
    parser.add_argument(
        "--allow-signature",
        action="store_true",
        help="allow development/simulator signing; release archives stay strict",
    )
    return parser.parse_args()


def _load_plist(path: Path, label: str, issues: list[str]) -> dict:
    try:
        with path.open("rb") as stream:
            value = plistlib.load(stream)
        if not isinstance(value, dict):
            raise ValueError("root is not a dictionary")
        return value
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        issues.append(f"{label} is invalid: {error}")
        return {}


def _expect(
    mapping: dict,
    key: str,
    expected: object,
    label: str,
    issues: list[str],
) -> None:
    actual = mapping.get(key)
    if actual != expected:
        issues.append(f"{label}.{key} is {actual!r}; expected {expected!r}")


def _audit_privacy_manifest(path: Path, label: str, issues: list[str]) -> None:
    manifest = _load_plist(path, label, issues)
    _expect(manifest, "NSPrivacyTracking", False, label, issues)
    _expect(manifest, "NSPrivacyCollectedDataTypes", [], label, issues)
    accessed = manifest.get("NSPrivacyAccessedAPITypes")
    if not isinstance(accessed, list):
        issues.append(f"{label}.NSPrivacyAccessedAPITypes is not an array")
        return
    user_defaults = [
        item
        for item in accessed
        if isinstance(item, dict)
        and item.get("NSPrivacyAccessedAPIType")
        == "NSPrivacyAccessedAPICategoryUserDefaults"
    ]
    if len(user_defaults) != 1:
        issues.append(f"{label} must declare UserDefaults exactly once")
        return
    reasons = user_defaults[0].get("NSPrivacyAccessedAPITypeReasons")
    if not isinstance(reasons, list) or "1C8F.1" not in reasons:
        issues.append(f"{label} is missing UserDefaults reason 1C8F.1")


def _audit_tree(
    app: Path, issues: list[str], *, allow_signature: bool
) -> set[str]:
    root = app.resolve()
    names: set[str] = set()
    folded: dict[str, str] = {}
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        names.add(relative)
        prior = folded.setdefault(relative.casefold(), relative)
        if prior != relative:
            issues.append(f"case-colliding payload paths: {prior} and {relative}")

        basename = path.name.casefold()
        parts = {part.casefold() for part in path.relative_to(app).parts}
        if basename in FORBIDDEN_BASENAMES or basename.startswith(".env."):
            issues.append(f"forbidden payload entry: {relative}")
        if parts.intersection({"secret", "secrets", "credentials"}):
            issues.append(f"forbidden private-data path: {relative}")
        if "_codesignature" in parts and not allow_signature:
            issues.append(f"signature leaked into unsigned artifact: {relative}")
        if basename.endswith((".pdb", ".dsym")):
            issues.append(f"debug payload leaked into release app: {relative}")
        if path.is_symlink():
            target = (path.parent / os.readlink(path)).resolve(strict=False)
            if not target.is_relative_to(root):
                issues.append(f"payload symlink escapes app bundle: {relative}")
        elif os.name == "posix" and path.is_file():
            mode = stat.S_IMODE(path.stat().st_mode)
            if mode & 0o022:
                issues.append(f"group/world-writable payload mode {mode:o}: {relative}")
    return names


def _audit_executable(
    bundle: Path,
    info: dict,
    label: str,
    issues: list[str],
    *,
    require_extension_isolation: bool = False,
    allow_development_dependencies: bool = False,
) -> None:
    executable_name = info.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        issues.append(f"{label}.CFBundleExecutable is missing")
        return
    executable = bundle / executable_name
    if not executable.is_file() or executable.is_symlink():
        issues.append(f"{label} executable is missing or unsafe: {executable_name}")
        return
    if os.name == "posix" and not os.access(executable, os.X_OK):
        issues.append(f"{label} executable is not executable: {executable_name}")
    if sys.platform == "darwin":
        result = subprocess.run(
            ["otool", "-L", str(executable)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            issues.append(f"otool could not inspect {label} executable")
            return
        dependencies = [
            line.strip().split(" ", 1)[0]
            for line in result.stdout.splitlines()
            if line[:1].isspace() and line.strip()
        ]
        if require_extension_isolation:
            for dependency in dependencies:
                relative = dependency.removeprefix("@rpath/")
                allowed_swift_runtime = (
                    dependency.startswith("@rpath/")
                    and "/" not in relative
                    and PurePosixPath(relative).name.startswith("libswift")
                    and PurePosixPath(relative).suffix == ".dylib"
                )
                allowed_system_library = dependency.startswith(
                    ("/System/Library/", "/usr/lib/")
                )
                allowed_development_library = (
                    allow_development_dependencies
                    and dependency == f"@rpath/{executable_name}.debug.dylib"
                )
                if not (
                    allowed_swift_runtime
                    or allowed_system_library
                    or allowed_development_library
                ):
                    issues.append(
                        "keyboard extension links a non-system dynamic dependency: "
                        f"{dependency}"
                    )
        else:
            for dependency in dependencies:
                if dependency.startswith("/") and not dependency.startswith(
                    ("/System/Library/", "/usr/lib/")
                ):
                    issues.append(
                        f"{label} executable has absolute non-system dependency: {dependency}"
                    )


def _audit_app(app: Path, args: argparse.Namespace) -> list[str]:
    issues: list[str] = []
    if not app.is_dir() or app.is_symlink():
        return [f"iOS app bundle is missing or unsafe: {app}"]

    names = _audit_tree(app, issues, allow_signature=args.allow_signature)
    for required in sorted(REQUIRED_HOST_PAYLOADS - names):
        issues.append(f"required host payload is missing: {required}")

    host_info = _load_plist(app / "Info.plist", "Runner Info.plist", issues)
    _expect(host_info, "CFBundlePackageType", "APPL", "Runner", issues)
    _expect(host_info, "CFBundleIdentifier", args.host_identifier, "Runner", issues)
    _expect(host_info, "CFBundleShortVersionString", args.version, "Runner", issues)
    _expect(host_info, "CFBundleVersion", args.build, "Runner", issues)
    _audit_executable(app, host_info, "Runner", issues)

    plugin_root = app / "PlugIns"
    extensions = sorted(plugin_root.glob("*.appex")) if plugin_root.is_dir() else []
    expected_extension = plugin_root / "KeyboardExtension.appex"
    if extensions != [expected_extension]:
        listed = ", ".join(item.name for item in extensions) or "none"
        issues.append(f"expected only KeyboardExtension.appex; found {listed}")
        return issues

    extension_info = _load_plist(
        expected_extension / "Info.plist", "KeyboardExtension Info.plist", issues
    )
    _expect(extension_info, "CFBundlePackageType", "XPC!", "KeyboardExtension", issues)
    _expect(
        extension_info,
        "CFBundleIdentifier",
        args.extension_identifier,
        "KeyboardExtension",
        issues,
    )
    _expect(
        extension_info,
        "CFBundleShortVersionString",
        args.version,
        "KeyboardExtension",
        issues,
    )
    _expect(extension_info, "CFBundleVersion", args.build, "KeyboardExtension", issues)

    extension = extension_info.get("NSExtension")
    if not isinstance(extension, dict):
        issues.append("KeyboardExtension.NSExtension is missing")
        extension = {}
    _expect(
        extension,
        "NSExtensionPointIdentifier",
        "com.apple.keyboard-service",
        "KeyboardExtension.NSExtension",
        issues,
    )
    attributes = extension.get("NSExtensionAttributes")
    if not isinstance(attributes, dict):
        issues.append("KeyboardExtension.NSExtensionAttributes is missing")
        attributes = {}
    _expect(attributes, "IsASCIICapable", True, "KeyboardExtension", issues)
    _expect(attributes, "RequestsOpenAccess", True, "KeyboardExtension", issues)

    endpoint = extension_info.get("YKDTransformationServiceBaseURL")
    reviewed = str(
        extension_info.get("YKDTransformationServicePrivacyReviewed", "")
    ).strip().casefold()
    if not isinstance(endpoint, str) or endpoint.strip():
        issues.append("offline extension unexpectedly configures a transformation endpoint")
    if reviewed in TRUTHY:
        issues.append("offline extension unexpectedly enables the privacy-review network gate")
    if any(
        marker in str(value)
        for value in (endpoint, reviewed)
        for marker in ("$(", "${")
    ):
        issues.append("extension contains unresolved network build settings")

    extension_relative_names = {
        path.relative_to(expected_extension).as_posix()
        for path in expected_extension.rglob("*")
    }
    embedded_frameworks = sorted(
        name
        for name in extension_relative_names
        if name.startswith("Frameworks/")
        and not (
            "/" not in name.removeprefix("Frameworks/")
            and PurePosixPath(name).name.startswith("libswift")
            and PurePosixPath(name).suffix == ".dylib"
        )
    )
    if embedded_frameworks:
        issues.append(
            "keyboard extension embeds a dynamic framework: "
            f"{embedded_frameworks[0]}"
        )
    _audit_executable(
        expected_extension,
        extension_info,
        "KeyboardExtension",
        issues,
        require_extension_isolation=True,
        allow_development_dependencies=args.allow_signature,
    )

    _audit_privacy_manifest(app / "PrivacyInfo.xcprivacy", "Runner privacy", issues)
    _audit_privacy_manifest(
        expected_extension / "PrivacyInfo.xcprivacy",
        "KeyboardExtension privacy",
        issues,
    )
    return issues


def _safe_extract_archive(path: Path, destination: Path) -> tuple[Path | None, list[str]]:
    issues: list[str] = []
    try:
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
            if len(entries) > MAX_ARCHIVE_ENTRIES:
                issues.append(
                    "archive contains too many entries: "
                    f"{len(entries)} > {MAX_ARCHIVE_ENTRIES}"
                )
            total_uncompressed = sum(item.file_size for item in entries)
            if total_uncompressed > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                issues.append(
                    "archive uncompressed size exceeds the limit: "
                    f"{total_uncompressed} > {MAX_ARCHIVE_UNCOMPRESSED_BYTES} bytes"
                )
            names = [item.filename for item in entries]
            if len(names) != len(set(names)):
                issues.append("archive contains duplicate paths")
            folded: dict[str, str] = {}
            for item in entries:
                name = item.filename
                pure = PurePosixPath(name)
                if item.file_size > MAX_ARCHIVE_ENTRY_BYTES:
                    issues.append(
                        f"archive entry exceeds the size limit: {name} "
                        f"({item.file_size} > {MAX_ARCHIVE_ENTRY_BYTES} bytes)"
                    )
                if item.flag_bits & 0x1:
                    issues.append(f"archive contains an encrypted entry: {name}")
                prior = folded.setdefault(name.casefold(), name)
                if prior != name:
                    issues.append(f"archive contains case-colliding paths: {prior} and {name}")
                if (
                    pure.is_absolute()
                    or ".." in pure.parts
                    or "\\" in name
                    or not pure.parts
                    or pure.parts[0] != "Runner.app"
                ):
                    issues.append(f"unsafe or unexpected archive path: {name}")
                mode = item.external_attr >> 16
                if stat.S_ISLNK(mode):
                    issues.append(f"archive contains a symbolic link: {name}")
            if issues:
                return None, issues
            archive.extractall(destination)
            for item in entries:
                mode = stat.S_IMODE(item.external_attr >> 16)
                extracted = destination / PurePosixPath(item.filename)
                if mode and extracted.exists():
                    extracted.chmod(mode)
    except (OSError, zipfile.BadZipFile) as error:
        return None, [f"iOS archive is invalid: {error}"]
    return destination / "Runner.app", issues


def main() -> int:
    args = _arguments()
    if not args.path.exists():
        print(f"iOS artifact is missing: {args.path}", file=sys.stderr)
        return 2

    archive_hash: str | None = None
    if args.path.is_file():
        archive_hash = _sha256(args.path)
        with tempfile.TemporaryDirectory(prefix="ykd-ios-audit-") as temp:
            app, issues = _safe_extract_archive(args.path, Path(temp))
            if app is not None:
                issues.extend(_audit_app(app, args))
    else:
        issues = _audit_app(args.path, args)

    if issues:
        print("iOS artifact audit failed:", file=sys.stderr)
        for issue in issues:
            print(f"- {issue}", file=sys.stderr)
        return 1

    suffix = f"; sha256={archive_hash}" if archive_hash else ""
    signature = "allowed" if args.allow_signature else "false"
    print(
        "iOS offline artifact is clean: "
        f"host={args.host_identifier}; extension={args.extension_identifier}; "
        f"version={args.version}+{args.build}; signed={signature}{suffix}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
