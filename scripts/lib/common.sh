#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DOCS_DIR="${ROOT_DIR}/docs"
STATE_DIR="${ROOT_DIR}/state"
STATE_FILE="${STATE_DIR}/install-state.json"
STATE_LIST_FILE="${STATE_DIR}/completed_steps.list"
STATE_ENV_FILE="${STATE_DIR}/runtime.env"
STEP_LOG_FILE="${DOCS_DIR}/STEP_LOG.md"
USER_LOG_DIR="${HOME}/.local/state/blip-waydroid"
USER_LOG_FILE="${USER_LOG_DIR}/runtime.log"

mkdir -p "${DOCS_DIR}" "${STATE_DIR}" "${USER_LOG_DIR}"

if [ ! -f "${STEP_LOG_FILE}" ]; then
  {
    printf "# Blip Waydroid Step Log\n\n"
    printf "This file is updated by install scripts after each successful step.\n"
  } > "${STEP_LOG_FILE}"
fi

if [ ! -f "${STATE_LIST_FILE}" ]; then
  : > "${STATE_LIST_FILE}"
fi

if [ ! -f "${STATE_ENV_FILE}" ]; then
  : > "${STATE_ENV_FILE}"
fi

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_info() {
  printf "[INFO] %s\n" "$*"
}

log_warn() {
  printf "[WARN] %s\n" "$*" >&2
}

log_error() {
  printf "[ERROR] %s\n" "$*" >&2
}

append_runtime_log() {
  printf "%s %s\n" "$(timestamp_utc)" "$*" >> "${USER_LOG_FILE}"
}

step_completed() {
  local step="$1"
  grep -Fxq "${step}" "${STATE_LIST_FILE}"
}

list_completed_steps_json() {
  local first=1
  while IFS= read -r step; do
    [ -z "${step}" ] && continue
    if [ "${first}" -eq 1 ]; then
      printf '    "%s"' "${step}"
      first=0
    else
      printf ',\n    "%s"' "${step}"
    fi
  done < "${STATE_LIST_FILE}"
  if [ "${first}" -eq 1 ]; then
    printf ""
  fi
}

get_state_value() {
  local key="$1"
  if grep -Eq "^${key}=" "${STATE_ENV_FILE}"; then
    sed -n "s/^${key}=//p" "${STATE_ENV_FILE}" | tail -n 1
  fi
}

set_state_value() {
  local key="$1"
  local value="$2"
  if grep -Eq "^${key}=" "${STATE_ENV_FILE}"; then
    sed -i "s|^${key}=.*$|${key}=${value}|" "${STATE_ENV_FILE}"
  else
    printf "%s=%s\n" "${key}" "${value}" >> "${STATE_ENV_FILE}"
  fi
  write_state_json
}

write_state_json() {
  local now package_name package_activity distro_name distro_codename
  now="$(timestamp_utc)"
  package_name="$(get_state_value blip_package || true)"
  package_activity="$(get_state_value blip_activity || true)"
  distro_name="$(get_state_value distro_name || true)"
  distro_codename="$(get_state_value distro_codename || true)"

  {
    printf "{\n"
    printf "  \"schema\": 1,\n"
    printf "  \"updated_at\": \"%s\",\n" "${now}"
    printf "  \"distro\": {\n"
    printf "    \"name\": \"%s\",\n" "${distro_name}"
    printf "    \"codename\": \"%s\"\n" "${distro_codename}"
    printf "  },\n"
    printf "  \"runtime\": {\n"
    printf "    \"blip_package\": \"%s\",\n" "${package_name}"
    printf "    \"blip_activity\": \"%s\"\n" "${package_activity}"
    printf "  },\n"
    printf "  \"completed_steps\": [\n"
    list_completed_steps_json
    printf "\n  ]\n"
    printf "}\n"
  } > "${STATE_FILE}"
}

mark_step_completed() {
  local step="$1"
  if ! step_completed "${step}"; then
    printf "%s\n" "${step}" >> "${STATE_LIST_FILE}"
  fi
  write_state_json
}

log_step_success() {
  local step="$1"
  local details="$2"
  {
    printf -- '- %s `%s` OK: %s\n' "$(timestamp_utc)" "${step}" "${details}"
  } >> "${STEP_LOG_FILE}"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    log_error "Missing required command: ${cmd}"
    exit 1
  fi
}

run_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

detect_distro() {
  if [ ! -f /etc/os-release ]; then
    log_error "/etc/os-release not found. Unsupported system."
    exit 1
  fi

  # shellcheck source=/dev/null
  . /etc/os-release

  local id_l id_like codename
  id_l="${ID:-unknown}"
  id_like="${ID_LIKE:-}"
  codename="${VERSION_CODENAME:-}"

  if [ -z "${codename}" ] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi

  set_state_value "distro_name" "${id_l}"
  set_state_value "distro_codename" "${codename}"

  case "${id_l}" in
    ubuntu|debian|zorin)
      return 0
      ;;
    *)
      if printf "%s" "${id_like}" | grep -Eqi "ubuntu|debian"; then
        return 0
      fi
      ;;
  esac

  log_error "Unsupported distro base: ID=${id_l}, ID_LIKE=${id_like}"
  log_error "This installer supports Ubuntu/Debian derivatives, with focus on ZorinOS 18."
  exit 1
}

validate_wayland_or_x11() {
  if [ -n "${WAYLAND_DISPLAY:-}" ] || [ -n "${DISPLAY:-}" ]; then
    return 0
  fi
  log_warn "No graphical session variables detected (WAYLAND_DISPLAY/DISPLAY)."
}

ensure_systemd_available() {
  if command -v systemctl >/dev/null 2>&1; then
    return 0
  fi

  if [ -f /run/.containerenv ] || [ -n "${FLATPAK_ID:-}" ] || ps -p 1 -o comm= 2>/dev/null | grep -qi "^bwrap$"; then
    log_error "No systemd detected in this shell (container/Flatpak runtime)."
    log_error "Run this installer from the host terminal session (outside Flatpak/Toolbox/Distrobox)."
    log_error "Then rerun: ./scripts/install.sh"
    exit 1
  fi

  log_error "Missing required command: systemctl"
  exit 1
}

wait_for_waydroid_session() {
  local attempts="${1:-25}"
  local delay="${2:-2}"
  local i
  for i in $(seq 1 "${attempts}"); do
    if waydroid status 2>/dev/null | grep -qi "Session:.*RUNNING"; then
      return 0
    fi
    sleep "${delay}"
  done
  return 1
}
