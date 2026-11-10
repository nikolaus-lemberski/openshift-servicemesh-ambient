#!/usr/bin/env bash
# Sets up the workshop users: namespaces, RBAC and the Web Terminal tools. Run as cluster-admin after install.sh.
# Idempotent, re-run it with a user name to add a late user.
#
# Usage: ./scripts/setup-users.sh [-y] [user ...]
#   Without user names, the users are detected (WORKSHOP_USERS, Keycloak realm import, htpasswd, User objects)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

GROUP=servicemesh-workshop-users
TOOLS_URL="http://tools.workshop-tools.svc:8080"

ASSUME_YES=false
EXPLICIT_USERS=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) fail "Unknown option: ${arg}" ;;
    *) EXPLICIT_USERS+=("$arg") ;;
  esac
done

# ----------------------------------------------------------------------------
# User detection
# ----------------------------------------------------------------------------
# Users of the Keycloak realm behind the OpenShift OpenID identity provider (RHDP clusters).
# Members of group /users, or all users not in /admins if there is no /users group
keycloak_users() {
  local issuer realm ns name
  for issuer in $(oc get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.type=="OpenID")].openID.issuer}'); do
    realm=${issuer##*/realms/}
    realm=${realm%%/*}
    while read -r ns name; do
      [[ -z "$ns" ]] && continue
      local users
      users=$(oc get keycloakrealmimport "$name" -n "$ns" \
        -o jsonpath='{range .spec.realm.users[*]}{.username}{" "}{.groups}{"\n"}{end}')
      if grep -q '"/users"' <<<"$users"; then
        grep '"/users"' <<<"$users" | cut -d' ' -f1
      else
        grep -v '"/admins"' <<<"$users" | cut -d' ' -f1
      fi
    done < <(oc get keycloakrealmimport -A \
      -o jsonpath="{range .items[?(@.spec.realm.realm==\"${realm}\")]}{.metadata.namespace}{\" \"}{.metadata.name}{\"\n\"}{end}" 2>/dev/null)
  done
}

htpasswd_users() {
  local secret
  for secret in $(oc get oauth cluster -o jsonpath='{.spec.identityProviders[?(@.type=="HTPasswd")].htpasswd.fileData.name}'); do
    oc get secret "$secret" -n openshift-config -o jsonpath='{.data.htpasswd}' | base64 --decode | cut -d: -f1
  done
}

existing_users() {
  oc get users -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
}

# Users with cluster-admin, directly or through a group
cluster_admins() {
  local kind name
  while read -r kind name; do
    case "$kind" in
      User) echo "$name" ;;
      Group) oc get group "$name" -o jsonpath='{range .users[*]}{@}{"\n"}{end}' 2>/dev/null || true ;;
    esac
  done < <(oc get clusterrolebinding \
    -o jsonpath='{range .items[?(@.roleRef.name=="cluster-admin")]}{range .subjects[*]}{.kind}{" "}{.name}{"\n"}{end}{end}')
}

if (( ${#EXPLICIT_USERS[@]} > 0 )); then
  SOURCE="command line"
  DETECTED=$(printf '%s\n' "${EXPLICIT_USERS[@]}")
elif [[ -n "${WORKSHOP_USERS:-}" ]]; then
  SOURCE="WORKSHOP_USERS"
  DETECTED=$(tr ' ,' '\n\n' <<<"$WORKSHOP_USERS")
else
  for SOURCE in "Keycloak realm import" "htpasswd identity provider" "User objects"; do
    case "$SOURCE" in
      Keycloak*) DETECTED=$(keycloak_users) ;;
      htpasswd*) DETECTED=$(htpasswd_users) ;;
      User*) DETECTED=$(existing_users) ;;
    esac
    # Detected cluster-admins aren't workshop users. Named on the command line, they are (e.g. to try the chapters as admin)
    DETECTED=$(grep -vxF -f <(cluster_admins; echo kube:admin) <<<"$DETECTED" || true)
    [[ -n "$DETECTED" ]] && break
  done
fi

USERS=()
for u in $(sort -uV <<<"$DETECTED"); do
  # The user name becomes part of the namespace names
  if [[ "$u" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && (( ${#u} <= 54 )); then
    USERS+=("$u")
  else
    warn "Skipping '${u}': not usable in a namespace name"
  fi
done
(( ${#USERS[@]} > 0 )) || fail "No workshop users found. Pass them as arguments: $0 user1 user2 ..."

echo ""
info "Workshop users (from ${SOURCE}): ${USERS[*]}"
if ! $ASSUME_YES; then
  read -rp "Set up ${#USERS[@]} users? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ----------------------------------------------------------------------------
# Step 1: Platform values for the users
# ----------------------------------------------------------------------------
info "Step 1: Reading the platform settings ..."
oc get istio default &>/dev/null || fail "Istio 'default' not found. Run ./scripts/install.sh first."
# Istio.spec.version can be an alias like v1.31-latest, the IstioRevision has the resolved version
ISTIO_VERSION=${ISTIO_VERSION:-$(oc get istiorevision -o jsonpath='{.items[0].spec.version}')}
ISTIO_VERSION=${ISTIO_VERSION#v}
[[ "$ISTIO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  fail "Couldn't determine the Istio version ('${ISTIO_VERSION}'). Set ISTIO_VERSION, e.g. ISTIO_VERSION=1.31.0"
KEYCLOAK_HOST="keycloak.$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
CONSOLE_URL="https://$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
KIALI_URL="https://$(oc get route kiali -n istio-system -o jsonpath='{.spec.host}')"
export ISTIO_VERSION
ok "Istio ${ISTIO_VERSION}, Keycloak ${KEYCLOAK_HOST}"

# ----------------------------------------------------------------------------
# Step 2: Tools server for the Web Terminals
# ----------------------------------------------------------------------------
info "Step 2: Deploying the tools server (istioctl ${ISTIO_VERSION}, envsubst) ..."
# Only substitute ISTIO_VERSION, the envsubst script in the manifest contains $ENV
envsubst '${ISTIO_VERSION}' < "${SCRIPT_DIR}/k8s/workshop-tools/tools-server.yml" | oc apply -f -
oc rollout status deployment/tools -n workshop-tools --timeout=300s || \
  fail "Tools server not ready, check: oc logs -n workshop-tools deploy/tools -c download"
ok "Tools server ready at ${TOOLS_URL}"

# ----------------------------------------------------------------------------
# Step 3: Shared RBAC
# ----------------------------------------------------------------------------
info "Step 3: Setting up the group and shared RBAC ..."
# Keep earlier members, so that adding a late user doesn't drop the others
GROUP_USERS=$( (oc get group "$GROUP" -o jsonpath='{range .users[*]}{@}{"\n"}{end}' 2>/dev/null || true; \
  printf '%s\n' "${USERS[@]}") | sort -uV)
oc apply -f - <<EOF
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  name: ${GROUP}
  labels:
    servicemesh-workshop/shared: "true"
users:
$(sed 's/^/- /' <<<"$GROUP_USERS")
EOF

# Mesh resources in the users' namespaces. Bound per namespace instead of aggregated to admin,
# which would change the admin role of the whole cluster
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: servicemesh-workshop-mesh-resources
  labels:
    servicemesh-workshop/shared: "true"
rules:
- apiGroups: [networking.istio.io, security.istio.io, telemetry.istio.io]
  resources: ["*"]
  verbs: [get, list, watch, create, update, patch, delete, deletecollection]
- apiGroups: [gateway.networking.k8s.io]
  resources: [gateways, httproutes, grpcroutes, referencegrants]
  verbs: [get, list, watch, create, update, patch, delete, deletecollection]
- apiGroups: [monitoring.coreos.com]
  resources: [podmonitors, servicemonitors]
  verbs: [get, list, watch, create, update, patch, delete, deletecollection]
EOF

# ztunnel logs (ch. 3) and istioctl ztunnel-config (ch. 4). Users see the ztunnel entries of all users
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: servicemesh-workshop-ztunnel
  namespace: ztunnel
  labels:
    servicemesh-workshop/shared: "true"
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [pods/log]
  verbs: [get]
- apiGroups: [""]
  resources: [pods/portforward]
  verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: servicemesh-workshop-ztunnel
  namespace: ztunnel
  labels:
    servicemesh-workshop/shared: "true"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: servicemesh-workshop-ztunnel
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: ${GROUP}
---
# The L4 metrics live in the ztunnel namespace and the Perses dashboards query across namespaces
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: servicemesh-workshop-cluster-monitoring-view
  labels:
    servicemesh-workshop/shared: "true"
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-monitoring-view
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: Group
  name: ${GROUP}
EOF

# Perses dashboards and datasource, the role names depend on the Cluster Observability Operator version
if oc get namespace perses-dev &>/dev/null; then
  for role in $(oc get clusterrole -o name | grep -E '/perses(dashboard|datasource|globaldatasource)-viewer-role$' | cut -d/ -f2); do
    oc create rolebinding "servicemesh-workshop-${role}" -n perses-dev --clusterrole="$role" --group="$GROUP" \
      --dry-run=client -o yaml | oc label --local -f - servicemesh-workshop/shared=true -o yaml | oc apply -f -
  done
else
  warn "Namespace perses-dev not found, skipping the Perses access"
fi
ok "Shared RBAC ready"

# ----------------------------------------------------------------------------
# Step 4: Per-user namespaces and RBAC
# ----------------------------------------------------------------------------
info "Step 4: Setting up the user namespaces ..."
for u in "${USERS[@]}"; do
  oc apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${u}-apps
  labels:
    istio-discovery: enabled
    servicemesh-workshop/user: ${u}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${u}-sidecar
  labels:
    istio-discovery: enabled
    servicemesh-workshop/user: ${u}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${u}-terminal
  labels:
    servicemesh-workshop/user: ${u}
---
# Users label their namespaces themselves (ambient onboarding, waypoint, sidecar injection)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: servicemesh-workshop-${u}-namespaces
  labels:
    servicemesh-workshop/user: ${u}
rules:
- apiGroups: [""]
  resources: [namespaces]
  resourceNames: [${u}-apps, ${u}-sidecar]
  verbs: [get, patch, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: servicemesh-workshop-${u}-namespaces
  labels:
    servicemesh-workshop/user: ${u}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: servicemesh-workshop-${u}-namespaces
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: ${u}
---
# Read by workshop-env.sh, users can't read the cluster-scoped objects these values come from
apiVersion: v1
kind: ConfigMap
metadata:
  name: workshop-info
  namespace: ${u}-terminal
data:
  KEYCLOAK_HOST: ${KEYCLOAK_HOST}
  ISTIO_VERSION: "${ISTIO_VERSION}"
  TOOLS_URL: ${TOOLS_URL}
  KIALI_URL: ${KIALI_URL}
  CONSOLE_URL: ${CONSOLE_URL}
EOF
  for ns in "${u}-apps" "${u}-sidecar" "${u}-terminal"; do
    oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: servicemesh-workshop-admin
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: ${u}
EOF
    if [[ "$ns" != *-terminal ]]; then
      oc apply -f - >/dev/null <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: servicemesh-workshop-mesh-resources
  namespace: ${ns}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: servicemesh-workshop-mesh-resources
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: ${u}
EOF
    fi
  done
  ok "User ${u} ready"
done

# ----------------------------------------------------------------------------
# Step 5: Verify the permissions of the first user
# ----------------------------------------------------------------------------
u=${USERS[0]}
info "Step 5: Checking the permissions of ${u} ..."
missing=0
check() {
  if ! oc auth can-i "$@" --as="$u" --as-group="$GROUP" --as-group=system:authenticated &>/dev/null; then
    warn "${u} can't: $*"
    missing=$((missing + 1))
  fi
}
for res in deployments services serviceaccounts routes.route.openshift.io \
    gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io \
    virtualservices.networking.istio.io destinationrules.networking.istio.io \
    peerauthentications.security.istio.io authorizationpolicies.security.istio.io requestauthentications.security.istio.io \
    podmonitors.monitoring.coreos.com; do
  check create "$res" -n "${u}-apps"
done
check patch "namespace/${u}-apps"
check patch "namespace/${u}-sidecar"
check create devworkspaces.workspace.devfile.io -n "${u}-terminal"
check get configmap/workshop-info -n "${u}-terminal"
check get pods/log -n ztunnel
check create pods/portforward -n ztunnel
(( missing == 0 )) && ok "All permissions in place" || warn "${missing} permission checks failed"

# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Workshop users ready!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
printf '  %-20s %s\n' "USER" "NAMESPACES"
for u in "${USERS[@]}"; do
  printf '  %-20s %s\n' "$u" "${u}-apps ${u}-sidecar ${u}-terminal"
done
echo ""
info "Console:  ${CONSOLE_URL}"
info "Kiali:    ${KIALI_URL}"
info "Users open the Web Terminal in project <user>-terminal and run:"
REPO_URL=$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null | sed 's#^git@github.com:#https://github.com/#')
echo "  git clone ${REPO_URL}"
echo "  cd $(basename "$REPO_URL" .git) && source scripts/workshop-env.sh"
echo ""
