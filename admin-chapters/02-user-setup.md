# 2. Workshop Users

Every workshop user gets their own namespaces and works in the Web Terminal of the OpenShift console. Users don't need any rights beyond their namespaces. The mesh, the observability stack and Keycloak are shared and stay with the admin.

## What the users get

Each user `<user>` gets three namespaces:

| Namespace        | Purpose                                                                                         |
| ---------------- | ----------------------------------------------------------------------------------------------- |
| `<user>-apps`     | The demo apps in ambient mode (chapters 2–9)                                                   |
| `<user>-sidecar`  | A second copy of the apps with sidecars (chapter 10)                                           |
| `<user>-terminal` | The user's Web Terminal. It's never in the mesh, so chapter 3 can call the apps from outside the mesh |

The users onboard their namespaces to the mesh themselves, by labeling them. That's part of what the workshop teaches. The two app namespaces only carry the discovery label `istio-discovery: enabled` at the start.

The script creates this RBAC:

| Object                                                       | Scope                       | Why                                                                                         |
| ------------------------------------------------------------ | --------------------------- | ------------------------------------------------------------------------------------------- |
| RoleBinding to `admin`                                       | the user's three namespaces | Deploy the apps, Routes, Web Terminal                                                       |
| ClusterRole `servicemesh-workshop-mesh-resources` + RoleBindings | `<user>-apps`, `<user>-sidecar` | Istio resources (policies, VirtualServices, Telemetry), Gateway API routes and gateways, PodMonitors. The `admin` role doesn't include them |
| ClusterRole + ClusterRoleBinding `servicemesh-workshop-<user>-namespaces` | the two app namespaces only (`resourceNames`) | Label the own namespaces: ambient onboarding, waypoint, sidecar injection |
| Group `servicemesh-workshop-users`                           | all users                   | Subject of the shared bindings below                                                        |
| Role/RoleBinding `servicemesh-workshop-ztunnel`              | namespace `ztunnel`         | ztunnel logs (chapter 3) and `istioctl ztunnel-config` (chapter 4)                          |
| ClusterRole + ClusterRoleBinding `servicemesh-workshop-monitoring-view` | cluster          | Metrics and Perses dashboards, the L4 metrics come from the `ztunnel` namespace. Like `cluster-monitoring-view`, but without `get namespaces`, so users only see their own projects |
| RoleBindings to the Perses viewer roles                      | namespace `perses-dev`      | Read the Perses dashboards and datasources                                                  |

> [!NOTE]
> With the namespace permission, users could change other labels of their two app namespaces as well, e.g. the Pod Security labels. For a workshop that's acceptable.

All objects carry the label `servicemesh-workshop/user=<user>` or `servicemesh-workshop/shared=true`. The teardown in [chapter 3](03-teardown.md) finds them by these labels.

The users also need `istioctl` and `envsubst` in their Web Terminal. Downloading `istioctl` from GitHub in every terminal would run into the GitHub download limits, because all users of a workshop usually share one outbound IP. The script deploys a small download server in the namespace `workshop-tools` instead, which downloads `istioctl` once, in the version of the control plane. The users' `scripts/workshop-env.sh` installs the tools from there.

## Set up the users

Run the script as `cluster-admin` after the installation:

```bash
./scripts/setup-users.sh
```

Without arguments, the script detects the workshop users in this order and uses the first source that has users:

1. The environment variable `WORKSHOP_USERS` (e.g. `WORKSHOP_USERS="user1 user2"`)
2. The `KeycloakRealmImport` behind an OpenID identity provider of the cluster (RHDP clusters): the members of the group `/users`, or all users that aren't in `/admins`
3. The users of an htpasswd identity provider
4. The existing `User` objects (users that have logged in at least once)

Users with `cluster-admin` rights are skipped. The script shows the users it found and asks before it changes anything. To set up specific users, pass them as arguments:

```bash
./scripts/setup-users.sh user1 user2 user3
```

Expected result: the script ends with a table of the users and their namespaces, and the check of the first user's permissions reports `All permissions in place`.

```text
  USER                 NAMESPACES
  user1                user1-apps user1-sidecar user1-terminal
  user2                user2-apps user2-sidecar user2-terminal
```

> [!TIP]
> The script is idempotent. If a user joins late, run it again with the user name, e.g. `./scripts/setup-users.sh user6`. The other users keep their namespaces and their group membership.

## Verify

Check what a user is allowed to do with `oc auth can-i`:

```bash
oc auth can-i create authorizationpolicies.security.istio.io -n user1-apps --as=user1 --as-group=servicemesh-workshop-users
oc auth can-i patch namespace/user1-apps --as=user1
oc auth can-i patch namespace/user2-apps --as=user1
```

Expected result: `yes`, `yes` and `no`. A user can't touch the namespaces of other users.

The tools server should be running:

```bash
oc get pods -n workshop-tools
```

If the pod hangs in `Init`, the download of `istioctl` failed. Check it with `oc logs -n workshop-tools deploy/tools -c download`.

## Hand over to the users

The users log in to the OpenShift console, open the Web Terminal in their project `<user>-terminal` and continue with [user-chapters/01-getting-started.md](../user-chapters/01-getting-started.md).

Some things are shared by all users:

- **Traces:** all users see all traces in Tempo. The chapters tell them to filter by their own namespace.
- **Keycloak:** the realm `servicemesh` with `testuser` and `adminuser` (chapter 6) is shared. Users only read tokens from it.
- **Tracing configuration:** the `Telemetry` resource and the Istio tracing settings are mesh-wide. They're part of the installation.

---

[← 1. Installation](01-installation.md) | [Overview](../README.md) | [3. Teardown →](03-teardown.md)
