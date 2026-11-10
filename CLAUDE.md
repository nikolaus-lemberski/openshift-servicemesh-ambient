# Service Mesh 3 Ambient - Workshop Project

## Mission

Workshop demonstrating Istio Service Mesh on OpenShift in ambient mode (ztunnel L4 + waypoint proxy L7) for Security (mTLS), Observability (metrics, tracing, access logging) and Resiliency (circuit breaker, retries, canary releases).

## Architecture

Three microservices in a call chain: A -> B -> C. Multi-user workshop: every user deploys them in their own namespace `<user>-apps`.

| Service | Language / Runtime | Framework |
|---------|-------------------|-----------|
| service-a | Python 3 | ASGI + uvicorn |
| service-b | TypeScript | Node.js + Express |
| service-c | Java 25 | Quarkus |

service-c has two versions (v1, v2) and crash/repair endpoints for resilience demos.

## Platform & Mesh

- OpenShift (oc CLI) with Red Hat OpenShift Service Mesh 3 (Istio Sail Operator)
- Istio ambient mode: ztunnel (L4/HBONE/mTLS) + waypoint proxy (L7 HTTP routing, AuthZ, tracing)
- Kubernetes Gateway API (`gateway.networking.k8s.io/v1`) — not legacy Istio Gateway API
- OVN-Kubernetes CNI with `routingViaHost: true`

## Observability Stack

- Prometheus (OpenShift user workload monitoring) with ServiceMonitor/PodMonitor
- Perses dashboards (via Cluster Observability Operator UIPlugin)
- Kiali + OpenShift Service Mesh (OSSM) console plugin
- Tempo (TempoStack with ODF or SeaweedFS S3) + OpenTelemetry Collector for distributed tracing

## Key Directories

- `apps/` — microservice source code (service-a, service-b, service-c) with Containerfiles
- `admin-chapters/` — instructions for the workshop admin (installation, user setup, teardown), one numbered Markdown file per chapter
- `user-chapters/` — instructions for the workshop users (getting started, chapters 2–10)
- `assets/img/` - images used in the instructions
- `admin-scripts/` — `install.sh`/`cleanup.sh` (platform), `setup-users.sh`/`cleanup-users.sh` (workshop users), run by the admin
- `user-scripts/` — `workshop-env.sh` (sourced by users in the Web Terminal)
- `k8s/istio/` — Istio, IstioCNI, ztunnel CRs (kustomize)
- `k8s/apps/` — app deployments, service accounts, pod monitors, route (kustomize, no namespace)
- `k8s/apps_gateway_waypoint/` — Gateway, HTTPRoute, waypoint proxy
- `k8s/observability/` — Kiali, OSSM console plugin, Perses dashboards/datasource, monitors, access logging (kustomize)
- `k8s/tracing/` — TempoStack, OTel collector, telemetry, network policies, tracing UI plugin
- `k8s/operators/` — operator subscriptions
- `k8s/keycloak/` — Red Hat build of Keycloak (operator, PostgreSQL, realm) as OIDC provider for Gateway auth
- `k8s/sidecar/` — second copy of the apps with sidecars (namespace `<user>-sidecar`, reuses `k8s/apps`), cross-namespace HTTPRoute, mTLS/AuthZ demo
- `k8s/workshop-tools/` — in-cluster download server for `istioctl` and `envsubst` (Web Terminal)
- `k8s/istiofeatures/` — canary, circuit-breaker, gateway-auth (JWT AuthN/AuthZ), l4-authz, mirroring, mTLS demos

## Key Files

- `apps/podman-compose.yml` — local dev compose (all three services)
- `apps/tag-and-push.sh` — container image build and push helper
- `admin-chapters/01-installation.md` — full installation guide (operators, Istio, observability, tracing, Keycloak, Web Terminal)
- `admin-chapters/02-user-setup.md`, `03-teardown.md` — workshop users and cleanup
- `user-chapters/01-getting-started.md` — Web Terminal, clone, `workshop-env.sh`
- `user-chapters/02-*.md` to `user-chapters/10-*.md` — workshop walkthrough, one numbered file per chapter (onboarding, L4 security, gateway/waypoint, tracing, gateway auth, canary, circuit breaker, mirroring, ambient/sidecar interop)

## Conventions

- K8s manifests use `.yml` extension
- Apply kustomize dirs with `oc apply -k`, individual files with `oc apply -f`
- Per-user namespaces: `<user>-apps` (ambient), `<user>-sidecar` (sidecars), `<user>-terminal` (Web Terminal, never in the mesh), mesh control plane: `istio-system`
- User-facing manifests have no `metadata.namespace` (applied to the current project). Cross-namespace references use `${APPS_NS}`/`${SIDECAR_NS}` and are applied with `envsubst`
- Objects created by `setup-users.sh` carry the label `servicemesh-workshop/user=<user>` or `servicemesh-workshop/shared=true`
- Label `istio-discovery: enabled` on namespaces for mesh discovery
- Label `istio.io/dataplane-mode=ambient` to onboard namespaces
- Label `istio.io/use-waypoint=waypoint` for waypoint enrollment
- Container images built with `podman build` using Containerfiles
- Local dev via `podman-compose up --build` (from `apps/` directory)
- Chapters: show the relevant part of each manifest as YAML snippet before applying it, explain the fields, state the expected result, end with cleanup and a previous/next navigation line; images are linked relative (`../assets/img/...`)
