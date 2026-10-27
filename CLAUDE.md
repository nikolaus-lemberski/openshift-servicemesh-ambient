# Service Mesh 3 Ambient - Workshop Project

## Mission

Workshop demonstrating Istio Service Mesh on OpenShift in ambient mode (ztunnel L4 + waypoint proxy L7) for Security (mTLS), Observability (metrics, tracing, access logging) and Resiliency (circuit breaker, retries, canary releases).

## Architecture

Three microservices in a call chain: A -> B -> C. Deployed in namespace `servicemesh-apps`.

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
- `assets/img/` - images used in the instructions
- `scripts/` — `install.sh` and `cleanup.sh` helper scripts
- `k8s/istio/` — Istio, IstioCNI, ztunnel CRs (kustomize)
- `k8s/apps/` — app deployments, service accounts, pod monitors, namespace, route (kustomize)
- `k8s/apps_gateway_waypoint/` — Gateway, HTTPRoute, waypoint proxy
- `k8s/observability/` — Kiali, OSSM console plugin, Perses dashboards/datasource, monitors, access logging (kustomize)
- `k8s/tracing/` — TempoStack, OTel collector, telemetry, network policies, tracing UI plugin
- `k8s/operators/` — operator subscriptions
- `k8s/istiofeatures/` — canary, circuit-breaker, l4-authz, mirroring, mTLS demos

## Key Files

- `apps/podman-compose.yml` — local dev compose (all three services)
- `apps/tag-and-push.sh` — container image build and push helper
- `INSTALLATION.md` — full installation guide (operators, Istio, observability, tracing)
- `USING_THE_MESH.md` — workshop walkthrough (onboarding, L4 security, waypoint, canary, circuit breaker, mirroring)

## Conventions

- K8s manifests use `.yml` extension
- Apply kustomize dirs with `oc apply -k`, individual files with `oc apply -f`
- Apps namespace: `servicemesh-apps`, mesh control plane: `istio-system`
- Label `istio-discovery: enabled` on namespaces for mesh discovery
- Label `istio.io/dataplane-mode=ambient` to onboard namespaces
- Label `istio.io/use-waypoint=waypoint` for waypoint enrollment
- Container images built with `podman build` using Containerfiles
- Local dev via `podman-compose up --build` (from `apps/` directory)
