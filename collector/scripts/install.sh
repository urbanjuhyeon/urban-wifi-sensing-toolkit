#!/usr/bin/env bash
set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 0027

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this installer as root: sudo bash install.sh" >&2
  exit 1
fi

REPOSITORY_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT="/opt/urban-sensing"
VENV="${INSTALL_ROOT}/venv"
CONFIG_DIR="/etc/urban-sensing"
CONFIG_PATH="${CONFIG_DIR}/config.json"
KEY_PATH="${CONFIG_DIR}/deployment.key"
SERVICE_USER="urban-sensing"
STATE_DIR="/var/lib/urban-sensing"

clean_local_build_artifacts() {
  local artifact
  for artifact in "${REPOSITORY_ROOT}/build" "${REPOSITORY_ROOT}/src/"*.egg-info; do
    if [[ ! -e "${artifact}" && ! -L "${artifact}" ]]; then
      continue
    fi
    if [[ -L "${artifact}" || ! -d "${artifact}" ]]; then
      echo "Refusing unexpected build-artifact path: ${artifact}" >&2
      exit 1
    fi
    rm -rf -- "${artifact}"
  done
}

# Extracting a newer ZIP over an older source directory can leave setuptools
# build output behind. Remove it before building so stale Python modules cannot
# be packaged under a newer version number.
clean_local_build_artifacts

if [[ -e /etc/systemd/system/sensing.service ||
      -e /lib/systemd/system/sensing.service ||
      -e /usr/lib/systemd/system/sensing.service ]] ||
  { command -v systemctl >/dev/null 2>&1 && systemctl cat sensing.service >/dev/null 2>&1; }; then
  echo "Refusing installation while the legacy root sensing.service exists." >&2
  echo "Follow MIGRATION.md, verify restricted historical data, then remove the legacy unit." >&2
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && {
  systemctl is-active --quiet urban-wifi-capture.service 2>/dev/null ||
    systemctl is-active --quiet urban-wifi-interfaces.service 2>/dev/null
}; then
  echo "Stop both urban WiFi services before installing or upgrading." >&2
  echo "  systemctl stop urban-wifi-capture.service urban-wifi-interfaces.service" >&2
  exit 1
fi

echo "Installing operating-system dependencies..."
export DEBIAN_FRONTEND=noninteractive
APT_RETRY_OPTIONS=(
  -o Acquire::Retries=5
  -o Acquire::http::Timeout=30
  -o Acquire::https::Timeout=30
)

apt_failure_help() {
  cat >&2 <<'EOF'

Operating-system package installation failed.
If the output above contains "Failed to fetch" and names an unreachable mirror,
the failure is in the configured Raspbian/Debian package mirror, not in the
collector. Retry after the mirror is reachable, or select a current mirror in
the Raspberry Pi OS APT source file. Do not hard-code a mirror copied from an
older walkthrough without confirming that it is current and reachable.

After repairing APT, restart this installer from the collector directory:
  sudo bash install.sh
EOF
}

if ! apt-get "${APT_RETRY_OPTIONS[@]}" update; then
  apt_failure_help
  exit 1
fi

if ! apt-get "${APT_RETRY_OPTIONS[@]}" install -y --no-install-recommends \
  build-essential \
  g++ \
  iproute2 \
  iw \
  libpcap-dev \
  python3 \
  python3-dev \
  python3-pip \
  python3-venv \
  sqlite3; then
  apt_failure_help
  exit 1
fi

if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${SERVICE_USER}"
else
  service_entry="$(getent passwd "${SERVICE_USER}")"
  service_shell="${service_entry##*:}"
  if [[ "${service_shell}" != "/usr/sbin/nologin" && "${service_shell}" != "/bin/false" ]]; then
    echo "Refusing existing ${SERVICE_USER} account with an interactive shell." >&2
    exit 1
  fi
  if [[ "$(id -G "${SERVICE_USER}" | wc -w)" -ne 1 ]]; then
    echo "Refusing ${SERVICE_USER} account with supplementary groups." >&2
    exit 1
  fi
fi

install -d -o root -g root -m 0755 "${INSTALL_ROOT}"
if [[ -L "${VENV}" || ( -e "${VENV}" && ! -d "${VENV}" ) ]]; then
  echo "Refusing unexpected virtual-environment path: ${VENV}" >&2
  exit 1
fi
VENV_STAGE="$(mktemp -d "${INSTALL_ROOT}/.venv-stage.XXXXXX")"
VENV_BACKUP="${INSTALL_ROOT}/.venv-previous"
cleanup_stage() {
  rm -rf -- "${VENV_STAGE}"
}
trap cleanup_stage EXIT
python3 -m venv "${VENV_STAGE}"
"${VENV_STAGE}/bin/python" -m pip install --no-cache-dir --require-hashes \
  -r "${REPOSITORY_ROOT}/requirements-build.txt"
"${VENV_STAGE}/bin/python" -m pip install --no-cache-dir --require-hashes \
  --no-build-isolation -r "${REPOSITORY_ROOT}/requirements.txt"
"${VENV_STAGE}/bin/python" -m pip install --no-cache-dir --no-deps \
  --no-build-isolation "${REPOSITORY_ROOT}"
clean_local_build_artifacts
if [[ -e "${VENV_BACKUP}" ]]; then
  rm -rf -- "${VENV_BACKUP}"
fi
if [[ -d "${VENV}" ]]; then
  mv -- "${VENV}" "${VENV_BACKUP}"
fi
if ! mv -- "${VENV_STAGE}" "${VENV}"; then
  if [[ -d "${VENV_BACKUP}" ]]; then
    mv -- "${VENV_BACKUP}" "${VENV}"
  fi
  exit 1
fi
trap - EXIT
rm -rf -- "${VENV_BACKUP}"

# Console scripts created in the staging virtual environment contain an
# absolute shebang. Rewrite those shebangs after the atomic move so commands
# such as pip do not keep pointing at the deleted staging directory.
for script in "${VENV}/bin/"*; do
  if [[ -f "${script}" && ! -L "${script}" ]]; then
    first_line="$(head -n 1 -- "${script}" 2>/dev/null || true)"
    case "${first_line}" in
      "#!${VENV_STAGE}/bin/python"*)
        sed -i "1c\\#!${VENV}/bin/python" "${script}"
        ;;
    esac
  fi
done
install -o root -g root -m 0755 \
  "${REPOSITORY_ROOT}/scripts/urban-wifi-capture.sh" \
  "${VENV}/bin/urban-wifi-capture"
install -d -o root -g root -m 0755 "${INSTALL_ROOT}/share"
install -o root -g root -m 0644 \
  "${REPOSITORY_ROOT}/README.md" \
  "${REPOSITORY_ROOT}/LICENSE" \
  "${REPOSITORY_ROOT}/MIGRATION.md" \
  "${REPOSITORY_ROOT}/PRIVACY.md" \
  "${REPOSITORY_ROOT}/PROVENANCE.md" \
  "${REPOSITORY_ROOT}/SECURITY.md" \
  "${REPOSITORY_ROOT}/THIRD_PARTY_NOTICES.md" \
  "${REPOSITORY_ROOT}/docs/HARDWARE_TEST.md" \
  "${REPOSITORY_ROOT}/requirements.txt" \
  "${REPOSITORY_ROOT}/requirements-build.txt" \
  "${INSTALL_ROOT}/share/"
chown -R root:root "${INSTALL_ROOT}"
# The service account must be able to traverse and read the root-owned runtime.
# Keep it non-writable while restoring read/traverse bits masked by umask 0027.
chmod -R a+rX,go-w "${INSTALL_ROOT}"

if [[ -L "${CONFIG_DIR}" || ( -e "${CONFIG_DIR}" && ! -d "${CONFIG_DIR}" ) ]]; then
  echo "Refusing non-directory or symlinked configuration path: ${CONFIG_DIR}" >&2
  exit 1
fi
install -d -o root -g "${SERVICE_USER}" -m 0750 "${CONFIG_DIR}"
if [[ ! -e "${CONFIG_PATH}" ]]; then
  install -o root -g "${SERVICE_USER}" -m 0640 \
    "${REPOSITORY_ROOT}/config.example.json" "${CONFIG_PATH}"
  echo "Created ${CONFIG_PATH}; edit sensor and interface values before capture."
else
  if [[ -L "${CONFIG_PATH}" || ! -f "${CONFIG_PATH}" ]]; then
    echo "Refusing non-regular or symlinked configuration: ${CONFIG_PATH}" >&2
    exit 1
  fi
  chown root:"${SERVICE_USER}" "${CONFIG_PATH}"
  chmod 0640 "${CONFIG_PATH}"
  echo "Preserved existing ${CONFIG_PATH}."
fi

if [[ -e "${KEY_PATH}" || -L "${KEY_PATH}" ]]; then
  if [[ -L "${KEY_PATH}" || ! -f "${KEY_PATH}" ]]; then
    echo "Refusing non-regular or symlinked deployment key: ${KEY_PATH}" >&2
    exit 1
  fi
  if [[ "$(stat -c '%h' "${KEY_PATH}")" -ne 1 ]]; then
    echo "Refusing hardlinked deployment key: ${KEY_PATH}" >&2
    exit 1
  fi
  if [[ "$(wc -c < "${KEY_PATH}")" -ne 32 ]]; then
    echo "Refusing deployment key that is not exactly 32 raw bytes: ${KEY_PATH}" >&2
    exit 1
  fi
  chown root:"${SERVICE_USER}" "${KEY_PATH}"
  chmod 0640 "${KEY_PATH}"
  echo "Preserved and protected existing ${KEY_PATH}."
else
  echo "No deployment key was created; provision one approved shared key before validation."
fi

for state_path in "${STATE_DIR}" "${STATE_DIR}/data"; do
  if [[ -L "${state_path}" || ( -e "${state_path}" && ! -d "${state_path}" ) ]]; then
    echo "Refusing non-directory or symlinked state path: ${state_path}" >&2
    exit 1
  fi
done
install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0700 \
  "${STATE_DIR}" "${STATE_DIR}/data"

install -o root -g root -m 0644 \
  "${REPOSITORY_ROOT}/systemd/urban-wifi-interfaces.service" \
  /etc/systemd/system/urban-wifi-interfaces.service
install -o root -g root -m 0644 \
  "${REPOSITORY_ROOT}/systemd/urban-wifi-capture.service" \
  /etc/systemd/system/urban-wifi-capture.service

systemctl daemon-reload
if command -v systemd-analyze >/dev/null 2>&1; then
  systemd-analyze verify \
    /etc/systemd/system/urban-wifi-interfaces.service \
    /etc/systemd/system/urban-wifi-capture.service
fi

cat <<'EOF'

Installation complete. Capture was NOT enabled or started.

1. Generate one deployment key on exactly one secured provisioning host, then
   copy that same 32-byte file to every sensor in this deployment. Never run
   generate-key independently on each sensor:
   sudo /opt/urban-sensing/venv/bin/urban-wifi-capture generate-key \
     --output /etc/urban-sensing/deployment.key
   sudo chown root:urban-sensing /etc/urban-sensing/deployment.key
   sudo chmod 0640 /etc/urban-sensing/deployment.key
2. Edit /etc/urban-sensing/config.json. Use the same deployment_id on every
   sensor in the deployment; only sensor_name and interfaces vary by sensor.
3. Validate as the service account:
   sudo -u urban-sensing /opt/urban-sensing/venv/bin/urban-wifi-capture validate \
     --config /etc/urban-sensing/config.json
4. Confirm ethics/site/data-security approval and synchronized system time.
5. Follow /opt/urban-sensing/share/HARDWARE_TEST.md before enabling field collection.
EOF
