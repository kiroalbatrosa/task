#!/usr/bin/env bash
set -Eeuo pipefail

readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly MINIKUBE_VERSION="${MINIKUBE_VERSION:-v1.39.0}"
readonly KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.37.0}"
readonly MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-devops-assignment}"
readonly MINIKUBE_CPUS="${MINIKUBE_CPUS:-2}"
readonly MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-3072}"
readonly IMAGE_REPOSITORY="${IMAGE_REPOSITORY:-ghcr.io/kiroalbatrosa/task}"
readonly IMAGE_TAG="${IMAGE_TAG:-latest}"
readonly GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
readonly GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
readonly SETUP_PHASE="${SETUP_PHASE:-bootstrap}"

export PATH="/usr/local/bin:${PATH}"

log() {
  printf '\n==> %s\n' "$1"
}

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 1
}

ensure_bootstrap_packages() {
  local missing=()

  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  command -v install >/dev/null 2>&1 || missing+=(coreutils)
  command -v getent >/dev/null 2>&1 || missing+=(libc-bin)
  command -v grep >/dev/null 2>&1 || missing+=(grep)
  command -v runuser >/dev/null 2>&1 || missing+=(util-linux)
  command -v sed >/dev/null 2>&1 || missing+=(sed)
  command -v usermod >/dev/null 2>&1 || missing+=(passwd)

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "Bootstrap utilities already present."
    return
  fi

  command -v apt-get >/dev/null 2>&1 || \
    fail "Missing ${missing[*]}. Automatic installation currently supports Debian and Ubuntu only."

  log "Installing bootstrap utilities: ${missing[*]}"
  apt-get update
  env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

detect_architecture() {
  case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) fail "Unsupported CPU architecture: $(uname -m). Supported architectures are amd64 and arm64." ;;
  esac
}

download_verified_binary() {
  local name="$1"
  local binary_url="$2"
  local checksum_url="$3"
  local destination="$4"
  local download_dir binary_file checksum_file expected_checksum

  download_dir="$(mktemp -d)"
  binary_file="${download_dir}/${name}"
  checksum_file="${binary_file}.sha256"

  echo "Downloading ${name}..."
  curl --fail --location --silent --show-error --output "${binary_file}" "${binary_url}"
  curl --fail --location --silent --show-error --output "${checksum_file}" "${checksum_url}"

  expected_checksum="$(tr -d '[:space:]' < "${checksum_file}")"
  [[ "${expected_checksum}" =~ ^[[:xdigit:]]{64}$ ]] || \
    fail "The downloaded ${name} checksum is not valid."
  printf '%s  %s\n' "${expected_checksum}" "${binary_file}" | sha256sum --check --status || \
    fail "Checksum verification failed for ${name}."

  install -o root -g root -m 0755 "${binary_file}" "${destination}"
  rm -rf "${download_dir:?}"
}

ensure_minikube() {
  local candidate architecture
  architecture="$(detect_architecture)"
  candidate="$(command -v minikube 2>/dev/null || true)"

  if [[ -n "${candidate}" ]]; then
    echo "Minikube $("${candidate}" version --short 2>/dev/null || echo unknown) already present at ${candidate}."
    return
  fi

  log "Installing Minikube ${MINIKUBE_VERSION} system-wide"
  download_verified_binary \
    minikube \
    "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${architecture}" \
    "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-${architecture}.sha256" \
    /usr/local/bin/minikube
  hash -r
}

kubectl_is_compatible() {
  local candidate="$1"
  local version_json client_major client_minor target target_major target_minor difference

  version_json="$("${candidate}" version --client --output=json 2>/dev/null)" || return 1
  client_major="$(printf '%s\n' "${version_json}" | sed -nE 's/^[[:space:]]*"major":[[:space:]]*"([0-9]+)".*/\1/p' | head -n 1)"
  client_minor="$(printf '%s\n' "${version_json}" | sed -nE 's/^[[:space:]]*"minor":[[:space:]]*"([0-9]+).*/\1/p' | head -n 1)"
  target="${KUBERNETES_VERSION#v}"
  target_major="${target%%.*}"
  target="${target#*.}"
  target_minor="${target%%.*}"

  [[ -n "${client_major}" && -n "${client_minor}" ]] || return 1
  [[ "${client_major}" == "${target_major}" ]] || return 1
  difference=$((client_minor - target_minor))
  ((difference < 0)) && difference=$((-difference))
  ((difference <= 1))
}

ensure_kubectl() {
  local candidate architecture installed_version
  architecture="$(detect_architecture)"
  candidate="$(command -v kubectl 2>/dev/null || true)"

  if [[ -n "${candidate}" ]] && kubectl_is_compatible "${candidate}"; then
    installed_version="$("${candidate}" version --client --output=json 2>/dev/null | sed -nE 's/.*"gitVersion":[[:space:]]*"([^"]+)".*/\1/p' | head -n 1)"
    echo "Compatible kubectl ${installed_version:-unknown} already present at ${candidate}."
    return
  fi

  if [[ -n "${candidate}" ]]; then
    echo "kubectl at ${candidate} is not within one minor version of Kubernetes ${KUBERNETES_VERSION}."
  fi
  log "Installing kubectl ${KUBERNETES_VERSION} system-wide"
  download_verified_binary \
    kubectl \
    "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${architecture}/kubectl" \
    "https://dl.k8s.io/release/${KUBERNETES_VERSION}/bin/linux/${architecture}/kubectl.sha256" \
    /usr/local/bin/kubectl
  hash -r
}

install_docker() {
  local distribution codename repository_architecture key_file sources_file

  [[ -r /etc/os-release ]] || \
    fail "Cannot identify this operating system. Install Docker manually and rerun this script."

  # shellcheck disable=SC1091
  source /etc/os-release
  distribution="${ID:-}"
  case "${distribution}" in
    ubuntu)
      codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
      ;;
    debian)
      codename="${VERSION_CODENAME:-}"
      ;;
    *)
      fail "Automatic Docker installation supports Debian and Ubuntu only. Install Docker manually and rerun."
      ;;
  esac

  [[ -n "${codename}" ]] || fail "Could not determine the operating-system codename for Docker's repository."
  command -v dpkg >/dev/null 2>&1 || fail "dpkg is required for automatic Docker installation."
  repository_architecture="$(dpkg --print-architecture)"
  key_file="$(mktemp)"
  sources_file="$(mktemp)"

  log "Installing Docker Engine from Docker's official apt repository"
  curl --fail --location --silent --show-error \
    --output "${key_file}" \
    "https://download.docker.com/linux/${distribution}/gpg"

  printf '%s\n' \
    'Types: deb' \
    "URIs: https://download.docker.com/linux/${distribution}" \
    "Suites: ${codename}" \
    'Components: stable' \
    "Architectures: ${repository_architecture}" \
    'Signed-By: /etc/apt/keyrings/docker.asc' > "${sources_file}"

  install -m 0755 -d /etc/apt/keyrings
  install -m 0644 "${key_file}" /etc/apt/keyrings/docker.asc
  install -m 0644 "${sources_file}" /etc/apt/sources.list.d/docker.sources
  rm -f "${key_file}" "${sources_file}"

  apt-get update
  env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

start_docker_daemon() {
  if command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker; then
    return
  fi
  if command -v service >/dev/null 2>&1; then
    service docker start || true
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    install_docker
  else
    echo "Docker CLI already present at $(command -v docker)."
  fi

  if ! docker info >/dev/null 2>&1; then
    start_docker_daemon
  fi
  if ! docker info >/dev/null 2>&1 && ! command -v dockerd >/dev/null 2>&1; then
    echo "Docker CLI is present, but Docker Engine is missing."
    install_docker
    start_docker_daemon
  fi
  if docker info >/dev/null 2>&1; then
    echo "Docker daemon is available."
    return
  fi

  fail "Docker is installed, but its daemon is unavailable. Start Docker and rerun this script."
}

resolve_deployment_identity() {
  local requested_user repository_owner passwd_entry

  requested_user="${SETUP_DEPLOY_USER:-${SUDO_USER:-}}"
  if [[ -z "${requested_user}" || "${requested_user}" == "root" ]]; then
    repository_owner="$(stat -c '%U' "${ROOT_DIR}")"
    if [[ -n "${repository_owner}" && "${repository_owner}" != "root" ]]; then
      requested_user="${repository_owner}"
    fi
  fi

  [[ -n "${requested_user}" && "${requested_user}" != "root" ]] || \
    fail "Could not determine a non-root deployment user. Set SETUP_DEPLOY_USER when running the script."
  id "${requested_user}" >/dev/null 2>&1 || fail "Deployment user '${requested_user}' does not exist."

  passwd_entry="$(getent passwd "${requested_user}")"
  [[ -n "${passwd_entry}" ]] || fail "Could not read the account information for '${requested_user}'."
  DEPLOYMENT_USER="${requested_user}"
  DEPLOYMENT_HOME="$(printf '%s\n' "${passwd_entry}" | cut -d: -f6)"
  [[ -d "${DEPLOYMENT_HOME}" ]] || fail "Home directory '${DEPLOYMENT_HOME}' does not exist."
}

ensure_deployment_user_can_use_docker() {
  if runuser --user "${DEPLOYMENT_USER}" -- \
      env HOME="${DEPLOYMENT_HOME}" PATH="${PATH}" docker info >/dev/null 2>&1; then
    echo "Docker is available to deployment user '${DEPLOYMENT_USER}'."
    return
  fi

  getent group docker >/dev/null 2>&1 || \
    fail "Docker is running, but no docker group exists for non-root access."
  command -v usermod >/dev/null 2>&1 || fail "usermod is required to configure Docker group access."

  log "Granting Docker access to deployment user '${DEPLOYMENT_USER}'"
  usermod -aG docker "${DEPLOYMENT_USER}"

  runuser --user "${DEPLOYMENT_USER}" -- \
    env HOME="${DEPLOYMENT_HOME}" PATH="${PATH}" docker info >/dev/null 2>&1 || \
    fail "Docker is running, but '${DEPLOYMENT_USER}' still cannot access it."
}

continue_as_deployment_user() {
  log "Continuing cluster setup as '${DEPLOYMENT_USER}'"
  exec runuser --user "${DEPLOYMENT_USER}" -- \
    env -u KUBECONFIG -u MINIKUBE_HOME -u DOCKER_CONFIG \
      HOME="${DEPLOYMENT_HOME}" \
      USER="${DEPLOYMENT_USER}" \
      LOGNAME="${DEPLOYMENT_USER}" \
      PATH="${PATH}" \
      SETUP_PHASE=deploy \
      "MINIKUBE_VERSION=${MINIKUBE_VERSION}" \
      "KUBERNETES_VERSION=${KUBERNETES_VERSION}" \
      "MINIKUBE_PROFILE=${MINIKUBE_PROFILE}" \
      "MINIKUBE_CPUS=${MINIKUBE_CPUS}" \
      "MINIKUBE_MEMORY=${MINIKUBE_MEMORY}" \
      "IMAGE_REPOSITORY=${IMAGE_REPOSITORY}" \
      "IMAGE_TAG=${IMAGE_TAG}" \
      "GRAFANA_ADMIN_USER=${GRAFANA_ADMIN_USER}" \
      "GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}" \
      "${BASH_SOURCE[0]}"
}

if [[ "$(uname -s)" != "Linux" ]]; then
  fail "This automated bootstrap currently supports Linux only."
fi

if [[ "${SETUP_PHASE}" == "bootstrap" ]]; then
  [[ "${EUID}" -eq 0 ]] || fail "Run this script with sudo: sudo ./scripts/setup.sh"

  log "Checking and installing system prerequisites"
  ensure_bootstrap_packages
  resolve_deployment_identity
  ensure_docker
  ensure_minikube
  ensure_kubectl
  ensure_deployment_user_can_use_docker
  continue_as_deployment_user
elif [[ "${SETUP_PHASE}" == "deploy" ]]; then
  [[ "${EUID}" -ne 0 ]] || fail "The cluster deployment phase must not run as root."
  echo "Running cluster deployment as $(id -un)."
else
  fail "Unknown setup phase '${SETUP_PHASE}'."
fi

if ! minikube status --profile "${MINIKUBE_PROFILE}" --format='{{.Host}}' 2>/dev/null | grep -Fxq Running; then
  log "Creating Minikube profile '${MINIKUBE_PROFILE}'"
  minikube start \
    --profile "${MINIKUBE_PROFILE}" \
    --driver docker \
    --container-runtime containerd \
    --kubernetes-version "${KUBERNETES_VERSION}" \
    --cpus "${MINIKUBE_CPUS}" \
    --memory "${MINIKUBE_MEMORY}" \
    --ports "127.0.0.1:3000:30000" \
    --ports "127.0.0.1:9090:30090" \
    --ports "127.0.0.1:3001:30300"
else
  echo "Reusing running Minikube profile '${MINIKUBE_PROFILE}'."
fi

kubectl config use-context "${MINIKUBE_PROFILE}" >/dev/null

log "Creating namespaces and the local Grafana credential secret"
kubectl apply -f "${ROOT_DIR}/k8s/namespaces.yaml"
kubectl --namespace observability create secret generic grafana-admin \
  --from-literal="admin-user=${GRAFANA_ADMIN_USER}" \
  --from-literal="admin-password=${GRAFANA_ADMIN_PASSWORD}" \
  --dry-run=client \
  --output=yaml | kubectl apply -f -

app_deployment_existed=false
prometheus_deployment_existed=false
grafana_deployment_existed=false
kubectl --namespace app get deployment/devops-assignment >/dev/null 2>&1 && app_deployment_existed=true
kubectl --namespace observability get deployment/prometheus >/dev/null 2>&1 && prometheus_deployment_existed=true
kubectl --namespace observability get deployment/grafana >/dev/null 2>&1 && grafana_deployment_existed=true

log "Applying the application and observability manifests"
kubectl apply -k "${ROOT_DIR}/k8s"
kubectl --namespace app set image deployment/devops-assignment \
  "app=${IMAGE_REPOSITORY}:${IMAGE_TAG}"

if [[ "${app_deployment_existed}" == "true" ]]; then
  kubectl --namespace app rollout restart deployment/devops-assignment
fi
if [[ "${prometheus_deployment_existed}" == "true" ]]; then
  kubectl --namespace observability rollout restart deployment/prometheus
fi
if [[ "${grafana_deployment_existed}" == "true" ]]; then
  kubectl --namespace observability rollout restart deployment/grafana
fi

log "Waiting for workloads to become available"
kubectl --namespace app rollout status deployment/devops-assignment --timeout=180s
kubectl --namespace observability rollout status deployment/prometheus --timeout=180s
kubectl --namespace observability rollout status deployment/grafana --timeout=180s

log "Checking the application endpoint"
health_check_succeeded=false
for _ in {1..30}; do
  if curl --fail --silent --show-error http://localhost:3000/health >/dev/null; then
    health_check_succeeded=true
    break
  fi
  sleep 2
done

if [[ "${health_check_succeeded}" != "true" ]]; then
  fail "The workloads are available, but http://localhost:3000/health did not respond."
fi

printf '\nSetup complete.\n'
printf 'Application: http://localhost:3000\n'
printf 'Prometheus:  http://localhost:9090\n'
printf 'Grafana:     http://localhost:3001\n'
printf 'Grafana login: %s / %s\n\n' "${GRAFANA_ADMIN_USER}" "${GRAFANA_ADMIN_PASSWORD}"
printf 'Application image: %s:%s\n' "${IMAGE_REPOSITORY}" "${IMAGE_TAG}"
printf 'Generate traffic with: curl http://localhost:3000/health\n'
printf 'Remove the cluster with: minikube delete --profile %s\n' "${MINIKUBE_PROFILE}"
