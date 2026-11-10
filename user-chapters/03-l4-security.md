# 3. L4 Security (Ztunnel)

Before we move to L7 with waypoint proxies, let's demonstrate what the ztunnel can already do at L4: enforce strict mTLS and identity-based authorization. Both work without any change to the apps and without a waypoint proxy.

| Feature        | Istio resource        | Enforced by | Based on                              |
| -------------- | --------------------- | ----------- | ------------------------------------- |
| Strict mTLS    | `PeerAuthentication`  | ztunnel     | Is the connection mTLS (HBONE)?       |
| Authorization  | `AuthorizationPolicy` | ztunnel     | SPIFFE identity of the caller         |

## Preparation — two clients

If you're in a new terminal tab, load the environment ([Getting Started](01-getting-started.md#a-second-terminal-tab)) and set the `ROUTE` variable again:

```bash
export ROUTE="https://$(oc get route -n $APPS_NS service-a -o jsonpath='{.spec.host}')"
```

We call service-c from two clients:

- **Outside the mesh:** your Web Terminal. It runs in `<user>-terminal`, which is not enrolled in the mesh.
- **Inside the mesh:** a temporary curl pod in `<user>-apps`.

Start the curl pod and wait until it's running:

```bash
oc run curl-test -n $APPS_NS --image=curlimages/curl --restart=Never -- sleep 3600
oc wait pod/curl-test -n $APPS_NS --for=condition=Ready --timeout=60s
```

> [!NOTE]
> You may see a PodSecurity warning for the pod. The pod is created anyway.

## Strict mTLS

![Strict mTLS](../assets/img/strict_mtls.png)

By default, Istio ambient mode uses *permissive* mTLS: mesh workloads accept both plain-text and mTLS traffic. This makes onboarding easy, as clients outside the mesh keep working. We can enforce that **only** mTLS traffic is allowed.

### Step 1 — Permissive mode (default)

Your Web Terminal is not in the mesh and sends plain-text HTTP. In permissive mode this is **accepted**:

```bash
curl -s -m 5 -w "\n" http://service-c.$APPS_NS:8080/health
```

### Step 2 — Enforce strict mTLS

A `PeerAuthentication` with mode `STRICT` in your namespace tells the ztunnel to accept only mTLS connections for all workloads in this namespace:

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict-mtls
spec:
  mtls:
    mode: STRICT
```

```bash
oc apply -f k8s/istiofeatures/mtls/peer-authentication.yml -n $APPS_NS
```

**Test from outside the mesh:** The Web Terminal still sends plain-text HTTP, so it is now **rejected**:

```bash
curl -s -m 5 -w "\n" http://service-c.$APPS_NS:8080/health
```

The connection is reset because the ztunnel enforces mTLS and rejects plain-text traffic (curl exits with an error).

**Test from inside the mesh:** Now run the same curl from the curl pod in your namespace. The ztunnel transparently adds mTLS, so the request **succeeds**:

```bash
oc exec curl-test -n $APPS_NS -- curl -s -m 5 -w "\n" http://service-c.$APPS_NS:8080/health
```

You should get a healthy response. Neither the curl pod nor service-c knows anything about certificates: the ztunnel provides zero-config mTLS for all enrolled workloads.

| Caller                          | Permissive (default) | STRICT   |
| ------------------------------- | -------------------- | -------- |
| Web Terminal (no mesh)          | allowed              | rejected |
| curl pod in `<user>-apps`       | allowed              | allowed  |

### Cleanup

Remove the strict mTLS policy. We keep the curl pod for the next demo:

```bash
oc delete -f k8s/istiofeatures/mtls/peer-authentication.yml -n $APPS_NS
```

## L4 Authorization Policy

![L4 Authorization Policy](../assets/img/l4_authorization_policy.png)

The ztunnel can also enforce authorization at L4 based on the **SPIFFE identity** of the caller. Every workload in the mesh gets a certificate with an identity derived from its namespace and service account:

```text
spiffe://cluster.local/ns/<namespace>/sa/<service-account>
```

Our deployments use dedicated service accounts (`service-a`, `service-b`, `service-c`), so the ztunnel can distinguish between callers. The curl pod uses the `default` service account.

### Step 1 — Allow only service-b to call service-c

This `AuthorizationPolicy` selects the service-c pods and allows only connections with the identity of service-b. As soon as an `ALLOW` policy selects a workload, everything that doesn't match is denied:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: service-c-allow-service-b
spec:
  selector:
    matchLabels:
      app: service-c
  action: ALLOW
  rules:
  - from:
    - source:
        principals:
        - cluster.local/ns/${APPS_NS}/sa/service-b
```

The policy only uses L4 attributes (the identity of the caller), so the ztunnel can enforce it. Rules with L7 attributes like HTTP paths or headers would need a waypoint proxy.

The principal contains your namespace, so the file has the variable `${APPS_NS}`. `envsubst` replaces it before the policy is applied:

```bash
envsubst < k8s/istiofeatures/l4-authz/authorization-policy.yml | oc apply -n $APPS_NS -f -
```

### Step 2 — Test

**The call chain:** The normal A -> B -> C call still works because service-b is the one calling service-c:

```bash
curl $ROUTE
```

**From the curl pod:** The curl pod uses the `default` service account, not `service-b`. The ztunnel **denies** the request:

```bash
oc exec curl-test -n $APPS_NS -- curl -s -m 5 -w "\n" http://service-c.$APPS_NS:8080/health
```

The connection is closed by the ztunnel. Only the identity of service-b is allowed to reach service-c.

| Caller                              | Identity                  | Result  |
| ----------------------------------- | ------------------------- | ------- |
| service-b (call chain via `$ROUTE`) | `.../sa/service-b`        | allowed |
| curl pod in `<user>-apps`           | `.../sa/default`          | denied  |

You can also verify in the ztunnel logs that the connection was denied. The ztunnel handles the traffic of all users, so filter for your namespace:

```bash
oc logs -n ztunnel -l app=ztunnel --tail=200 | grep "policy rejection" | grep $APPS_NS
```

### Cleanup

Remove the authorization policy and the curl pod:

```bash
oc delete authorizationpolicy service-c-allow-service-b -n $APPS_NS
oc delete pod curl-test -n $APPS_NS
```

---

[← 2. Deploy and Onboard the Apps](02-deploy-and-onboard.md) | [Overview](../README.md) | [4. Gateway and Waypoint Proxy →](04-gateway-and-waypoint.md)
