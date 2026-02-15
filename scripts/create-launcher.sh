#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TEMPLATE_FILE="${ROOT_DIR}/templates/blip.desktop.tpl"
WRAPPER_FILE="${HOME}/.local/bin/blip-waydroid-launch"
DESKTOP_FILE="${HOME}/.local/share/applications/blip-waydroid.desktop"
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
mkdir -p "\${LOG_DIR}"
printf "%s launcher start\n" "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "\${LOG_FILE}"

if ! command -v waydroid >/dev/null 2>&1; then
  echo "Waydroid not installed." >&2
  exit 1
fi

waydroid session start >/dev/null 2>&1 || true

for _ in \$(seq 1 30); do
  if waydroid status 2>/dev/null | grep -qi "Session:.*RUNNING"; then
    break
  fi
  sleep 1
done

if ! waydroid status 2>/dev/null | grep -qi "Session:.*RUNNING"; then
  echo "Waydroid session is not running. Check ${LAUNCH_LOG_FILE}" >&2
  exit 1
fi

if ! waydroid shell pm list packages 2>/dev/null | sed 's/^package://g' | grep -Fxq "${PACKAGE_NAME}"; then
  echo "Blip package (${PACKAGE_NAME}) not found. Install/update in Play Store once." >&2
  exit 1
fi

waydroid app launch "${PACKAGE_NAME}" >> "\${LOG_FILE}" 2>&1
EOF

chmod +x "${WRAPPER_FILE}"

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
update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 || true

log_info "Launcher created at ${DESKTOP_FILE}"
append_runtime_log "launcher_created package=${PACKAGE_NAME} activity=${PACKAGE_ACTIVITY}"
