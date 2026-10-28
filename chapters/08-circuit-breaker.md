# 8. Circuit Breaker

A circuit breaker protects your system by detecting unhealthy endpoints and temporarily removing them from the load-balancing pool (outlier detection). Combined with retries, it ensures users never see errors from a single crashed instance.

![Circuit breaker](../assets/img/circuit_breaker.png)

We'll demonstrate this on service-c-v1 with 2 replicas. One pod will be "crashed" via its `/crash` endpoint while `/health` keeps returning UP — so Kubernetes still considers the pod ready, but the business endpoint returns 500. This is a typical failure that Kubernetes probes don't catch.

| Step | Resource                              | What the user sees                       |
| ---- | ------------------------------------- | ---------------------------------------- |
| 1    | none                                  | about every second request fails         |
| 2    | `DestinationRule` (outlier detection) | one error, then only successful requests |
| 3    | + `VirtualService` (retries)          | no errors at all                         |

## Preparation — Scale service-c-v1

If you're in a new terminal, set the `ROUTE` variable again:

```bash
export ROUTE="https://$(oc get route -n servicemesh-apps apps-gateway -o jsonpath='{.spec.host}')"
```

Scale service-c-v1 to 2 replicas so the waypoint proxy round-robins between them:

```bash
oc scale deployment/service-c-v1 -n servicemesh-apps --replicas=2
```

Verify both pods are running:

```bash
oc get pods -n servicemesh-apps -l app=service-c,version=v1
```

Generate some traffic and confirm both pods handle requests — the abbreviated host ID in the response alternates:

```bash
for i in $(seq 1 10); do curl $ROUTE; done
```

## Step 1 — Crash one pod (no circuit breaker)

Pick one of the service-c pods and crash it via port-forwarding:

```bash
export CRASH_POD=$(oc get pods -n servicemesh-apps -l app=service-c,version=v1 -o jsonpath='{.items[0].metadata.name}')
oc port-forward -n servicemesh-apps $CRASH_POD 8080:8080 &
```

```bash
curl http://localhost:8080/crash
kill %1
```

Now generate traffic. Roughly half the requests fail because the waypoint proxy round-robins between the healthy and crashed pods:

```bash
for i in $(seq 1 20); do curl $ROUTE; sleep 1; done
```

You should see a mix of successful responses and `INTERNAL_SERVER_ERROR`. This is the problem we want to solve.

## Step 2 — Apply the Circuit Breaker

Outlier detection is configured with an Istio `DestinationRule` for the host `service-c`. The waypoint proxy tracks the responses of every endpoint (pod):

```yaml
apiVersion: networking.istio.io/v1
kind: DestinationRule
metadata:
  name: service-c-circuit-breaker
  namespace: servicemesh-apps
spec:
  host: service-c
  trafficPolicy:
    outlierDetection:
      consecutive5xxErrors: 1
      interval: 5s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
```

| Field                    | Value | Meaning                                                                      |
| ------------------------ | ----- | ---------------------------------------------------------------------------- |
| `consecutive5xxErrors`   | 1     | Eject an endpoint after a single 5xx response (strict, good for the demo)    |
| `interval`               | 5s    | How often the endpoints are analyzed                                         |
| `baseEjectionTime`       | 30s   | How long an endpoint stays ejected. Grows with every repeated ejection      |
| `maxEjectionPercent`     | 100   | Up to 100 % of the endpoints may be ejected                                  |

```bash
oc apply -f k8s/istiofeatures/circuit-breaker/1-destination-rule.yml
```

Generate traffic again:

```bash
for i in $(seq 1 20); do curl $ROUTE; sleep 1; done
```

You may still see **one** error (the first 5xx triggers the ejection), but all subsequent requests go only to the healthy pod. The circuit breaker has opened for the crashed endpoint.

## Step 3 — Add Retries (zero errors for the user)

To eliminate even that initial error, add a retry policy. The waypoint retries failed requests up to 3 times on 5xx responses, and each try has a timeout of 2 seconds:

```yaml
apiVersion: networking.istio.io/v1
kind: VirtualService
metadata:
  name: service-c-retry
  namespace: servicemesh-apps
spec:
  hosts:
  - service-c
  http:
  - route:
    - destination:
        host: service-c
        port:
          number: 8080
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: 5xx
```

```bash
oc apply -f k8s/istiofeatures/circuit-breaker/2-retry-virtualservice.yml
```

Generate traffic:

```bash
for i in $(seq 1 20); do curl $ROUTE; sleep 1; done
```

No errors at all. If a request hits the crashed pod it is retried transparently on the healthy one.

Explore the Kiali Traffic Graph to see the Circuit Breaker and Retry applied and the information reported about the HTTP responses.

## Step 4 — Repair and observe recovery

Repair the crashed pod:

```bash
oc port-forward -n servicemesh-apps $CRASH_POD 8080:8080 &
```

```bash
curl http://localhost:8080/repair
kill %1
```

The circuit breaker ejects endpoints for a base period of 30 seconds (increasing with repeated ejections). Wait about a minute for the ejection to expire, then generate traffic:

```bash
for i in $(seq 1 20); do curl $ROUTE; sleep 1; done
```

The host ID alternates again — both pods are back in rotation. The circuit has closed and traffic flows to all healthy endpoints.

## Cleanup

```bash
oc delete -f k8s/istiofeatures/circuit-breaker/2-retry-virtualservice.yml
oc delete -f k8s/istiofeatures/circuit-breaker/1-destination-rule.yml
oc scale deployment/service-c-v1 -n servicemesh-apps --replicas=1
```

---

[← 7. Canary Release](07-canary-release.md) | [Overview](../README.md) | [9. Traffic Mirroring →](09-traffic-mirroring.md)
