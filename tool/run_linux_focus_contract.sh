#!/usr/bin/env bash

set -euo pipefail

build_dir="${1:-build/linux/x64/debug}"
openbox >"$build_dir/openbox.out" 2>"$build_dir/openbox.err" &
window_manager_pid=$!
cleanup() {
  kill "$window_manager_pid" 2>/dev/null || true
  wait "$window_manager_pid" 2>/dev/null || true
}
trap cleanup EXIT

window_manager_ready=0
for _ in {1..100}; do
  if xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id'; then
    window_manager_ready=1
    break
  fi
  if ! kill -0 "$window_manager_pid" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
if [[ "$window_manager_ready" -ne 1 ]]; then
  cat "$build_dir/openbox.out"
  cat "$build_dir/openbox.err" >&2
  exit 1
fi

if ! GDK_BACKEND=x11 YKD_REQUIRE_WINDOW_MANAGER=1 ctest \
  --test-dir "$build_dir" \
  --output-on-failure \
  -R 'linux_native_bridge_plugin_lifecycle|wayland_global_shortcuts_plugin_contract'; then
  cat "$build_dir/openbox.out"
  cat "$build_dir/openbox.err" >&2
  exit 1
fi
