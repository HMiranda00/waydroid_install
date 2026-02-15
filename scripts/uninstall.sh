#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

MODE="${1:-}"
if [ "${MODE}" != "--user-only" ] && [ "${MODE}" != "--full-purge" ]; then
  cat <<'EOF'
Usage:
  scripts/uninstall.sh --user-only
  scripts/uninstall.sh --full-purge
EOF
  exit 1
fi

REMOVED_ITEMS=""
MISSING_ITEMS=""

track_removed() {
  REMOVED_ITEMS="${REMOVED_ITEMS}\n- $1"
}

track_missing() {
  MISSING_ITEMS="${MISSING_ITEMS}\n- $1"
}

remove_path() {
  local path="$1"
  if [ -e "${path}" ]; then
    rm -rf "${path}"
    track_removed "${path}"
  else
    track_missing "${path}"
  fi
}

remove_user_artifacts() {
  remove_path "${HOME}/.local/share/applications/blip-waydroid.desktop"
  remove_path "${HOME}/.config/autostart/blip-waydroid-prewarm.desktop"
  remove_path "${HOME}/.local/bin/blip-waydroid-launch"
  remove_path "${HOME}/.local/bin/blip-waydroid-prewarm"
  remove_path "${HOME}/.local/state/blip-waydroid"
  remove_path "${HOME}/.local/share/icons/blip-waydroid.svg"
  remove_path "${HOME}/.local/share/waydroid"
  remove_path "${HOME}/.config/waydroid"
}

remove_repo_state() {
  remove_path "${STATE_FILE}"
  remove_path "${STATE_LIST_FILE}"
  remove_path "${STATE_ENV_FILE}"
}

remove_system_waydroid() {
  run_sudo systemctl disable --now waydroid-container || true
  run_sudo apt-get purge -y waydroid || true
  run_sudo apt-get autoremove -y || true

  if [ -f /etc/apt/sources.list.d/waydroid.list ]; then
    run_sudo rm -f /etc/apt/sources.list.d/waydroid.list
    track_removed "/etc/apt/sources.list.d/waydroid.list"
  else
    track_missing "/etc/apt/sources.list.d/waydroid.list"
  fi

  if [ -f /etc/apt/keyrings/waydroid.gpg ]; then
    run_sudo rm -f /etc/apt/keyrings/waydroid.gpg
    track_removed "/etc/apt/keyrings/waydroid.gpg"
  else
    track_missing "/etc/apt/keyrings/waydroid.gpg"
  fi

  if [ -d /var/lib/waydroid ]; then
    run_sudo rm -rf /var/lib/waydroid
    track_removed "/var/lib/waydroid"
  else
    track_missing "/var/lib/waydroid"
  fi

  run_sudo apt-get update || true
}

main() {
  log_info "Starting uninstall mode: ${MODE}"

  remove_user_artifacts
  remove_repo_state

  if [ "${MODE}" = "--full-purge" ]; then
    remove_system_waydroid
  fi

  {
    printf "\n## Uninstall report (%s)\n" "$(timestamp_utc)"
    printf "\n### Removed\n%b\n" "${REMOVED_ITEMS:-\n- (none)}"
    printf "\n### Not found\n%b\n" "${MISSING_ITEMS:-\n- (none)}"
  } >> "${STEP_LOG_FILE}"

  printf "Uninstall completed.\n"
  printf "Removed:%b\n" "${REMOVED_ITEMS:-\n- (none)}"
  printf "Not found:%b\n" "${MISSING_ITEMS:-\n- (none)}"
}

main
