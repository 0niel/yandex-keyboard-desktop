#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if ! command -v docker >/dev/null; then
  echo "Docker is required for the clean Debian package smoke." >&2
  exit 1
fi

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
image=${YKD_DEB_SMOKE_IMAGE:-ubuntu:22.04}

docker run --rm \
  --volume "$deb:/tmp/yandex-keyboard-desktop.deb:ro" \
  "$image" bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install --yes \
      /tmp/yandex-keyboard-desktop.deb xvfb dbus-x11 desktop-file-utils
    test "$(dpkg-query -W -f=\${db:Status-Status} \
      yandex-keyboard-desktop)" = installed
    test -x /usr/bin/yandex-keyboard-desktop
    desktop-file-validate \
      /usr/share/applications/io.github.oniel.yandex_keyboard_desktop.desktop

    set +e
    env -u WAYLAND_DISPLAY GDK_BACKEND=x11 \
      GALLIUM_DRIVER=softpipe LIBGL_ALWAYS_SOFTWARE=1 \
      dbus-run-session -- xvfb-run -a timeout --kill-after=2s 8s \
      /usr/bin/yandex-keyboard-desktop \
      >/tmp/ykd-package.out 2>/tmp/ykd-package.err
    status=$?
    set -e
    cat /tmp/ykd-package.out
    cat /tmp/ykd-package.err >&2
    test "$status" -eq 124
    ! grep -E \
      "Unhandled Exception|MissingPluginException|PlatformException|CRITICAL|Segmentation|Assertion|BadWindow|double free|invalid pointer" \
      /tmp/ykd-package.err
    echo "Installed Debian package remained healthy for the bounded Xvfb smoke."
  '
