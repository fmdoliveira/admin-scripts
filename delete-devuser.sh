#!/bin/bash
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <username>"
  exit 1
fi

DEVUSER_NAME="$1"
DEVUSER_HOME="/home/$DEVUSER_NAME"

RUNNER_USER="$(id -un)"
RUNNER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
RUNNER_SSH_DIR="$RUNNER_HOME/.ssh"
RUNNER_KEY_FILE="${RUNNER_SSH_DIR}/id_ed25519_${RUNNER_USER}_${DEVUSER_NAME}"
SSH_CONFIG_FILE="${RUNNER_SSH_DIR}/config"
MARK_START="# >>> devuser ${DEVUSER_NAME} start"
MARK_END="# <<< devuser ${DEVUSER_NAME} end"

echo "==> Deleting dev user: $DEVUSER_NAME"

# 1) If user exists, stop rootless Docker and uninstall helper
if id "$DEVUSER_NAME" &>/dev/null; then
  echo " - Stopping rootless Docker (if any)…"
  sudo -iu "$DEVUSER_NAME" bash -lc '
    systemctl --user stop docker 2>/dev/null || true
    systemctl --user disable docker 2>/dev/null || true
    dockerd-rootless-setuptool.sh uninstall 2>/dev/null || true
  ' || true

  echo " - Disabling lingering…"
  sudo loginctl disable-linger "$DEVUSER_NAME" || true

  echo " - Terminating user processes…"
  sudo loginctl terminate-user "$DEVUSER_NAME" || sudo pkill -u "$DEVUSER_NAME" || true
  sleep 3

  # Optional: remove crontab
  sudo crontab -r -u "$DEVUSER_NAME" 2>/dev/null || true

  echo " - Removing user and home directory…"
  sudo userdel -r "$DEVUSER_NAME" || {
    echo "   userdel failed. Check for remaining processes or mounts." >&2
    exit 1
  }
else
  echo " - User $DEVUSER_NAME does not exist. Skipping userdel."
fi

# 2) Clean SSH config block from the runner
if [ -f "$SSH_CONFIG_FILE" ]; then
  if grep -qF "$MARK_START" "$SSH_CONFIG_FILE"; then
    echo " - Removing SSH config block for ${DEVUSER_NAME}"
    awk -v start="$MARK_START" -v end="$MARK_END" '
      BEGIN{inblk=0}
      {
        if ($0==start){inblk=1; next}
        if ($0==end){inblk=0; next}
        if (!inblk) print
      }' "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp"
    mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"
    chmod 600 "$SSH_CONFIG_FILE"
  else
    echo " - No SSH config block found for ${DEVUSER_NAME}"
  fi
fi

# 3) Remove the patterned keypair from the runner
echo " - Removing patterned keypair (if present)…"
rm -f "${RUNNER_KEY_FILE}" "${RUNNER_KEY_FILE}.pub"

# 4) Sanity cleanup for lingering state dirs (harmless if absent)
sudo rm -f "/var/lib/systemd/linger/${DEVUSER_NAME}" 2>/dev/null || true

echo "✅ Deleted ${DEVUSER_NAME} gracefully."
