# 7. Canary Release

A canary release lets you roll out a new version of a service gradually, shifting traffic in controlled increments so you can observe behaviour before committing fully. We'll use the waypoint proxy and a Gateway API `HTTPRoute` to steer traffic between service-c v1 and v2.

![Canary release](../assets/img/canary_release.png)

| Step | HTTPRoute file              | service-c-v1 | service-c-v2 |
| ---- | --------------------------- | ------------ | ------------ |
| 1    | `1-httproute-v1.yml`        | 100 %        | 0 %          |
| 3    | `2-httproute-90-10.yml`     | 90 %         | 10 %         |
| 4    | `3-httproute-50-50.yml`     | 50 %         | 50 %         |
| 5    | `4-httproute-v2.yml`        | 0 %          | 100 %        |

## Preparation — version-specific Services

If you're in a new terminal, set the `ROUTE` variable again:

```bash
export ROUTE="https://$(oc get route -n servicemesh-apps apps-gateway -o jsonpath='{.spec.host}')"
```

The existing `service-c` Service selects **all** pods with `app: service-c` regardless of version. To split traffic we need two additional Services that each select a single version:

```yaml
kind: Service
metadata:
  name: service-c-v1
spec:
  selector:
    app: service-c
    version: v1
---
kind: Service
metadata:
  name: service-c-v2
spec:
  selector:
    app: service-c
    version: v2
```

```bash
oc apply -f k8s/istiofeatures/canary/0-service-c-versions.yml
```

## Step 1 — Pin all traffic to v1

Before deploying the new version, pin traffic explicitly to v1. In chapter 4, our `HTTPRoute` had the Gateway as parent. This `HTTPRoute` has the **`service-c` Service** as parent: it applies to all requests sent to `service-c` inside the mesh and is processed by the waypoint proxy. It sends 100 % of the requests to `service-c-v1`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: service-c-canary
  namespace: servicemesh-apps
spec:
  parentRefs:
  - group: ""
    kind: Service
    name: service-c
    port: 8080
  rules:
  - backendRefs:
    - name: service-c-v1
      port: 8080
      weight: 100
```

```bash
oc apply -f k8s/istiofeatures/canary/1-httproute-v1.yml
```

Verify that everything still works:

```bash
curl $ROUTE
```

You should see `v1` in the response:

```text
Service A <- Service B <- Service C | v1 | 5vnhc | 42
```

## Step 2 — Deploy service-c v2

Now deploy the v2 version alongside v1. It is the same image, only the labels and the environment variable `VERSION` are different:

```yaml
kind: Deployment
metadata:
  name: service-c-v2
spec:
  template:
    metadata:
      labels:
        app: service-c
        version: v2
    spec:
      containers:
      - name: service-c
        env:
        - name: VERSION
          value: "v2"
```

```bash
oc apply -f k8s/istiofeatures/canary/c-v2-deploy.yml
```

Wait for the pod to be ready:

```bash
oc rollout status deployment/service-c-v2 -n servicemesh-apps
```

The v2 pod also matches the selector of `service-c` (`app: service-c`). Without our `HTTPRoute`, it would get traffic right away. But the HTTPRoute still sends 100 % of traffic to v1. Confirm by generating some requests:

```bash
for i in $(seq 1 10); do curl $ROUTE; done
```

Every response should show `v1`.

## Step 3 — Shift 10 % of traffic to v2

Start small — send 10 % of requests to v2 while keeping 90 % on v1. Only the `backendRefs` change:

```yaml
  rules:
  - backendRefs:
    - name: service-c-v1
      port: 8080
      weight: 90
    - name: service-c-v2
      port: 8080
      weight: 10
```

```bash
oc apply -f k8s/istiofeatures/canary/2-httproute-90-10.yml
```

Generate traffic and observe the version in the responses:

```bash
while true; do curl $ROUTE; sleep 2; done
```

Roughly 1 in 10 requests should now show `v2`. Check Kiali for a visual split:

```text
Service Mesh -> Traffic Graph -> Display -> Check "Traffic Distribution"
```

![Kiali traffic distribution](../assets/img/10-canary-release.png)

## Step 4 — Shift 50 % of traffic to v2

If v2 looks healthy, increase the canary to 50/50:

```yaml
    - name: service-c-v1
      port: 8080
      weight: 50
    - name: service-c-v2
      port: 8080
      weight: 50
```

```bash
oc apply -f k8s/istiofeatures/canary/3-httproute-50-50.yml
```

You should see an even mix of `v1` and `v2` responses.

## Step 5 — Complete the rollout to v2

Once you're confident, send 100 % of traffic to v2:

```yaml
  rules:
  - backendRefs:
    - name: service-c-v2
      port: 8080
      weight: 100
```

```bash
oc apply -f k8s/istiofeatures/canary/4-httproute-v2.yml
```

All responses should now show `v2`.

## Cleanup

Remove the canary HTTPRoute, the version-specific Services and the v2 Deployment:

```bash
oc delete -f k8s/istiofeatures/canary/4-httproute-v2.yml
oc delete -f k8s/istiofeatures/canary/0-service-c-versions.yml
oc delete -f k8s/istiofeatures/canary/c-v2-deploy.yml
```

Traffic returns to the original `service-c` Service, which now only has the v1 pod behind it.

---

[← 6. Authentication and Authorization on the Gateway](06-gateway-auth.md) | [Overview](../README.md) | [8. Circuit Breaker →](08-circuit-breaker.md)
