#!/bin/bash
set -euo pipefail

# usage
if [ $# -ne 1 ]; then
  echo "usage: $0 <username>"
  exit 1
fi

DEVUSER_NAME="$1"
DEVUSER_HOME="/home/$DEVUSER_NAME"

# ---- prerequisites as root (outside the sudo -u block) ----
echo " - Installing prerequisites for rootless Docker (as root)..."
# As root
sudo apt-get update
sudo apt-get install -y uidmap dbus-user-session slirp4netns fuse-overlayfs tar xz-utils curl
sudo loginctl enable-linger "$DEVUSER_NAME"

# ---- install + enable rootless docker as the target user ----
echo " - Installing rootless Docker for $DEVUSER_NAME (SKIP_IPTABLES=1)..."
sudo -u "$DEVUSER_NAME" -i bash <<'EOF'
sudo -iu "$DEVUSER_NAME"
export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
mkdir -p ~/.local/bin ~/.config/systemd/user

# Run installer verbosely so we can see why it fails, and skip iptables checks
curl -fsSL -o /tmp/docker-rootless.sh https://get.docker.com/rootless
SKIP_IPTABLES=1 sh -x /tmp/docker-rootless.sh

# Now the helper should exist:
command -v dockerd-rootless-setuptool.sh

# Create the systemd unit & start the daemon
dockerd-rootless-setuptool.sh install #--skip-tables
systemctl --user daemon-reload
systemctl --user enable --now docker

# Point the client and test
echo 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock' >> ~/.bashrc
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
docker run --rm hello-world

EOF


echo
echo "✅ Done."
echo "Try: docker info"
echo
