#!/usr/bin/env bash
# Removes what setup-users.sh created: the user namespaces (with everything the users deployed), the RBAC and the
# tools server. The mesh, the Web Terminal Operator and the User/Identity objects stay.
#
# Usage: ./admin-scripts/cleanup-users.sh [-y] [user ...]
#   Without user names, all workshop users and the shared objects are removed
set -uo pipefail

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
USER_LABEL=servicemesh-workshop/user
SHARED_LABEL=servicemesh-workshop/shared=true

ASSUME_YES=false
USERS=()
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) fail "Unknown option: ${arg}" ;;
    *) USERS+=("$arg") ;;
  esac
done

# Objects are found by label, not by detecting the users again, so users removed from the IdP are cleaned up too
if (( ${#USERS[@]} > 0 )); then
  SELECTOR="${USER_LABEL} in ($(IFS=,; echo "${USERS[*]}"))"
else
  SELECTOR="$USER_LABEL"
fi
FOUND=$(oc get namespaces -l "$SELECTOR" \
  -o jsonpath="{range .items[*]}{.metadata.labels.servicemesh-workshop/user}{\"\n\"}{end}" | sort -uV | xargs)

echo ""
if (( ${#USERS[@]} > 0 )); then
  info "Removing the workshop users: ${USERS[*]}"
  [[ -n "$FOUND" ]] || info "No namespaces found for them"
else
  info "Removing all workshop users (${FOUND:-none found}) and the shared objects (tools server, group, RBAC)"
fi
if ! $ASSUME_YES; then
  read -rp "This deletes the user namespaces with everything deployed in them. Continue? [y/N] " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

# ----------------------------------------------------------------------------
# Step 1: User namespaces and per-user RBAC
# ----------------------------------------------------------------------------
info "Step 1: Removing the user namespaces ..."
# Also removes the apps, gateways, waypoints, policies and the users' Web Terminals (DevWorkspaces)
for ns in $(oc get namespaces -l "$SELECTOR" -o name); do
  oc delete "$ns" --ignore-not-found --wait=false >/dev/null
  ok "Deleting ${ns#*/} (background)"
done
for res in $(oc get clusterrolebinding,clusterrole -l "$SELECTOR" -o name); do
  oc delete "$res" --ignore-not-found >/dev/null
  ok "Deleted ${res}"
done

# ----------------------------------------------------------------------------
# Step 2: Shared objects, or only the group membership of the given users
# ----------------------------------------------------------------------------
if (( ${#USERS[@]} > 0 )); then
  info "Step 2: Removing the users from the group ${GROUP} ..."
  members=$(oc get group "$GROUP" -o jsonpath='{range .users[*]}{@}{"\n"}{end}' 2>/dev/null)
  remove=$(printf '%s\n' "${USERS[@]}" | grep -xF -f <(echo "$members") || true)
  if [[ -n "$remove" ]]; then
    # shellcheck disable=SC2086
    oc adm groups remove-users "$GROUP" $remove >/dev/null
    ok "Removed $(xargs <<<"$remove") from ${GROUP}"
  fi
else
  info "Step 2: Removing the shared objects ..."
  # Namespace workshop-tools, Group, mesh-resources and monitoring-view ClusterRoles
  for res in $(oc get namespace,group,clusterrolebinding,clusterrole -l "$SHARED_LABEL" -o name); do
    oc delete "$res" --ignore-not-found --wait=false >/dev/null
    ok "Deleted ${res}"
  done
  # ztunnel Role/RoleBinding, Perses RoleBindings
  while read -r ns res; do
    [[ -z "$ns" ]] && continue
    oc delete "$res" -n "$ns" --ignore-not-found >/dev/null
    ok "Deleted ${res} in ${ns}"
  done < <(oc get rolebinding,role -A -l "$SHARED_LABEL" \
    -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.kind}/{.metadata.name}{"\n"}{end}')
fi

# ----------------------------------------------------------------------------
# Step 3: Wait for the namespaces
# ----------------------------------------------------------------------------
info "Step 3: Waiting for the namespaces to terminate ..."
# Ambient namespaces should be gone before cleanup.sh removes Istio
WAIT_FOR=("$SELECTOR")
(( ${#USERS[@]} > 0 )) || WAIT_FOR+=("$SHARED_LABEL")
for selector in "${WAIT_FOR[@]}"; do
  [[ -n "$(oc get namespaces -l "$selector" -o name)" ]] || continue
  oc wait --for=delete namespace -l "$selector" --timeout=300s >/dev/null 2>&1 || \
    warn "Namespaces still terminating: $(oc get namespaces -l "$selector" -o name | xargs)"
done

# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Workshop users removed!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
info "The User and Identity objects stay, they belong to the identity provider."
info "Traces of the users stay in the Tempo storage until the retention expires."
echo ""
