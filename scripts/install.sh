#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

RESUME_MODE=0
if [ "${1:-}" = "--resume" ]; then
  RESUME_MODE=1
fi

STEP_PRECHECK="precheck_host"
STEP_BASE_INSTALL="install_waydroid_base"
STEP_INIT_GAPPS="init_waydroid_gapps"
STEP_PREWARM="configure_prewarm_session"
STEP_BLIP_INSTALL="install_blip_from_play_store"
STEP_LAUNCHER="create_blip_launcher"
STEP_VALIDATE="validate_setup"

run_step() {
  local step="$1"
  shift
  if step_completed "${step}"; then
    log_info "Skipping already completed step: ${step}"
    return 0
  fi
  "$@"
}

step_precheck_host() {
  log_info "Step: pre-check host"
  require_cmd awk
  require_cmd sed
  require_cmd grep
  require_cmd systemctl
  require_cmd sudo

  detect_distro
  validate_wayland_or_x11

  if ! grep -Eq "binder|ashmem" /proc/modules && [ ! -e /dev/binderfs ]; then
    log_warn "binder/ashmem modules not currently visible. Waydroid may still work with binderfs."
  fi

  mark_step_completed "${STEP_PRECHECK}"
  log_step_success "${STEP_PRECHECK}" "Distro and host prerequisites checked."
}

install_waydroid_repo() {
  if [ -f /etc/apt/sources.list.d/waydroid.list ]; then
    log_info "Waydroid apt source already exists."
    return 0
  fi
  log_info "Adding Waydroid apt source."
  run_sudo apt-get update
  run_sudo apt-get install -y curl ca-certificates
  # Official helper script adds repo/keyring for Debian/Ubuntu derivatives.
  curl -s https://repo.waydro.id | run_sudo bash
}

step_install_waydroid_base() {
  log_info "Step: install Waydroid base"
  require_cmd apt-get
  require_cmd curl

  install_waydroid_repo

  run_sudo apt-get update
  run_sudo apt-get install -y waydroid
  run_sudo systemctl enable --now waydroid-container

  local waydroid_version
  waydroid_version="$(waydroid --version 2>/dev/null || echo "unknown")"

  mark_step_completed "${STEP_BASE_INSTALL}"
  log_step_success "${STEP_BASE_INSTALL}" "Waydroid installed (${waydroid_version}) and container service enabled."
}

step_init_waydroid_gapps() {
  log_info "Step: initialize Waydroid with GAPPS image"
  require_cmd waydroid

  if [ ! -d /var/lib/waydroid/images ] || [ -z "$(ls -A /var/lib/waydroid/images 2>/dev/null || true)" ]; then
    run_sudo waydroid init -s GAPPS
  else
    log_info "Waydroid images already present, skipping re-init."
  fi

  run_sudo systemctl restart waydroid-container
  waydroid session start || true

  if ! wait_for_waydroid_session 30 2; then
    log_warn "Waydroid session did not report RUNNING yet. Continuing; launcher wrapper will retry at runtime."
  fi

  mark_step_completed "${STEP_INIT_GAPPS}"
  log_step_success "${STEP_INIT_GAPPS}" "Waydroid GAPPS initialized and session start attempted."
}

step_configure_prewarm_session() {
  log_info "Step: configure pre-warm session on login"
  local autostart_dir prewarm_script autostart_file
  autostart_dir="${HOME}/.config/autostart"
  prewarm_script="${HOME}/.local/bin/blip-waydroid-prewarm"
  autostart_file="${autostart_dir}/blip-waydroid-prewarm.desktop"

  mkdir -p "${autostart_dir}" "${HOME}/.local/bin"

  cat > "${prewarm_script}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if command -v waydroid >/dev/null 2>&1; then
  waydroid session start >/dev/null 2>&1 || true
fi
EOF
  chmod +x "${prewarm_script}"

  cat > "${autostart_file}" <<EOF
[Desktop Entry]
Type=Application
Name=Blip Waydroid Prewarm
Comment=Starts Waydroid session silently at login for faster Blip launch.
Exec=${prewarm_script}
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

  mark_step_completed "${STEP_PREWARM}"
  log_step_success "${STEP_PREWARM}" "Autostart prewarm configured at ${autostart_file}."
}

detect_blip_package() {
  local candidate
  candidate="$(
    (waydroid app list 2>/dev/null || true) \
      | grep -Eio '[a-zA-Z0-9_]+(\.[a-zA-Z0-9_]+){2,}' \
      | grep -Ei 'blip' \
      | head -n 1 || true
  )"

  if [ -z "${candidate}" ]; then
    candidate="$(
      (waydroid shell pm list packages 2>/dev/null || true) \
        | sed 's/^package://g' \
        | grep -Ei 'blip' \
        | head -n 1 || true
    )"
  fi

  printf "%s" "${candidate}"
}

detect_blip_activity() {
  local pkg="$1"
  local activity
  activity="$(
    waydroid shell cmd package resolve-activity --brief "${pkg}" 2>/dev/null \
      | tail -n 1 || true
  )"
  printf "%s" "${activity}"
}

step_install_blip_from_play_store() {
  log_info "Step: install Blip from Play Store (interactive)"
  waydroid session start || true
  if ! wait_for_waydroid_session 30 2; then
    log_warn "Waydroid session still not RUNNING. Continue if Play Store can open."
  fi

  log_info "Opening Play Store in Waydroid. Install Blip, then return to this terminal."
  waydroid app launch com.android.vending >/dev/null 2>&1 || true

  printf "\nInstall Blip in Play Store, then press ENTER to continue..."
  # shellcheck disable=SC2034
  read -r _

  local pkg activity
  pkg="$(detect_blip_package)"
  if [ -z "${pkg}" ]; then
    printf "Could not auto-detect Blip package. Paste package id (example format com.vendor.app): "
    read -r pkg
  fi
  if [ -z "${pkg}" ]; then
    log_error "No package id provided."
    exit 1
  fi

  activity="$(detect_blip_activity "${pkg}")"
  set_state_value "blip_package" "${pkg}"
  set_state_value "blip_activity" "${activity}"

  mark_step_completed "${STEP_BLIP_INSTALL}"
  log_step_success "${STEP_BLIP_INSTALL}" "Blip package detected: ${pkg}; activity: ${activity}."
}

step_create_launcher() {
  log_info "Step: create Blip native launcher"
  "${SCRIPT_DIR}/create-launcher.sh"

  mark_step_completed "${STEP_LAUNCHER}"
  log_step_success "${STEP_LAUNCHER}" "Native .desktop launcher created in user applications."
}

step_validate_setup() {
  log_info "Step: validation checklist"
  local pkg
  pkg="$(get_state_value blip_package || true)"
  if [ -z "${pkg}" ]; then
    log_error "Validation failed: missing blip_package in state."
    exit 1
  fi

  if [ ! -f "${HOME}/.local/share/applications/blip-waydroid.desktop" ]; then
    log_error "Validation failed: launcher file not found."
    exit 1
  fi

  {
    printf "\nValidation checklist:\n"
    printf "1. Open app from menu: Blip (Waydroid)\n"
    printf "2. Confirm login persists after reboot\n"
    printf "3. Confirm notifications are delivered\n"
    printf "4. Confirm no manual Android UI open is needed\n\n"
  } >> "${STEP_LOG_FILE}"

  mark_step_completed "${STEP_VALIDATE}"
  log_step_success "${STEP_VALIDATE}" "Basic validations generated. Manual checks pending in STEP_LOG.md."
}

main() {
  log_info "Starting installer (resume=${RESUME_MODE})"
  write_state_json

  run_step "${STEP_PRECHECK}" step_precheck_host
  run_step "${STEP_BASE_INSTALL}" step_install_waydroid_base
  run_step "${STEP_INIT_GAPPS}" step_init_waydroid_gapps
  run_step "${STEP_PREWARM}" step_configure_prewarm_session
  run_step "${STEP_BLIP_INSTALL}" step_install_blip_from_play_store
  run_step "${STEP_LAUNCHER}" step_create_launcher
  run_step "${STEP_VALIDATE}" step_validate_setup

  log_info "Install flow completed."
  log_info "State file: ${STATE_FILE}"
  log_info "Step log: ${STEP_LOG_FILE}"
}

main "$@"

