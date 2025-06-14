#!/bin/bash
set -e

# Input parameters (expected as environment variables)
# INPUT_CONTAINER_NAME: Name of the container
# IMAGE_TAG: Tag for the ghcr.io/erikjiang/systemd-node image
# HOME: User's home directory (automatically available)
# GITHUB_OUTPUT: Path to GitHub Actions output file (set by runner)

echo "--- Starting Node Preparation ---"

# 1. Start container
echo "Starting container ${INPUT_CONTAINER_NAME} with image tag ${IMAGE_TAG}..."
docker network create kubespray-net || true
docker run -d \
  --name "${INPUT_CONTAINER_NAME}" \
  --hostname "${INPUT_CONTAINER_NAME}" \
  --privileged \
  --security-opt "seccomp=unconfined" \
  --security-opt "apparmor=unconfined" \
  --security-opt "label=disable" \
  --ipc private \
  --cgroupns host \
  --shm-size 64m \
  --network kubespray-net \
  --volume /dev:/dev:rshared \
  --volume /tmp:/tmp:rshared \
  --volume /run:/run:rshared \
  --volume /sys:/sys:rshared \
  --volume /dev/mapper:/dev/mapper \
  --volume /lib/modules:/lib/modules:ro \
  --volume /var/lib/docker \
  --volume /var/lib/containerd \
  --device /dev/fuse \
  --cap-add SYS_ADMIN \
  --cap-add NET_ADMIN \
  --cap-add SYS_RESOURCE \
  --publish 6443:6443 \
  --dns=8.8.8.8 --dns=8.8.4.4 \
  "ghcr.io/erikjiang/systemd-node:${IMAGE_TAG}" \
  /sbin/init

if [ $? -ne 0 ]; then
  echo "Failed to start container ${INPUT_CONTAINER_NAME}. Please check Docker logs."
  docker logs "${INPUT_CONTAINER_NAME}"
  exit 1
fi

echo "Container ${INPUT_CONTAINER_NAME} started successfully."

# 2. Wait for container to be ready
echo "Waiting for container ${INPUT_CONTAINER_NAME} to be ready..."
timeout_seconds=180
interval_seconds=5
elapsed_seconds=0

until docker exec "${INPUT_CONTAINER_NAME}" systemctl is-system-running --wait &>/dev/null; do
  if [ "$elapsed_seconds" -ge "$timeout_seconds" ]; then
    echo "Timeout: Container ${INPUT_CONTAINER_NAME} did not become ready in $timeout_seconds seconds."
    echo "Dumping container logs:"
    docker logs "${INPUT_CONTAINER_NAME}"
    exit 1
  fi
  sleep "$interval_seconds"
  elapsed_seconds=$((elapsed_seconds + interval_seconds))
  echo "Still waiting for container... ($elapsed_seconds/$timeout_seconds s)"
done
echo "Container ${INPUT_CONTAINER_NAME} is ready."

# 3. Get container info
echo "Getting container IP address..."
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${INPUT_CONTAINER_NAME}")
if [ -z "$CONTAINER_IP" ]; then
  echo "Failed to get container IP address."
  exit 1
fi
echo "Container IP: ${CONTAINER_IP}"

# Output for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "container_ip=${CONTAINER_IP}" >>"$GITHUB_OUTPUT"
  echo "Output 'container_ip=${CONTAINER_IP}' to GITHUB_OUTPUT"
fi

# 4. Setup SSH
echo "Setting up SSH..."
SSH_DIR="$HOME/.ssh"
SSH_KEY_PATH="$SSH_DIR/id_rsa_kubespray"
mkdir -p "$SSH_DIR"
if [ ! -f "$SSH_KEY_PATH" ]; then
  ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N ""
  echo "Generated new SSH key pair at ${SSH_KEY_PATH}"
else
  echo "Using existing SSH key pair at ${SSH_KEY_PATH}"
fi
chmod 600 "$SSH_KEY_PATH"

# Ensure sshpass is installed or handle its absence
if ! command -v sshpass &>/dev/null; then
  echo "sshpass could not be found. Attempting to install..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get update && sudo apt-get install -y sshpass
  elif command -v yum &>/dev/null; then
    sudo yum install -y sshpass
  elif command -v brew &>/dev/null; then # For macOS self-hosted runners
    brew install hudochenkov/sshpass/sshpass
  else
    echo "Cannot determine package manager to install sshpass. Please install it manually."
    exit 1
  fi
fi

echo "Copying SSH public key to root@${CONTAINER_IP}..."
# Use sudo for sshpass if the script runner doesn't have direct permissions for ssh-copy-id to modify known_hosts system-wide,
# or if sshpass itself requires it. Often, ssh-copy-id manages user's known_hosts fine without sudo.
# However, the original script used sudo, so keeping it for consistency unless it causes issues.
# Consider if `sudo` is truly needed here or if `sshpass -p "kubespray" ssh-copy-id ...` is sufficient.
# For now, retaining sudo as per original.
sudo sshpass -p "kubespray" ssh-copy-id \
  -i "${SSH_KEY_PATH}.pub" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "root@${CONTAINER_IP}"
echo "SSH setup complete."

echo "--- Node Preparation Finished ---"
