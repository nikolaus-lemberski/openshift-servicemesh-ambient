# Service Mesh 3 Ambient Workshop

Workshop demonstrating **Red Hat OpenShift Service Mesh 3** in ambient mode on OpenShift.

Three microservices form a call chain (A → B → C) to showcase Istio ambient mesh capabilities: **ztunnel** for L4 mTLS and **waypoint proxies** for L7 HTTP routing, authorization, observability, and resilience.

| Service | Runtime | Framework |
|---------|---------|-----------|
| service-a | Python 3 | ASGI + uvicorn |
| service-b | TypeScript | Node.js + Express |
| service-c | Java 25 | Quarkus |

## Topics Covered

- **Security** — automatic mTLS, authorization policies
- **Observability** — Prometheus metrics, Perses dashboards, Kiali, distributed tracing (Tempo + OpenTelemetry)
- **Resilience** — circuit breakers, retries, canary releases, traffic mirroring

## Getting Started

1. [Installation Guide](INSTALLATION.md) — install operators, Istio ambient mesh, and the observability/tracing stack
2. [Using the Mesh](USING_THE_MESH.md) — deploy the demo apps, configure routing, and explore mesh features
