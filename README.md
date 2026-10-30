# Service Mesh 3 Ambient Workshop

Workshop demonstrating **Red Hat OpenShift Service Mesh 3** in ambient mode on OpenShift.

Three microservices form a call chain (A → B → C) to showcase Istio ambient mesh capabilities: **ztunnel** for L4 mTLS and **waypoint proxies** for L7 HTTP routing, authorization, observability, and resilience.

| Service | Runtime | Framework |
|---------|---------|-----------|
| service-a | Python 3 | ASGI + uvicorn |
| service-b | TypeScript | Node.js + Express |
| service-c | Java 25 | Quarkus |

## Topics Covered

- **Security** — automatic mTLS, authorization policies, JWT authentication and authorization on the Gateway (Keycloak)
- **Observability** — Prometheus metrics, Perses dashboards, Kiali, distributed tracing (Tempo + OpenTelemetry)
- **Resilience** — circuit breakers, retries, canary releases, traffic mirroring

## Chapters

1. [Installation](chapters/01-installation.md) — install operators, Istio ambient mesh, the observability/tracing stack and Keycloak
2. [Deploy and Onboard the Apps](chapters/02-deploy-and-onboard.md) — deploy the demo apps, add them to the ambient mesh and explore Kiali, metrics and dashboards
3. [L4 Security](chapters/03-l4-security.md) — strict mTLS and identity-based authorization with the ztunnel
4. [Gateway and Waypoint Proxy](chapters/04-gateway-and-waypoint.md) — ingress with the Gateway API and L7 features with a waypoint proxy
5. [Distributed Tracing](chapters/05-distributed-tracing.md) — traces with Tempo and OpenTelemetry
6. [Authentication and Authorization on the Gateway](chapters/06-gateway-auth.md) — JWT validation and role-based access with Keycloak
7. [Canary Release](chapters/07-canary-release.md) — shift traffic gradually from v1 to v2
8. [Circuit Breaker](chapters/08-circuit-breaker.md) — outlier detection and retries
9. [Traffic Mirroring](chapters/09-traffic-mirroring.md) — send a copy of live traffic to a new version
10. [Ambient and Sidecar Side by Side](chapters/10-sidecar-interop.md) — run the apps with sidecars and route from ambient to sidecar workloads
