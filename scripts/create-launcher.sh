#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TEMPLATE_FILE="${ROOT_DIR}/templates/blip.desktop.tpl"
WRAPPER_FILE="${HOME}/.local/bin/blip-waydroid-launch"
WAYLAND_WRAPPER_FILE="${HOME}/.local/bin/blip-waydroid-wayland-launch"
DESKTOP_FILE="${HOME}/.local/share/applications/blip-waydroid.desktop"
WAYLAND_DESKTOP_FILE="${HOME}/.local/share/applications/blip-waydroid-wayland.desktop"
ICON_FILE="${HOME}/.local/share/icons/blip-waydroid.svg"
LAUNCH_LOG_DIR="${HOME}/.local/state/blip-waydroid"
LAUNCH_LOG_FILE="${LAUNCH_LOG_DIR}/launcher.log"

mkdir -p "$(dirname "${WRAPPER_FILE}")" "$(dirname "${DESKTOP_FILE}")" "${LAUNCH_LOG_DIR}" "$(dirname "${ICON_FILE}")"

PACKAGE_NAME="$(get_state_value blip_package || true)"
PACKAGE_ACTIVITY="$(get_state_value blip_activity || true)"

if [ -z "${PACKAGE_NAME}" ]; then
  log_error "Missing blip_package in state. Run install step for Play Store first."
  exit 1
fi

cat > "${WRAPPER_FILE}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="\${HOME}/.local/state/blip-waydroid"
LOG_FILE="\${LOG_DIR}/launcher.log"
WESTON_LOG="\${LOG_DIR}/weston.log"
WAYDROID_BIN="/usr/bin/waydroid"
WESTON_BIN="/usr/bin/weston"
mkdir -p "\${LOG_DIR}"
printf "%s launcher start\n" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\${LOG_FILE}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"

if [ ! -x "\${WAYDROID_BIN}" ]; then
  echo "Waydroid not installed." >&2
  exit 1
fi

if [ -z "\${WAYLAND_DISPLAY:-}" ] || [ ! -S "/run/user/\$(id -u)/\${WAYLAND_DISPLAY}" ]; then
  if [ -n "\${DISPLAY:-}" ]; then
    if [ ! -x "\${WESTON_BIN}" ]; then
      echo "X11 detected and weston is missing. Install it: sudo apt-get install -y weston" >&2
      exit 1
    fi

    WESTON_SOCKET="wayland-1"
    if [ ! -S "/run/user/\$(id -u)/\${WESTON_SOCKET}" ]; then
      nohup "\${WESTON_BIN}" --backend=x11-backend.so --socket="\${WESTON_SOCKET}" --xwayland --fullscreen >> "\${WESTON_LOG}" 2>&1 &
      for _ in \$(seq 1 20); do
        if [ -S "/run/user/\$(id -u)/\${WESTON_SOCKET}" ]; then
          break
        fi
        sleep 1
      done
    fi

    if [ ! -S "/run/user/\$(id -u)/\${WESTON_SOCKET}" ]; then
      echo "Could not start Weston's Wayland socket. Check \${WESTON_LOG}" >&2
      exit 1
    fi
    export WAYLAND_DISPLAY="\${WESTON_SOCKET}"
    printf "%s using nested weston socket=%s\n" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "\${WAYLAND_DISPLAY}" >> "\${LOG_FILE}"
  else
    echo "No graphical session detected (missing DISPLAY/WAYLAND_DISPLAY)." >&2
    exit 1
  fi
fi

"\${WAYDROID_BIN}" session start >/dev/null 2>&1 || true

for _ in \$(seq 1 30); do
  if "\${WAYDROID_BIN}" status 2>/dev/null | grep -qi "Session:.*RUNNING"; then
    break
  fi
  sleep 1
done

if ! "\${WAYDROID_BIN}" status 2>/dev/null | grep -qi "Session:.*RUNNING"; then
  if "\${WAYDROID_BIN}" status 2>&1 | grep -qi "not initialized"; then
    echo "Waydroid is not initialized. Run: sudo waydroid init -s GAPPS" >&2
  else
    echo "Waydroid session is not running. Check ${LAUNCH_LOG_FILE}" >&2
  fi
  exit 1
fi

# Ensure a visible surface exists in fresh boots (prevents blank Weston window).
"\${WAYDROID_BIN}" show-full-ui >> "\${LOG_FILE}" 2>&1 &
sleep 2

pkg_seen=0
for _ in \$(seq 1 25); do
  if "\${WAYDROID_BIN}" app list 2>/dev/null | grep -Fq "packageName: ${PACKAGE_NAME}"; then
    pkg_seen=1
    break
  fi
  sleep 1
done

if [ "\${pkg_seen}" -ne 1 ]; then
  printf "%s package_not_seen=%s\n" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${PACKAGE_NAME}" >> "\${LOG_FILE}"
fi

launched=0
for _ in \$(seq 1 20); do
  if "\${WAYDROID_BIN}" app launch "${PACKAGE_NAME}" >> "\${LOG_FILE}" 2>&1; then
    launched=1
    break
  fi
  sleep 1
done

if [ "\${launched}" -ne 1 ]; then
  # Fallback: open full UI once, then launch app again.
  "\${WAYDROID_BIN}" show-full-ui >> "\${LOG_FILE}" 2>&1 || true
  sleep 2
  "\${WAYDROID_BIN}" app launch "${PACKAGE_NAME}" >> "\${LOG_FILE}" 2>&1
fi
EOF

chmod +x "${WRAPPER_FILE}"

cat > "${WAYLAND_WRAPPER_FILE}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="\${HOME}/.local/state/blip-waydroid"
LOG_FILE="\${LOG_DIR}/launcher-wayland.log"
WAYDROID_BIN="/usr/bin/waydroid"
mkdir -p "\${LOG_DIR}"
printf "%s launcher start\n" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\${LOG_FILE}"
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/run/user/\$(id -u)}"

if [ ! -x "\${WAYDROID_BIN}" ]; then
  echo "Waydroid not installed." >&2
  exit 1
fi

if [ -z "\${WAYLAND_DISPLAY:-}" ] || [ ! -S "/run/user/\$(id -u)/\${WAYLAND_DISPLAY}" ]; then
  echo "Wayland session not detected. Use this launcher from a native Wayland login." >&2
  exit 1
fi

"\${WAYDROID_BIN}" session start >/dev/null 2>&1 || true
for _ in \$(seq 1 30); do
  if "\${WAYDROID_BIN}" status 2>/dev/null | grep -qi "Session:.*RUNNING"; then
    break
  fi
  sleep 1
done

"\${WAYDROID_BIN}" app launch "${PACKAGE_NAME}" >> "\${LOG_FILE}" 2>&1
EOF

chmod +x "${WAYLAND_WRAPPER_FILE}"

if [ ! -f "${ICON_FILE}" ]; then
  cat > "${ICON_FILE}" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="48" fill="#0A84FF"/>
  <path d="M76 52h54c35 0 58 18 58 46 0 16-8 29-24 36 21 6 32 20 32 40 0 34-26 54-69 54H76V52zm41 71c18 0 28-7 28-20 0-12-10-19-28-19h-6v39h6zm7 73c20 0 31-8 31-23 0-14-11-22-31-22h-13v45h13z" fill="#FFFFFF"/>
</svg>
EOF
fi

if [ ! -f "${TEMPLATE_FILE}" ]; then
  log_error "Template not found: ${TEMPLATE_FILE}"
  exit 1
fi

sed \
  -e "s|__BLIP_EXEC__|${WRAPPER_FILE}|g" \
  -e "s|__BLIP_ICON__|${ICON_FILE}|g" \
  "${TEMPLATE_FILE}" > "${DESKTOP_FILE}"

chmod 644 "${DESKTOP_FILE}"

sed \
  -e "s|Blip (Waydroid)|Blip (Wayland)|g" \
  -e "s|Launch Blip directly inside Waydroid|Launch Blip on native Wayland session|g" \
  -e "s|__BLIP_EXEC__|${WAYLAND_WRAPPER_FILE}|g" \
  -e "s|__BLIP_ICON__|${ICON_FILE}|g" \
  "${TEMPLATE_FILE}" > "${WAYLAND_DESKTOP_FILE}"

chmod 644 "${WAYLAND_DESKTOP_FILE}"
update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 || true

log_info "Launchers created at ${DESKTOP_FILE} and ${WAYLAND_DESKTOP_FILE}"
append_runtime_log "launcher_created package=${PACKAGE_NAME} activity=${PACKAGE_ACTIVITY}"
