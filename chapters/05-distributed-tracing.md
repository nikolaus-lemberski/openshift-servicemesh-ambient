# 5. Distributed Tracing

Distributed tracing works by adding trace and span IDs to the HTTP headers. So with the L4 ambient mesh (ztunnel only) we do not get tracing data from the Service Mesh. Now that we have a waypoint proxy, the mesh can trace every HTTP request.

```mermaid
graph LR
    GW["Gateway"] -->|spans| OTel["OTel Collector<br/>tempostack"]
    WP["Waypoint proxy"] -->|spans| OTel
    OTel --> Tempo["TempoStack"]
    Tempo --> UI["OpenShift console<br/>Observe -> Traces"]
```

## How it is configured

We already configured tracing during the [installation](01-installation.md#distributed-tracing). Two resources are important.

The `Istio` resource registers the OpenTelemetry collector as tracing provider (`k8s/tracing/istio-update.yml`):

```yaml
spec:
  values:
    meshConfig:
      enableTracing: true
      extensionProviders:
      - name: otel
        opentelemetry:
          port: 4317
          service: otel-collector.tempostack.svc.cluster.local
```

A mesh-wide `Telemetry` resource in the root namespace `istio-system` enables tracing with this provider for all requests (`k8s/tracing/telemetry.yml`):

```yaml
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  accessLogging:
    - providers:
      - name: envoy
  tracing:
    - providers:
        - name: otel
      randomSamplingPercentage: 100
```

> [!NOTE]
> We sample 100 % of the requests, which is good for a workshop. In production you would use a much lower sampling rate.

## Trace context propagation

The Gateway and the waypoint add tracing headers to incoming requests if there aren't any. But the mesh can't know that the request service-a sends to service-b belongs to the request service-a received. To see the full path in one trace, the apps have to **forward the tracing headers** (e.g. `traceparent`, `x-request-id` and the `x-b3-*` headers) when doing downstream service calls, see the [Istio docs](https://istio.io/latest/docs/tasks/observability/distributed-tracing/overview/#building-applications-to-support-trace-context-propagation).

Our apps do that, so we get one trace across the Gateway, service-a, service-b and service-c.

## Explore the traces

Generate some traffic (if it's not running anymore):

```bash
export ROUTE="https://$(oc get route -n servicemesh-apps apps-gateway -o jsonpath='{.spec.host}')"
while true; do curl $ROUTE; sleep 3; done
```

Open the Distributed Tracing UI in the OpenShift console:

```text
Observe -> Traces -> Tempo instance "tempostack" -> Tenant "dev"
```

Click on a trace to see the spans of the Gateway and the waypoint for every hop and how long each service took.

![Distributed Tracing](../assets/img/9-distributed-tracing.png)

## Traces in Kiali

Kiali reads the traces from the same TempoStack and shows them next to the traffic graph and the metrics. It is configured in the `Kiali` resource (`k8s/observability/kiali.yml`):

```yaml
spec:
  external_services:
    tracing:
      enabled: true
      provider: tempo
      use_grpc: false
      use_waypoint_name: true
      internal_url: https://tempo-tempostack-gateway.tempostack.svc.cluster.local:8080/api/traces/v1/dev/tempo
      auth:
        type: bearer
        use_kiali_token: true
      tempo_config:
        url_format: openshift
        name: tempostack
        namespace: tempostack
        tenant: dev
```

| Field                | Meaning                                                                                                          |
| -------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `internal_url`       | Tempo API of the tenant `dev`, behind the TempoStack gateway                                                     |
| `auth`               | Kiali authenticates with its ServiceAccount token. All authenticated users may read the `dev` tenant (ClusterRole `tempostack-traces-reader`) |
| `use_waypoint_name`  | The waypoint reports its spans as `waypoint.servicemesh-apps`, so Kiali looks up the traces of a service via its waypoint |
| `tempo_config`       | *View in Tracing* links open the trace in **Observe -> Traces** of the OpenShift console (`external_url` is the console URL) |

With the traffic still running, open Kiali and go to

```text
Services -> service-c -> Traces
```

Every dot in the chart is a trace. Click one to see its spans and how long each hop took. *View in Tracing* opens the same trace in the Distributed Tracing UI of the OpenShift console. You also find the traces in the *Traffic Graph*: click on a service node and open the *Traces* tab in the side panel.

---

[← 4. Gateway and Waypoint Proxy](04-gateway-and-waypoint.md) | [Overview](../README.md) | [6. Authentication and Authorization on the Gateway →](06-gateway-auth.md)
