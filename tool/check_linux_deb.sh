#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

for command in cut desktop-file-validate dpkg-deb find grep ldd readelf \
  readlink realpath sed sha256sum sort stat; do
  if ! command -v "$command" >/dev/null; then
    echo "Required Debian validation command is unavailable: $command" >&2
    exit 1
  fi
done

deb=${1:-}
if [[ -z "$deb" ]]; then
  deb=$(find build/release -maxdepth 1 -type f \
    -name 'yandex-keyboard-desktop_*_amd64.deb' -print -quit)
fi
if [[ -z "$deb" || ! -f "$deb" ]]; then
  echo "Debian package is missing: ${deb:-<not found>}" >&2
  exit 1
fi
deb=$(realpath "$deb")

package=$(dpkg-deb -f "$deb" Package)
version=$(dpkg-deb -f "$deb" Version)
architecture=$(dpkg-deb -f "$deb" Architecture)
[[ "$package" == yandex-keyboard-desktop ]]
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]
[[ "$architecture" == amd64 ]]

staging_parent=${TMPDIR:-/tmp}
staging_root=$(mktemp -d "$staging_parent/ykd-deb-check.XXXXXXXX")
case "$staging_root" in
  "$staging_parent"/ykd-deb-check.*) ;;
  *)
    echo "Refusing unsafe validation staging path: $staging_root" >&2
    exit 1
    ;;
esac
cleanup() {
  rm -rf -- "$staging_root"
}
trap cleanup EXIT

root="$staging_root/root"
contents="$staging_root/contents.txt"
dependencies="$staging_root/ldd.txt"
dpkg-deb -x "$deb" "$root"
dpkg-deb --contents "$deb" >"$contents"

unsafe_mode=$(find "$root" ! -type l -perm /022 -print -quit)
if [[ -n "$unsafe_mode" ]]; then
  echo "Group/world-writable installed path is forbidden: $unsafe_mode" >&2
  exit 1
fi

executable="$root/opt/yandex-keyboard-desktop/yandex_keyboard_desktop"
assets="$root/opt/yandex-keyboard-desktop/data/flutter_assets"
[[ -x "$executable" ]]
[[ "$(stat -c %a "$executable")" == 755 ]]
[[ "$(stat -c %a "$assets/assets/brand/symbol.svg")" == 644 ]]
[[ "$(readlink "$root/usr/bin/yandex-keyboard-desktop")" == \
  /opt/yandex-keyboard-desktop/yandex_keyboard_desktop ]]

while IFS= read -r -d '' symlink; do
  installed_path=${symlink#"$root"}
  target=$(readlink "$symlink")
  if [[ "$installed_path" == /usr/bin/yandex-keyboard-desktop \
    && "$target" == /opt/yandex-keyboard-desktop/yandex_keyboard_desktop ]]; then
    continue
  fi
  if [[ "$target" == /* ]]; then
    echo "Unexpected absolute installed symlink is forbidden: $installed_path" >&2
    exit 1
  fi
  resolved=$(realpath -m "$(dirname "$symlink")/$target")
  case "$resolved" in
    "$root"|"$root"/*) ;;
    *)
      echo "Installed symlink escapes the package tree: $installed_path" >&2
      exit 1
      ;;
  esac
done < <(find "$root" -type l -print0 | sort -z)

desktop-file-validate \
  "$root/usr/share/applications/io.github.oniel.yandex_keyboard_desktop.desktop"

LD_LIBRARY_PATH="$root/opt/yandex-keyboard-desktop/lib" \
  ldd "$executable" >"$dependencies"
if grep -q 'not found' "$dependencies"; then
  cat "$dependencies" >&2
  echo "Package has unresolved dynamic libraries." >&2
  exit 1
fi

if grep -Eqi \
  '(^|/)(\.env($|\.)|config\.json$|credentials|secrets?|.*\.pdb$|flutter_acrylic|materialicons)' \
  "$contents"; then
  echo "Package contains a forbidden private or stale payload path." >&2
  grep -Ei \
    '(^|/)(\.env($|\.)|config\.json$|credentials|secrets?|.*\.pdb$|flutter_acrylic|materialicons)' \
    "$contents" >&2
  exit 1
fi

while IFS= read -r -d '' binary; do
  runpath=$(readelf -d "$binary" 2>/dev/null | sed -nE \
    's/.*Library (r|run)path: \[([^]]*)\].*/\2/p')
  IFS=: read -r -a runpath_entries <<<"$runpath"
  for entry in "${runpath_entries[@]}"; do
    if [[ "$entry" == /* ]]; then
      echo "Absolute RUNPATH is forbidden: $binary" >&2
      exit 1
    fi
  done
done < <(find "$root/opt/yandex-keyboard-desktop" -type f \
  \( -name yandex_keyboard_desktop -o -name '*.so' \) -print0 | sort -z)

entries=$(wc -l <"$contents")
hash=$(sha256sum "$deb" | cut -d' ' -f1)
printf '%s\n' \
  "Debian package is clean." \
  "package=$package" \
  "version=$version" \
  "architecture=$architecture" \
  "entries=$entries" \
  "sha256=$hash"
