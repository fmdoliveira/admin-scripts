#!/bin/bash
set -euo pipefail

# usage
if [ $# -ne 1 ]; then
    echo "usage: $0 <username>"
    exit 1
fi

DEVUSER_NAME="$1"
DEVUSER_HOME="/home/$DEVUSER_NAME"

RUNNER_USER="$(id -un)"
RUNNER_HOME="$(getent passwd "$RUNNER_USER" | cut -d: -f6)"
RUNNER_SSH_DIR="$RUNNER_HOME/.ssh"

# Key file named by pattern
RUNNER_KEY_FILE="${RUNNER_SSH_DIR}/id_ed25519_${RUNNER_USER}_${DEVUSER_NAME}"
RUNNER_PUBKEY=""

echo "==> Preparing dev user: $DEVUSER_NAME (localhost alias: ssh $DEVUSER_NAME)"

# 1) Create user (no password)
if id "$DEVUSER_NAME" &>/dev/null; then
    echo " - User $DEVUSER_NAME already exists."
else
    echo " - Creating user $DEVUSER_NAME (no password)..."
    sudo adduser --disabled-password --gecos "" "$DEVUSER_NAME"
fi

# Ensure home exists & owned
sudo test -d "$DEVUSER_HOME" || sudo mkdir -p "$DEVUSER_HOME"
sudo chown "$DEVUSER_NAME:$DEVUSER_NAME" "$DEVUSER_HOME"

# Convenience dirs
sudo -u "$DEVUSER_NAME" mkdir -p "$DEVUSER_HOME/repos" "$DEVUSER_HOME/bin" "$DEVUSER_HOME/grimoires" "$DEVUSER_HOME/runes"

# 2) Idempotent .bashrc lines
if ! sudo -u "$DEVUSER_NAME" bash -lc 'grep -qxF "export PATH=$HOME/bin:$PATH" ~/.bashrc'; then
    sudo -u "$DEVUSER_NAME" bash -lc 'echo "export PATH=\$HOME/bin:\$PATH" >> ~/.bashrc'
fi
if ! sudo -u "$DEVUSER_NAME" bash -lc 'grep -qxF "export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock" ~/.bashrc'; then
    sudo -u "$DEVUSER_NAME" bash -lc 'echo "export DOCKER_HOST=unix:///run/user/\$(id -u)/docker.sock" >> ~/.bashrc'
fi

# 3) Ensure the RUNNER has a patterned public key; generate if missing
mkdir -p "$RUNNER_SSH_DIR"
chmod 700 "$RUNNER_SSH_DIR"
if [ ! -f "${RUNNER_KEY_FILE}.pub" ]; then
    echo " - Generating SSH key ${RUNNER_KEY_FILE} (no passphrase)..."
    ssh-keygen -t ed25519 -N "" -f "$RUNNER_KEY_FILE" -C "${RUNNER_USER}@${DEVUSER_NAME}@localhost"
else
    echo " - Using existing key ${RUNNER_KEY_FILE}"
fi
RUNNER_PUBKEY="$(cat "${RUNNER_KEY_FILE}.pub")"

# 4) Install key into target user's authorized_keys (idempotent)
sudo -u "$DEVUSER_NAME" mkdir -p "$DEVUSER_HOME/.ssh"
sudo chmod 700 "$DEVUSER_HOME/.ssh"
sudo touch "$DEVUSER_HOME/.ssh/authorized_keys"
sudo chmod 600 "$DEVUSER_HOME/.ssh/authorized_keys"
sudo chown -R "$DEVUSER_NAME:$DEVUSER_NAME" "$DEVUSER_HOME/.ssh"

if ! sudo -u "$DEVUSER_NAME" bash -lc "grep -qxF '$RUNNER_PUBKEY' ~/.ssh/authorized_keys"; then
    echo " - Installing runner's public key into $DEVUSER_NAME authorized_keys..."
    printf '%s\n' "$RUNNER_PUBKEY" | sudo tee -a "$DEVUSER_HOME/.ssh/authorized_keys" >/dev/null
    sudo chown "$DEVUSER_NAME:$DEVUSER_NAME" "$DEVUSER_HOME/.ssh/authorized_keys"
else
    echo " - Key already present in authorized_keys."
fi

# 5) Seed known_hosts for localhost (avoid interactive prompt)
KNOWN_HOSTS="${RUNNER_SSH_DIR}/known_hosts"
touch "$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"

# Add localhost and 127.0.0.1 host keys idempotently
for H in localhost 127.0.0.1; do
    if ! ssh-keygen -F "$H" -f "$KNOWN_HOSTS" >/dev/null; then
        echo " - Adding $H to known_hosts"
        ssh-keyscan -H "$H" 2>/dev/null >> "$KNOWN_HOSTS" || true
    fi
done

# 6) Update ~/.ssh/config in the RUNNER account so "ssh <username>" hits localhost
SSH_CONFIG_FILE="${RUNNER_SSH_DIR}/config"
MARK_START="# >>> devuser ${DEVUSER_NAME} start"
MARK_END="# <<< devuser ${DEVUSER_NAME} end"

touch "$SSH_CONFIG_FILE"
chmod 600 "$SSH_CONFIG_FILE"

read -r -d '' HOST_BLOCK <<EOF || true
$MARK_START
Host ${DEVUSER_NAME}
    HostName localhost
    User ${DEVUSER_NAME}
    IdentityFile ${RUNNER_KEY_FILE}
    IdentitiesOnly yes
    PubkeyAuthentication yes
$MARK_END
EOF

if grep -qF "$MARK_START" "$SSH_CONFIG_FILE"; then
    echo " - Updating SSH config entry for: ${DEVUSER_NAME}"
    awk -v start="$MARK_START" -v end="$MARK_END" -v repl="$HOST_BLOCK" '
        BEGIN{inblk=0}
        {
            if ($0==start){print repl; inblk=1; next}
            if ($0==end){inblk=0; next}
            if (!inblk) print
        }' "$SSH_CONFIG_FILE" > "${SSH_CONFIG_FILE}.tmp"
    mv "${SSH_CONFIG_FILE}.tmp" "$SSH_CONFIG_FILE"
else
    echo " - Adding SSH config entry for: ${DEVUSER_NAME}"
    printf "\n%s\n" "$HOST_BLOCK" >> "$SSH_CONFIG_FILE"
fi

echo
echo "✅ Done."
echo "Try: ssh ${DEVUSER_NAME}"
echo "or : ssh -i ${RUNNER_KEY_FILE} ${DEVUSER_NAME}@localhost"
echo

