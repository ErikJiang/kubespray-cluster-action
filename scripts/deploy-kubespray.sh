#!/bin/bash
set -e

# Input parameters (expected as environment variables)
# INPUT_CONTAINER_NAME: Name of the container
# CONTAINER_IP: IP address of the container
# KUBESPRAY_DIR: Path to the checked-out Kubespray directory
# HOME: User's home directory (automatically available)
# GITHUB_OUTPUT: Path to GitHub Actions output file (set by runner)

echo "--- Starting Kubespray Deployment ---"

# Ensure KUBESPRAY_DIR is set
if [ -z "$KUBESPRAY_DIR" ]; then
  echo "Error: KUBESPRAY_DIR environment variable is not set."
  exit 1
fi
if [ ! -d "$KUBESPRAY_DIR" ]; then
  echo "Error: Kubespray directory '$KUBESPRAY_DIR' not found."
  exit 1
fi

SSH_PRIVATE_KEY_PATH="$HOME/.ssh/id_rsa_kubespray"
KUBECONFIG_PATH="$HOME/.kube/config"

# 1. Setup Kubespray (venv and requirements)
echo "Setting up Kubespray in ${KUBESPRAY_DIR}..."
VENV_PATH="${KUBESPRAY_DIR}/kubespray-venv" # Create venv inside kubespray dir or a common workspace location
python -m venv "$VENV_PATH"
# shellcheck source=/dev/null
source "$VENV_PATH/bin/activate"
cd "$KUBESPRAY_DIR"
pip install -r requirements.txt
echo "Kubespray setup complete."

# 2. Deploy Kubernetes
echo "Deploying Kubernetes..."
# Create inventory
cp -rfp inventory/sample inventory/mycluster
cat >inventory/mycluster/hosts.yaml <<EOF
all:
  hosts:
    ${INPUT_CONTAINER_NAME}:
      ansible_host: ${CONTAINER_IP}
      ip: ${CONTAINER_IP}
      ansible_user: root
      ansible_ssh_private_key_file: ${SSH_PRIVATE_KEY_PATH}
      ansible_ssh_common_args: '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
  children:
    kube_control_plane:
      hosts:
        ${INPUT_CONTAINER_NAME}:
    kube_node:
      hosts:
        ${INPUT_CONTAINER_NAME}:
    etcd:
      hosts:
        ${INPUT_CONTAINER_NAME}:
    k8s_cluster:
      children:
        kube_control_plane:
        kube_node:
    calico_rr:
      hosts: {}
EOF
echo "Inventory created at ${KUBESPRAY_DIR}/inventory/mycluster/hosts.yaml"

# Run ansible-playbook
echo "Running Ansible ping..."
ansible -i inventory/mycluster/hosts.yaml all -m ping -v

echo "Running Ansible playbook for cluster deployment..."
ansible-playbook -i inventory/mycluster/hosts.yaml cluster.yml -b -v \
  -e '{"kube_network_plugin": "calico"}' \
  -e '{"kube_owner": "root"}' \
  -e '{"resolvconf_mode": "none"}' \
  -e '{"kubeadm_ignore_preflight_errors": ["SystemVerification"]}' \
  -e '{"kube_proxy_conntrack_max_per_core": 0}' \
  -e '{"kube_proxy_conntrack_tcp_timeout_close_wait": "0s"}' \
  -e '{"kube_proxy_conntrack_tcp_timeout_time_wait": "0s"}' \
  -e '{"enable_nodelocaldns": false}' \
  -e '{"etcd_deployment_type": "kubeadm"}' \
  -e '{"kubelet_fail_swap_on": false}'

if [ $? -ne 0 ]; then
  echo "Error: Ansible playbook execution failed."
  exit 1
fi

echo "Kubernetes deployment complete."
deactivate
cd "$OLDPWD" # Go back to original directory

# 3. Get kubeconfig
echo "Retrieving kubeconfig..."
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
docker cp "${INPUT_CONTAINER_NAME}":/etc/kubernetes/admin.conf "$KUBECONFIG_PATH"

# Update server address in kubeconfig
# Using | as delimiter for sed to avoid issues with slashes in IP/URL
sed -i.bak "s|server: https://[^:]*|server: https://${CONTAINER_IP}|g" "$KUBECONFIG_PATH"
rm -f "${KUBECONFIG_PATH}.bak" # Remove backup file created by sed -i.bak
echo "Kubeconfig saved to ${KUBECONFIG_PATH}"

# Output for GitHub Actions
if [ -n "$GITHUB_OUTPUT" ]; then
  echo "kubeconfig_path=${KUBECONFIG_PATH}" >>"$GITHUB_OUTPUT"
  echo "Output 'kubeconfig_path=${KUBECONFIG_PATH}' to GITHUB_OUTPUT"
fi

# Copy kubectl binary from container
echo "Copying kubectl binary from container..."
if docker cp "${INPUT_CONTAINER_NAME}":/usr/local/bin/kubectl /usr/local/bin/kubectl; then
  chmod +x /usr/local/bin/kubectl
  echo "kubectl copied to /usr/local/bin/kubectl"
else
  echo "Warning: Failed to copy kubectl from container. It might not be available at /usr/local/bin/kubectl."
  echo "Attempting to find kubectl in common paths within the container..."
  KUBECTL_PATH_IN_CONTAINER=$(docker exec "${INPUT_CONTAINER_NAME}" sh -c "command -v kubectl || find / -name kubectl -type f -executable 2>/dev/null | head -n 1")
  if [ -n "$KUBECTL_PATH_IN_CONTAINER" ]; then
    echo "Found kubectl at ${KUBECTL_PATH_IN_CONTAINER} in container. Copying..."
    if docker cp "${INPUT_CONTAINER_NAME}:${KUBECTL_PATH_IN_CONTAINER}" /usr/local/bin/kubectl; then
      chmod +x /usr/local/bin/kubectl
      echo "kubectl copied to /usr/local/bin/kubectl"
    else
      echo "Error: Failed to copy kubectl from ${KUBECTL_PATH_IN_CONTAINER}. Please ensure kubectl is installed in the runner or container."
      exit 1
    fi
  else
    echo "Error: kubectl not found in container. Please ensure kubectl is installed in the runner or container."
    exit 1
  fi
fi

# 4. Test kubectl
echo "Testing kubectl..."
export KUBECONFIG="${KUBECONFIG_PATH}"
if command -v kubectl &>/dev/null; then
  echo "kubectl get nodes:"
  kubectl get nodes -o wide
  echo "kubectl get pods --all-namespaces:"
  kubectl get pods --all-namespaces
  echo "kubectl test complete."
else
  echo "kubectl command not found. Skipping kubectl tests."
fi

echo "--- Kubespray Deployment Finished ---"
