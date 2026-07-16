#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

for command in dpkg-deb dpkg-shlibdeps readelf readlink realpath sort tar; do
  if ! command -v "$command" >/dev/null; then
    echo "Required packaging command is unavailable: $command" >&2
    exit 1
  fi
done

bundle=build/linux/x64/release/bundle
if [[ ! -x "$bundle/yandex_keyboard_desktop" ]]; then
  echo "Release bundle is missing; run flutter build linux --release first." >&2
  exit 1
fi

version=${YKD_VERSION:-$(
  awk '/^version:/ { split($2, parts, "+"); print parts[1]; exit }' pubspec.yaml
)}
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  echo "Invalid package version: $version" >&2
  exit 1
fi

output_dir="$repo_root/build/release"
install -d "$output_dir"
staging_parent=/tmp
staging_root=$(mktemp -d "$staging_parent/ykd-deb.XXXXXXXX")
case "$staging_root" in
  "$staging_parent"/ykd-deb.*) ;;
  *)
    echo "Refusing unsafe packaging staging path: $staging_root" >&2
    exit 1
    ;;
esac
cleanup() {
  rm -rf -- "$staging_root"
}
trap cleanup EXIT

package_root="$staging_root/linux-deb-root"
metadata_root="$staging_root/debian-metadata"
output="$output_dir/yandex-keyboard-desktop_${version}_amd64.deb"
install -d \
  "$package_root/DEBIAN" \
  "$package_root/opt/yandex-keyboard-desktop" \
  "$package_root/usr/bin" \
  "$package_root/usr/share/applications" \
  "$package_root/usr/share/doc/yandex-keyboard-desktop" \
  "$package_root/usr/share/icons/hicolor/256x256/apps" \
  "$metadata_root/debian"

tar --sort=name -C "$bundle" -cf - . | \
  tar -C "$package_root/opt/yandex-keyboard-desktop" -xf -
ln -s /opt/yandex-keyboard-desktop/yandex_keyboard_desktop \
  "$package_root/usr/bin/yandex-keyboard-desktop"
install -m 0644 packaging/linux/io.github.oniel.yandex_keyboard_desktop.desktop \
  "$package_root/usr/share/applications/io.github.oniel.yandex_keyboard_desktop.desktop"
install -m 0644 assets/brand/app_icon.png \
  "$package_root/usr/share/icons/hicolor/256x256/apps/io.github.oniel.yandex_keyboard_desktop.png"
install -m 0644 LICENSE \
  "$package_root/usr/share/doc/yandex-keyboard-desktop/copyright"
install -m 0644 packaging/linux/debian/control \
  "$metadata_root/debian/control"

find "$package_root" -type d -exec chmod 0755 {} +
find "$package_root" -type f -exec chmod 0644 {} +
chmod 0755 \
  "$package_root/opt/yandex-keyboard-desktop/yandex_keyboard_desktop"
find "$package_root/opt/yandex-keyboard-desktop/lib" \
  -maxdepth 1 -type f -name '*.so' -exec chmod 0755 {} +

while IFS= read -r -d '' symlink; do
  installed_path=${symlink#"$package_root"}
  target=$(readlink "$symlink")
  if [[ "$installed_path" == /usr/bin/yandex-keyboard-desktop \
    && "$target" == /opt/yandex-keyboard-desktop/yandex_keyboard_desktop ]]; then
    continue
  fi
  if [[ "$target" == /* ]]; then
    echo "Unexpected absolute payload symlink is forbidden: $installed_path" >&2
    exit 1
  fi
  resolved=$(realpath -m "$(dirname "$symlink")/$target")
  case "$resolved" in
    "$package_root"|"$package_root"/*) ;;
    *)
      echo "Payload symlink escapes the package tree: $installed_path" >&2
      exit 1
      ;;
  esac
done < <(find "$package_root" -type l -print0 | sort -z)

while IFS= read -r -d '' binary; do
  runpath=$(readelf -d "$binary" 2>/dev/null | sed -nE \
    's/.*Library (r|run)path: \[([^]]*)\].*/\2/p')
  IFS=: read -r -a runpath_entries <<<"$runpath"
  for entry in "${runpath_entries[@]}"; do
    if [[ "$entry" == /* ]]; then
      echo "Absolute RUNPATH is forbidden in release bundles: $binary" >&2
      exit 1
    fi
  done
done < <(find "$bundle" -type f \
  \( -name yandex_keyboard_desktop -o -name '*.so' \) -print0 | sort -z)

binary_arguments=(
  "-e$package_root/opt/yandex-keyboard-desktop/yandex_keyboard_desktop"
)
while IFS= read -r -d '' library; do
  binary_arguments+=("-e$library")
done < <(find "$package_root/opt/yandex-keyboard-desktop/lib" \
  -maxdepth 1 -type f -name '*.so' -print0 | sort -z)

shlibs_output=$(
  cd "$metadata_root"
  dpkg-shlibdeps -O \
    "-S$package_root" \
    "-l$package_root/opt/yandex-keyboard-desktop/lib" \
    "${binary_arguments[@]}"
)
runtime_dependencies=${shlibs_output#shlibs:Depends=}
if [[ "$runtime_dependencies" == "$shlibs_output" \
  || -z "$runtime_dependencies" ]]; then
  echo "dpkg-shlibdeps returned no runtime dependency set." >&2
  exit 1
fi

dynamic_runtime_dependencies='libegl1, libgles2, libgl1-mesa-dri'

cat >"$package_root/DEBIAN/control" <<EOF
Package: yandex-keyboard-desktop
Version: $version
Section: utils
Priority: optional
Architecture: amd64
Maintainer: Oniel
Depends: $dynamic_runtime_dependencies, $runtime_dependencies
Installed-Size: $(du -sk "$package_root/opt/yandex-keyboard-desktop" | cut -f1)
Description: Privacy-conscious selected-text assistant
 A capability-based desktop assistant with configurable global shortcuts,
 transactional clipboard recovery, and English/Russian localization.
EOF

chmod 0755 "$package_root/DEBIAN"
chmod 0644 "$package_root/DEBIAN/control"

if [[ -z "${SOURCE_DATE_EPOCH:-}" ]]; then
  SOURCE_DATE_EPOCH=$(git log -1 --format=%ct 2>/dev/null || true)
fi
if [[ ! "${SOURCE_DATE_EPOCH:-}" =~ ^[0-9]+$ ]]; then
  echo "SOURCE_DATE_EPOCH must be a Unix timestamp." >&2
  exit 1
fi
export SOURCE_DATE_EPOCH
while IFS= read -r -d '' path; do
  touch --no-dereference --date="@$SOURCE_DATE_EPOCH" "$path"
done < <(find "$package_root" -depth -print0 | sort -z)

unsafe_mode=$(find "$package_root" ! -type l -perm /022 -print -quit)
if [[ -n "$unsafe_mode" ]]; then
  echo "Group/world-writable payload path is forbidden: $unsafe_mode" >&2
  exit 1
fi

dpkg-deb --root-owner-group --build "$package_root" "$output"
dpkg-deb --info "$output"
echo "$output"
