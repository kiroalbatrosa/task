# Local automated Kubernetes cluster and observability

This repository contains a containerized TypeScript/Express application, a two-job GitHub Actions pipeline, a reproducible local Minikube cluster, and a preconfigured Prometheus and Grafana monitoring stack.

## Quick start

The automated bootstrap supports 64-bit Debian or Ubuntu Linux on `amd64` and `arm64`. Start with a regular user that has `sudo` access, an internet connection, at least 2 CPUs, 3 GB of available memory, and approximately 20 GB of free disk space.

From the repository root, run the single bootstrap command:

```bash
sudo ./scripts/setup.sh
```

The script checks prerequisites before making changes. It reuses compatible installed components and installs only what is missing:

- base download/checksum utilities are installed with `apt` when necessary;
- Docker Engine is installed system-wide from Docker's official `apt` repository only when Docker is absent or only a client without a local engine is present;
- Minikube is reused from the system `PATH` when present; otherwise, the pinned binary is checksum-verified and installed into `/usr/local/bin`;
- a system `kubectl` within one minor release of the configured Kubernetes version is reused; otherwise, a checksum-verified compatible version is installed into `/usr/local/bin`;
- a Helm client that supports resource adoption is reused; otherwise, pinned Helm v4 is checksum-verified and installed into `/usr/local/bin`;
- an installed but stopped Docker daemon is started, and Docker group access is configured when required.

It then creates or reuses the Minikube cluster, resolves the public application tag to an immutable GHCR digest, and runs one atomic `helm upgrade --install` for the complete stack. Every invocation changes a pod-template rollout token, so an existing application, Prometheus, and Grafana deployment are replaced and checked for readiness. `make setup` remains available as a convenience when `make` is installed, but `make` is not a bootstrap prerequisite.

The initial process runs as root so prerequisite installation never invokes nested `sudo` commands. Before creating the cluster, the script switches to the user who invoked `sudo`; Minikube state, kubeconfig, and deployments therefore remain owned by that regular user. When the script is launched directly by a root automation account, set `SETUP_DEPLOY_USER` to the non-root account that should own the local cluster.

| Component | URL | Notes |
| --- | --- | --- |
| Application | <http://localhost:3000> | `/health`, `/ready`, and `/metrics` are available |
| Prometheus | <http://localhost:9090> | Check **Status > Target health** for the app targets |
| Grafana | <http://localhost:3001> | Log in with `admin` / `admin` by default |

For a non-default local Grafana password:

```bash
sudo env GRAFANA_ADMIN_PASSWORD='choose-a-local-password' ./scripts/setup.sh
```

Generate a little traffic and then open the provisioned **Assignment / DevOps Assignment Application** dashboard:

```bash
for i in {1..20}; do curl --silent http://localhost:3000/health >/dev/null; done
```

Remove the local cluster with:

```bash
minikube delete --profile devops-assignment
```

Alternatively, use `make destroy` when `make` is available.

## Architecture

```text
Browser / curl
    |
    +-- localhost:3000 --> Minikube NodePort --> Node.js Service --> 2 application pods
    |                                                |          /health (liveness)
    |                                                |          /ready  (readiness)
    |                                                +--------> /metrics
    |
    +-- localhost:9090 --> Prometheus -- Kubernetes discovery --+
    |                         |
    +-- localhost:3001 --> Grafana --> Prometheus datasource
```

Minikube was selected because it provides a familiar local Kubernetes environment and works with Docker. The setup uses Minikube's Docker driver, pulls the public application image from GitHub Container Registry, and maps the three fixed NodePorts to loopback-only host ports. A single local Helm chart owns the namespaces, workloads, Services, RBAC, Secret, and generated configuration resources.

Prometheus uses Kubernetes endpoint discovery and an intentionally small, namespace-scoped, read-only RBAC role. Any Service in the `app` namespace with the expected `prometheus.io/*` annotations can be discovered without editing Prometheus configuration. Grafana's datasource, dashboard provider, and dashboard are provisioned as code, so the UI is ready immediately after deployment.

## Repository layout

```text
.
├── .github/
│   ├── dependabot.yml
│   └── workflows/ci.yaml
├── app/
│   ├── Dockerfile
│   └── src/
├── helm/
│   └── devops-assignment/
│       ├── files/
│       ├── templates/
│       ├── Chart.yaml
│       └── values.yaml
├── scripts/setup.sh
├── Makefile
└── README.md
```

## Application and container design

The application exposes:

- `GET /health`: process liveness and uptime; used by the Kubernetes liveness/startup probes.
- `GET /ready`: returns `503` during the configurable startup delay, then `200`; used by the readiness probe.
- `GET /metrics`: Prometheus text-format metrics, including Node.js process metrics, request count/latency, and the supplied synthetic application metrics.
- `GET /`: a simple user-facing response.

The Dockerfile uses separate dependency, build, production-dependency, and runtime stages. The final image contains no compiler or development dependencies and runs as the unprivileged `node` user. Kubernetes additionally drops Linux capabilities, blocks privilege escalation, uses the runtime-default seccomp profile, and mounts the container root filesystem read-only.

The application deployment uses two replicas, rolling updates with zero planned unavailability, resource requests/limits, and distinct startup, readiness, and liveness probes. Setup pulls `ghcr.io/kiroalbatrosa/task:latest`, resolves its registry digest, and passes `ghcr.io/kiroalbatrosa/task@sha256:...` to Helm. Every release therefore records the exact deployed image while `IMAGE_REPOSITORY` and `IMAGE_TAG` can still select another published image.

## Automation commands

| Command | Purpose |
| --- | --- |
| `sudo ./scripts/setup.sh` | Install missing prerequisites, drop to the invoking user, create or reuse the cluster, and deploy the complete stack |
| `make setup` | Convenience wrapper for `sudo ./scripts/setup.sh` |
| `make test` | Install locked dependencies, test, and compile the application |
| `make build` | Optional developer-only local image build; deployment does not use it |
| `make manifests` | Render the Helm chart without installing it |
| `make status` | Show assignment pods and Services |
| `make destroy` | Delete the Minikube profile |

Optional environment variables for setup are `MINIKUBE_VERSION`, `MINIKUBE_PROFILE`, `KUBERNETES_VERSION`, `HELM_VERSION`, `HELM_RELEASE`, `MINIKUBE_CPUS`, `MINIKUBE_MEMORY`, `IMAGE_REPOSITORY`, `IMAGE_TAG`, `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`, and `SETUP_DEPLOY_USER`.

The Kubernetes and Helm versions are pinned for reproducibility. Helm adopts resources from an older manifest-based installation on the first upgrade. An atomic upgrade waits for readiness and automatically rolls back if the new release cannot become healthy.

## CI pipeline

`.github/workflows/ci.yaml` contains exactly two jobs:

1. **Test application** installs dependencies using the committed lockfile, runs Jest, compiles TypeScript, and lints and renders the Helm chart.
2. **Build and push image** waits for tests, creates a multi-architecture image with BuildKit, generates an SBOM and provenance attestation, and publishes to GitHub Container Registry (GHCR) on pushes to `main` and version tags. Pull requests build the same image but do not push it.

The destination is:

```text
ghcr.io/kiroalbatrosa/task
```

No registry password is required: the workflow uses the short-lived `GITHUB_TOKEN` with only `contents:read` and `packages:write`. The resulting package must remain public so the local cluster can pull it without an image-pull secret. Dependabot is configured to keep npm, Docker, and GitHub Actions dependencies current.

## Observability

Prometheus discovers both application pod endpoints from the annotated Service and scrapes `/metrics` every 15 seconds. Data is intentionally stored in an `emptyDir` with 24-hour retention because this is a disposable local environment.

The provisioned Grafana dashboard shows:

- target health;
- request rate grouped by route;
- p95 HTTP latency;
- responses grouped by status code;
- synthetic queue depth;
- application process CPU usage.

To inspect the raw target status, open <http://localhost:9090/targets>. To inspect the raw application metrics, use:

```bash
curl http://localhost:3000/metrics
```

## Verification and troubleshooting

Run application checks independently of Kubernetes:

```bash
make test
```

Render and inspect Kubernetes resources without a cluster:

```bash
make manifests
```

Useful diagnostics after setup:

```bash
kubectl get pods --all-namespaces -l app.kubernetes.io/part-of=devops-home-assignment
kubectl describe deployment devops-assignment --namespace app
kubectl logs --namespace app deployment/devops-assignment
kubectl logs --namespace observability deployment/prometheus
kubectl logs --namespace observability deployment/grafana
```

Ports `3000`, `3001`, and `9090` must be free when the Minikube profile is first created. Docker port mappings are fixed at profile creation time; if this profile was created with different options, run `make destroy` and then `make setup`.

Automatic prerequisite installation intentionally targets Debian and Ubuntu. On another operating system, install Docker, Minikube, Helm, and a version-compatible `kubectl` manually before running the script.

## Production considerations

This setup is intentionally local. A production deployment should replace NodePorts with an Ingress or managed load balancer, use a managed secret provider instead of a locally generated Kubernetes Secret, use persistent or remote storage for metrics, add TLS and network policies, and deploy highly available monitoring components. The local workflow already resolves tags to immutable digests; production should additionally promote those digests through separate environments.
