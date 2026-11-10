# Plan: Multi-User Workshop

Goal: turn the single-user tutorial into a workshop. A cluster admin installs and configures the platform (operators, Istio, observability, tracing, Keycloak, Web Terminal) and sets up the workshop users. Each user works through the chapters in their own namespaces from the OpenShift Web Terminal, without needing `oc` or cluster-admin rights.

Branch: `workshop-multiuser`

## Findings on the current cluster (2026-11-10)

| Topic | Finding | Consequence |
|-------|---------|-------------|
| Identity provider | OpenID IdP `rhbk` → RHDP Keycloak, realm `sso`, namespace `keycloak` (`sso.apps.<domain>`) | Users are defined in Keycloak, not in htpasswd |
| Users | Realm import `keycloak/sso` defines `admin` (group `/admins`) and `user1`–`user5` (group `/users`) | User detection has to read the realm import (see 1.2) |
| `User` objects | Only `admin` exists. `user1`–`user5` don't have one until they first log in | `oc get users` **can't** be used for detection. RoleBindings by user name still work without a `User` object |
| cluster-admin | `admin` through ClusterRoleBinding `keycloak-sso-user:admin:cluster-admin` | Exclude cluster-admins from the workshop users |
| Cluster | OpenShift 4.22.22, **single node** (31.5 CPU / 122 GiB allocatable, ~12 % requested) | Plenty of room for 5 users. Check again for larger groups |
| Installed | cert-manager, RHBK operator (namespace `keycloak`), no mesh yet | Workshop Keycloak (`servicemesh-keycloak`) is a second RHBK operator installation, which `cleanup.sh` already handles |
| Gateway API RBAC | `system:openshift:gateway-api:aggregate-to-admin` exists | Namespace admins can probably manage Gateways/HTTPRoutes (still verify) |
| Web Terminal | Package `web-terminal` available, default channel `fast` | Install from `redhat-operators` |

## Design decisions (proposed)

### Namespaces per user

Each user `<u>` gets three namespaces, all created by the admin script (users can't create or label namespaces):

| Namespace | Purpose | Labels set by the script |
|-----------|---------|--------------------------|
| `<u>-apps` | ambient apps (replaces `servicemesh-apps`) | `istio-discovery=enabled` |
| `<u>-sidecar` | sidecar copy of the apps, chapter 10 (replaces `servicemesh-sidecar`) | `istio-discovery=enabled` |
| `<u>-terminal` | Web Terminal DevWorkspace + "outside the mesh" client (replaces `curl-test` in `default`) | none (never in the mesh) |

All namespaces and cluster-scoped objects created for users get the label `servicemesh-workshop/user=<u>`, which the cleanup uses (see 3.1).

Why a separate terminal namespace: if the Web Terminal pod ran in `<u>-apps`, it would join the mesh once the namespace is onboarded, show up in Kiali and be affected by STRICT mTLS/AuthZ policies. Because the terminal pod is outside the mesh, chapter 3's "outside the mesh" test can curl straight from the terminal, so we don't need the `curl-test` pod in `default` anymore.

### What users must be able to do

The chapters ask users to **label their own namespaces** (`istio.io/dataplane-mode=ambient` in ch. 2, `istio.io/use-waypoint=waypoint` in ch. 4, `istio-injection=enabled` in ch. 10). These steps are central to what the workshop teaches, so we keep them. Users can't patch Namespace objects with the project `admin` role. The script therefore creates a per-user ClusterRole with `get, patch, update` on `namespaces` and `resourceNames: [<u>-apps, <u>-sidecar]`. Trade-off: users could also change other labels on these two namespaces (e.g. Pod Security). That's acceptable for a workshop. A ValidatingAdmissionPolicy that only allows the `istio.io/*` and `istio-injection` labels is an optional hardening step.

### Manifests: no hard-coded namespaces

- Remove `metadata.namespace: servicemesh-apps` from all user-facing manifests (`k8s/apps`, `k8s/apps_gateway_waypoint`, `k8s/istiofeatures/*`, `k8s/sidecar`). They get applied to the current project (`oc project <u>-apps`).
- Remove `namespace:` and `ns.yml` from `k8s/apps/kustomization.yml` (the namespace already exists).
- Cross-namespace references become variables and are applied with `envsubst` (chapter 6 already does this for `${KEYCLOAK_HOST}`):
  - SPIFFE principals `cluster.local/ns/${APPS_NS}/sa/service-b|waypoint` (l4-authz, sidecar 4 + 5)
  - HTTPRoute backendRef `namespace: ${SIDECAR_NS}` (sidecar 2), ReferenceGrant `from.namespace: ${APPS_NS}` (sidecar 1)
- `k8s/sidecar/kustomization.yml` doesn't set a namespace anymore. It just reuses `../apps` and gets applied with `oc apply -k k8s/sidecar -n $SIDECAR_NS`. The `istio-injection` label moves from the Namespace patch to an `oc label` step in chapter 10.
- Gateway `allowedRoutes.namespaces.from: All` → `Same`, so that users can't attach routes to each other's gateways.

### User environment helper

Add a new file `scripts/workshop-env.sh`, which users `source` after cloning (and again after a terminal restart):

```bash
export WORKSHOP_USER=$(oc whoami)
export APPS_NS=${WORKSHOP_USER}-apps SIDECAR_NS=${WORKSHOP_USER}-sidecar TERMINAL_NS=${WORKSHOP_USER}-terminal
export KEYCLOAK_HOST=...   # from a ConfigMap the admin script creates, users can't read ingresses.config/cluster
oc project $APPS_NS
```

The admin script creates a ConfigMap `workshop-info` in every `<u>-terminal` namespace with `KEYCLOAK_HOST`, `ISTIO_VERSION`, `TOOLS_URL`, `KIALI_URL` and `CONSOLE_URL`. That way, users don't need cluster-scoped read access.

---

## 1. Install script / user setup

### 1.1 Web Terminal Operator (platform, admin)

- [x] Add a `web-terminal` Subscription (channel `fast`, namespace `openshift-operators`) to `k8s/operators/subscriptions.yml`. It pulls in the DevWorkspace Operator as a dependency (on this cluster: `web-terminal.v1.17.2`, `devworkspace-operator.v1.0.0`).
- [x] `install.sh`: run `wait_for_csv openshift-operators web-terminal` and `devworkspace-operator`. Also fixed `wait_for_csv`: its jsonpath filter `name >= prefix` was a string comparison and matched any CSV whose name sorts after the prefix (e.g. `servicemeshoperator3` satisfied the wait for `kiali-operator`). It now does a real prefix match.
- [x] `install.sh` annotates `openshift-operators` with `servicemesh-workshop/devworkspace-operator=installed` if no DevWorkspace CSV existed before.
- [x] Idle timeout (default 15 min) raised to 4h (`WEB_TERMINAL_IDLE_TIMEOUT`). There's no DevWorkspaceOperatorConfig setting for this: the timeout is the env var `WEB_TERMINAL_IDLE_TIMEOUT` in the DevWorkspaceTemplate `web-terminal-exec` (`openshift-operators`). `install.sh` patches it and sets the annotation `web-terminal.redhat.com/unmanaged-state=true`, which keeps the operator from reverting it (tested: the value survives a controller restart).
- [x] **Spike (2026-11-10)**, in a DevWorkspace started like the console does:
  - Tooling image has `git`, `curl`, `jq`, `oc`, `kubectl`, `tar`, `helm`, `perl`, `wtoctl`. **Missing: `envsubst`** (no gettext), `istioctl`, `python3`.
  - `/wto/bin/downloaded` is on the `PATH` and group-writable for the terminal user (gid 0) → put downloaded tools there, no `PATH` change needed. `$HOME` (`/home/user`) is writable too. Both are lost on a terminal restart.
  - Outbound internet works: `istioctl` 1.31.0 downloaded from GitHub releases and runs (`istioctl version --remote=false`).
  - `envsubst` replacement: a two-line `perl -p` script in `/wto/bin/downloaded/envsubst` (handles `${VAR}` and `$VAR`, unset → empty, like gettext). Tested.
  - A user with the `admin` RoleBinding in a namespace can create DevWorkspaces there and read the `web-terminal-*` templates (`oc auth can-i --as=user1`).
- **No per-user downloads from GitHub.** With up to 70 users, all terminal pods share the cluster's outbound IP. GitHub doesn't guarantee a download limit, and 70 near-identical downloads in a few minutes risk being throttled during the workshop. Tools are served from inside the cluster instead (decision 2026-11-10):
- [x] **In-cluster tools server (option 1):** `k8s/workshop-tools/tools-server.yml`, applied by `setup-users.sh` with `envsubst '${ISTIO_VERSION}'`. Tested on the cluster (2026-11-10): the init container (UBI `httpd-24`) downloads `istioctl-<version>-linux-<arch>.tar.gz` once, the httpd container serves `istioctl.tar.gz`, `envsubst` and `istio-version` at `http://tools.workshop-tools.svc:8080`. Reachable from other namespaces without a NetworkPolicy. A pod label with the Istio version restarts the server (new download) when the version changes. Original plan: `setup-users.sh` creates namespace `workshop-tools` (label `servicemesh-workshop/shared=true`) with a small web server Deployment + Service (e.g. `tools.workshop-tools.svc:8080`). An init container downloads `istioctl` (version from the installed `Istio` CR) **once** and writes the `envsubst` script. The web server (unprivileged, e.g. UBI httpd/nginx, restricted SCC) serves both files. NetworkPolicy/ingress: reachable from the `<u>-terminal` namespaces.
- [ ] **TODO – check option 3 during the full install:** does the OSSM 3 operator add `istioctl` to the console's Command Line Tools page (`oc get consoleclidownloads`)? If so, the tools server only serves the `envsubst` script (or `workshop-env.sh` writes it inline) and `istioctl` comes from the Red Hat download, which runs inside the cluster too. Check whether the download URL works from a terminal pod without logging in, and whether the version matches the control plane.
- [x] `workshop-env.sh` installs `istioctl` and `envsubst` from the in-cluster URL (in `workshop-info`, key `TOOLS_URL`) into `/wto/bin/downloaded` if they're missing, so re-sourcing after a terminal restart works too. `ISTIO_VERSION` stays in `workshop-info` for the version check (users can't read the cluster-scoped `Istio` CR). Tested end to end in a pod with the Web Terminal tooling image (temporary namespaces, `oc whoami` stubbed): tools land in `/wto/bin/downloaded`, `envsubst` works, re-sourcing skips the downloads.
- Fixed during the test: the spike's `envsubst` one-liner used `s/…/…/`, and the `//` in the replacement ended the expression. It uses `s#…#…#` now. `istioctl version --short` prints `client version: 1.31.0`, so the script compares the last word.
- Option 2 (custom tooling image with the tools built in) not pursued: it needs a registry and a rebuild per Istio version. Revisit only if the workshop runs often.
- [ ] Still to check once the mesh is installed: `istioctl ztunnel-config workload -n ztunnel` with the ztunnel RBAC from 1.2. Last resort if it doesn't work: Kiali views (Workloads → ztunnel details). The custom tooling image fallback isn't needed.

### 1.2 `scripts/setup-users.sh` (admin, idempotent)

Written (2026-11-10). Tested so far: syntax and user detection (finds `user1`–`user5` via the realm import, excludes `admin`). **The full run is still untested**, it needs the mesh (`Istio` CR, `ztunnel` namespace, Kiali route). Also check during that run that `IstioRevision.spec.version` holds the resolved version (e.g. `v1.31.0`, not the alias `v1.31-latest`). The script reads it from there, and `ISTIO_VERSION=1.31.0` overrides it.


User detection, first match wins:
1. Explicit list: `./scripts/setup-users.sh user1 user2 …` or `WORKSHOP_USERS="…"`.
2. RHDP Keycloak: `oc get keycloakrealmimport -A`, members of group `/users` (fall back to all users without `/admins` if the group is missing).
3. htpasswd IdP: user names from the secret referenced in `oauth/cluster`.
4. Existing `User` objects.

From every detected result, remove users with `cluster-admin` (direct or through a group). Users named on the command line or in `WORKSHOP_USERS` are kept even if they are cluster-admins, so that `setup-users.sh admin` works (decision 1). The realm import is matched by the realm name in the issuer URL of the OpenShift OpenID IdP, so the workshop's own `servicemesh` realm (testuser/adminuser) is never picked up. User names that aren't valid in namespace names are skipped with a warning. If no users are found, abort with a clear message. Print the detected list and ask for confirmation (`-y` to skip the prompt).

Per user:
- [x] Namespaces `<u>-apps`, `<u>-sidecar`, `<u>-terminal` with the labels from the table above + `servicemesh-workshop/user=<u>`
- [x] RoleBinding `admin` → user in all three namespaces (named `servicemesh-workshop-admin`)
- [x] ClusterRole `servicemesh-workshop-mesh-resources` (`networking`/`security`/`telemetry.istio.io`, Gateway API, PodMonitor/ServiceMonitor), bound with a RoleBinding in `<u>-apps` and `<u>-sidecar`. Bound per namespace rather than as `aggregate-to-admin`, which would change the `admin` role for the whole cluster
- [x] ClusterRole + ClusterRoleBinding `servicemesh-workshop-<u>-namespaces` (patch own namespaces, see design)
- [x] ConfigMap `workshop-info` in `<u>-terminal`
- [ ] Optional: ResourceQuota/LimitRange per namespace (default off, it matters for larger groups). Not implemented yet

Shared (once):
- [x] Namespace `workshop-tools` with the in-cluster tools server (see 1.1)
- [x] OpenShift Group `servicemesh-workshop-users` with all detected users. The cluster-scoped bindings go to the group. Existing members are kept, so adding a late user doesn't drop the others
- [x] `ztunnel` namespace: Role with `get/list pods`, `get pods/log`, `create pods/portforward`, bound to the group (needed for ch. 3 ztunnel logs and `istioctl ztunnel-config`). Note: users can see other users' workloads/logs in the ztunnel. That's acceptable for a workshop.
- [x] Metrics: `cluster-monitoring-view` for the group, because the L4 metrics live in the `ztunnel` namespace (ch. 2 "Metrics") and the Perses dashboards query across namespaces. Alternative: only `view` in `ztunnel` (needs testing whether Thanos tenancy is enough).
- [x] Perses: RoleBindings in `perses-dev` for whichever `perses(dashboard|datasource|globaldatasource)-viewer-role` ClusterRoles exist. Still to check after the install: do these role names exist in the installed COO version?
- [x] Step 5 of the script checks the first user with `oc auth can-i --as=<u> --as-group=servicemesh-workshop-users …` and warns for anything missing. Original item: verify that users can manage Gateway, HTTPRoute, ReferenceGrant, `networking.istio.io` (VirtualService, DestinationRule), `security.istio.io` (PeerAuthentication, AuthorizationPolicy, RequestAuthentication) and `monitoring.coreos.com` PodMonitor in their namespaces. Add aggregated ClusterRoles (`aggregate-to-admin`) for anything missing.
- [ ] Tempo: tenant `dev` is already readable by `system:authenticated`. Nothing to do, but all users see all traces (the chapter tells them to filter by their namespace).
- [ ] Kiali (OpenShift auth) shows only namespaces a user has access to. Check that users can log in to Kiali and to the OSSM console plugin.

Output at the end: table of users + namespaces, console URL, Kiali URL, repo URL to clone.

### 1.3 Integration with `install.sh`

- [x] Keep `install.sh` for the platform only (+ Web Terminal). At the end, print "next: `./scripts/setup-users.sh`" (or add an opt-in flag `--with-users`).
- [ ] Smoke test as a user: `oc login` as `user1` (or `--as`), go through ch. 2 (deploy, onboard, label), ch. 4 (gateway + waypoint) and ch. 10 (sidecar namespace).

---

## 2. Rewrite the instructions

Prerequisite: the manifest changes (see design decisions) are done first, because all chapters depend on them.

### 2.1 Manifests

- [ ] Remove hard-coded namespaces, introduce `${APPS_NS}`/`${SIDECAR_NS}` where references cross namespaces (see design)
- [ ] `k8s/apps/kustomization.yml` without `ns.yml`/`namespace:`. Delete `k8s/apps/ns.yml` (no single-user mode anymore)
- [ ] `k8s/sidecar` reworked (no Namespace patch)
- [ ] Gateway `allowedRoutes` → `Same`

### 2.2 Directory layout

`chapters/` is split into two directories, so each role knows right away which part is theirs:

```
admin-chapters/
  01-installation.md      # was chapters/01-installation.md (+ Web Terminal Operator)
  02-user-setup.md        # new: setup-users.sh, RBAC
  03-teardown.md          # new: cleanup-users.sh, cleanup.sh
user-chapters/
  01-getting-started.md   # new: Web Terminal, git clone, workshop-env.sh
  02-deploy-and-onboard.md … 10-sidecar-interop.md   # was chapters/02–10
```

- [ ] `git mv` the chapters (keeps the history). Both directories sit at the same depth as `chapters/`, so the `../assets/img/...` image links keep working
- [ ] Previous/next navigation stays within each directory. The last admin chapter links to "hand over to the users: `user-chapters/01-getting-started.md`", and user chapter 01 says "your admin has done `admin-chapters/`"
- [ ] Each directory gets a short intro block at the top of its first chapter: who this is for, which rights are needed (cluster-admin vs. workshop user)

### 2.3 Admin chapters

- [ ] `admin-chapters/01-installation.md`: add the Web Terminal Operator + idle timeout. Remove anything that's user work
- [ ] `admin-chapters/02-user-setup.md`: how detection works, what RBAC is created and why (table), running `setup-users.sh`, how to verify (`oc auth can-i --as=user1 …`), how to add a late user (re-run the script with the user name)
- [ ] `admin-chapters/03-teardown.md`: `cleanup-users.sh` between workshop runs, `cleanup.sh` to remove everything (section 3)

### 2.4 User chapters

- [ ] New `user-chapters/01-getting-started.md`: log in to the console as `userN`, open the Web Terminal (**select project `<u>-terminal`**), `git clone https://github.com/nikolaus-lemberski/openshift-servicemesh-ambient.git`, `cd`, `source scripts/workshop-env.sh`, check with `oc project`/`oc get ns`. Explain the three namespaces. Note on terminal restarts (re-source the env).
- [ ] Chapters 02–10: replace `servicemesh-apps` → `$APPS_NS`, `servicemesh-sidecar` → `$SIDECAR_NS` in commands. YAML snippets show `${APPS_NS}` where it matters. Kiali/console steps: "select your namespace `<u>-apps`"
- [ ] Ch. 2: remove `ns.yml`/namespace creation, keep the onboarding label step (users now have the permission). Metrics/Perses: filter by own namespace
- [ ] Ch. 3: the "outside the mesh" test runs directly from the Web Terminal (`curl http://service-c.$APPS_NS:8080/health`), the `curl-test` pod stays only in `$APPS_NS`. The ztunnel logs step: grep for the user's own namespace
- [ ] Ch. 4: gateway + route per user (host is generated per namespace, which is fine). Check that `istioctl ztunnel-config svc` works with the ztunnel RBAC
- [ ] Ch. 5: mention that tracing config (`Telemetry`, `istio-update`) is mesh-wide and done by the admin. Search traces by `service.name` / `waypoint.$APPS_NS`
- [ ] Ch. 6: `KEYCLOAK_HOST` from `workshop-env.sh` instead of `ingresses.config/cluster`. The Keycloak realm `servicemesh` (testuser/adminuser) is shared, which is fine
- [ ] Ch. 7–9: namespace replacements only. `oc port-forward` works inside the terminal
- [ ] Ch. 10: add an `oc label namespace $SIDECAR_NS istio-injection=enabled` step + `oc apply -k k8s/sidecar -n $SIDECAR_NS`. `envsubst` for files 1, 2, 4, 5
- [ ] All chapters: cleanup sections without the `default`-namespace steps
- [ ] README: workshop flow (admin → users), links to `admin-chapters/` and `user-chapters/`. Update CLAUDE.md (directories, namespace conventions, scripts)
- [ ] Screenshots show `servicemesh-apps`. Leave them (add a note) or retake them later

---

## 3. Teardown scripts

### 3.1 `scripts/cleanup-users.sh` (admin)

Removes everything `setup-users.sh` created, **not** the mesh infrastructure. It finds objects by label, not by detecting users again, so users removed from the IdP in the meantime are cleaned up too.

- [x] Confirmation prompt (`-y` to skip). Optional user list to clean up only some users
- [x] Delete namespaces with `servicemesh-workshop/user` (this also removes apps, gateways, waypoints, policies, curl pods and the users' DevWorkspaces/Web Terminals). Wait for them to be gone
- [x] Delete ClusterRoles/ClusterRoleBindings with the label
- [x] Shared objects: namespace `workshop-tools` (tools server), Group `servicemesh-workshop-users`, ztunnel Role/RoleBinding, `cluster-monitoring-view` binding, Perses bindings, any aggregated ClusterRoles
- [x] Doesn't touch `User`/`Identity` objects (created by the IdP at login, not by us), the Web Terminal Operator or the mesh
- [x] Idempotent, safe to run when nothing is there (same `safe_delete` style as `cleanup.sh`)
- [x] Note: traces of the users remain in Tempo storage until retention expires
- [x] With a user list, only their namespaces and ClusterRoles/Bindings go and they are removed from the Group; the shared objects stay. Without a list, everything labelled `servicemesh-workshop/user` or `servicemesh-workshop/shared=true` (namespace, Group, ClusterRole/Binding, Role/RoleBinding in any namespace) is deleted
- [x] Tested on the cluster with stand-in objects (two fake users, a shared namespace, Group, Role/RoleBinding): partial run, full run and a second run on an empty cluster. Still to test after `setup-users.sh` has run for real (Web Terminal DevWorkspaces in `<u>-terminal`, waypoints in `<u>-apps`)

### 3.2 `scripts/cleanup.sh` (platform)

- [x] Step 1: call `cleanup-users.sh -y` first (ambient namespaces should be removed before Istio goes away). Replace the removal of `servicemesh-apps`/`servicemesh-sidecar` and the `curl-test` pod in `default` with it
- [x] Step 7 deletes all Web Terminal DevWorkspaces (`console.openshift.io/terminal=true`) while the controller still runs, then the `web-terminal` templates and Subscription. The DevWorkspace Operator is removed only if the `servicemesh-workshop/devworkspace-operator=installed` annotation is set **and** no other DevWorkspaces remain (Dev Spaces uses it too)
- [x] `web-terminal` (always) and `devworkspace-operator` (same condition) added to the CSV, ClusterRole, CRD and Operator cleanup loops
- [x] DevWorkspace leftovers that OLM doesn't remove: webhook configurations `controller.devfile.io` (left behind, they would block `oc exec` cluster-wide), webhook server deployment/service/SA/TLS secret, ClusterRole/Bindings `devworkspace-webhook-server` and the `auth-delegator` binding
- [x] The idle timeout needs no revert: the patched template is deleted together with the operator
- [ ] **Not tested yet** on the cluster (the run was blocked). Test: open a terminal, run `cleanup.sh`, check that no `devfile` webhooks/CRDs are left and that `oc exec` still works, then reinstall the Web Terminal

### 3.3 Optional: `scripts/reset-my-namespaces.sh` (user)

- [ ] Lets a user reset their own namespaces mid-workshop (delete all workshop resources, remove the onboarding labels) without the admin

---

## Decisions (agreed 2026-11-10)

1. **No single-user mode.** An admin who wants to try the chapters runs `setup-users.sh admin` and works as a "user". The manifests and chapters exist only once.
2. **Namespaces** `<u>-apps` / `<u>-sidecar` / `<u>-terminal`.
3. **istioctl:** no per-user downloads from GitHub (rate-limit risk with up to 70 users behind one IP). Served by an in-cluster tools server in `workshop-tools` (option 1). TODO: check during the full install whether OSSM 3 provides an `istioctl` download in the console (option 3) and use that instead if it works (see 1.1).
4. **Metrics:** `cluster-monitoring-view` for the group `servicemesh-workshop-users`.
5. **Chapters:** split into `admin-chapters/` and `user-chapters/` (2.2).
