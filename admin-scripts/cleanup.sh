#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
YELLOW='\033[1;33m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[1;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }

safe_delete() {
  if oc get "$@" &>/dev/null; then
    oc delete "$@" --ignore-not-found --wait=false
    ok "Deleted $*"
  fi
}

safe_delete_ns() {
  local ns=$1
  if oc get namespace "$ns" &>/dev/null; then
    oc delete namespace "$ns" --ignore-not-found --wait=false
    ok "Deleting namespace ${ns} (background)"
  fi
}

echo ""
echo -e "${RED}========================================${NC}"
echo -e "${RED} Service Mesh 3 Ambient - Cleanup${NC}"
echo -e "${RED}========================================${NC}"
echo ""

read -rp "This will remove the entire Service Mesh 3 installation. Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

# ----------------------------------------------------------------------------
# Step 1: Workshop users
# ----------------------------------------------------------------------------
info "Step 1: Removing workshop users ..."
# Waits for the user namespaces, ambient namespaces should be gone before Istio is removed
"${SCRIPT_DIR}/admin-scripts/cleanup-users.sh" -y || warn "cleanup-users.sh failed, continuing"

# ----------------------------------------------------------------------------
# Step 2: Keycloak
# ----------------------------------------------------------------------------
info "Step 2: Removing Keycloak ..."
oc delete -f "${SCRIPT_DIR}/k8s/istiofeatures/gateway-auth/3-authorization-policy-require-admin.yml" --ignore-not-found 2>/dev/null || true
oc delete -f "${SCRIPT_DIR}/k8s/istiofeatures/gateway-auth/1-request-authentication.yml" --ignore-not-found 2>/dev/null || true
safe_delete keycloakrealmimport servicemesh -n servicemesh-keycloak
safe_delete keycloak keycloak -n servicemesh-keycloak
oc wait --for=delete keycloak/keycloak -n servicemesh-keycloak --timeout=120s 2>/dev/null || true
safe_delete subscription rhbk-operator -n servicemesh-keycloak
for csv in $(oc get csv -n servicemesh-keycloak -o name 2>/dev/null | grep rhbk-operator || true); do
  oc delete "$csv" -n servicemesh-keycloak --ignore-not-found 2>/dev/null || true
  ok "Deleted ${csv} in servicemesh-keycloak"
done
safe_delete_ns servicemesh-keycloak
ok "Keycloak removed"

# ----------------------------------------------------------------------------
# Step 3: UI Plugins (Distributed Tracing + Perses Monitoring)
# ----------------------------------------------------------------------------
info "Step 3: Removing UI Plugins ..."
safe_delete uiplugin distributed-tracing
safe_delete uiplugin monitoring
oc wait --for=delete uiplugin/distributed-tracing uiplugin/monitoring --timeout=120s 2>/dev/null || true
# COO removes the ConsolePlugins, but not their entries in the console config
for plugin in distributed-tracing-console-plugin monitoring-console-plugin; do
  idx=$(oc get consoles.operator.openshift.io cluster -o jsonpath='{range .spec.plugins[*]}{@}{"\n"}{end}' | grep -nx "$plugin" | cut -d: -f1)
  if [[ -n "$idx" ]]; then
    oc patch consoles.operator.openshift.io cluster --type=json -p "[{\"op\":\"remove\",\"path\":\"/spec/plugins/$((idx - 1))\"}]"
    ok "Removed ${plugin} from the console config"
  fi
done

# ----------------------------------------------------------------------------
# Step 4: Tracing resources
# ----------------------------------------------------------------------------
info "Step 4: Removing tracing resources ..."
oc delete -f "${SCRIPT_DIR}/k8s/tracing/istio-update.yml" --ignore-not-found 2>/dev/null || true
oc delete -f "${SCRIPT_DIR}/k8s/tracing/telemetry.yml" --ignore-not-found 2>/dev/null || true
oc delete -f "${SCRIPT_DIR}/k8s/tracing/networkpolicies.yml" --ignore-not-found 2>/dev/null || true
oc delete -f "${SCRIPT_DIR}/k8s/tracing/otel-collector.yml" --ignore-not-found 2>/dev/null || true

safe_delete tempostack tempostack -n tempostack
safe_delete secret s3-bucket -n tempostack
safe_delete clusterrolebinding tempostack-traces-reader
safe_delete clusterrole tempostack-traces-reader
safe_delete clusterrolebinding tempostack-traces-writer
safe_delete clusterrole tempostack-traces-writer
safe_delete rolebinding view -n tempostack
safe_delete objectbucketclaim tempostorage -n tempostack
safe_delete_ns seaweedfs
ok "Tracing resources removed"

# ----------------------------------------------------------------------------
# Step 5: Observability stack
# ----------------------------------------------------------------------------
info "Step 5: Removing observability stack ..."
oc delete -k "${SCRIPT_DIR}/k8s/observability" --ignore-not-found 2>/dev/null || true
ok "Observability resources removed"

# ----------------------------------------------------------------------------
# Step 6: Istio, IstioCNI, ZTunnel
# ----------------------------------------------------------------------------
info "Step 6: Removing Istio, IstioCNI, and ZTunnel ..."
safe_delete ztunnel default
safe_delete istiocni default
safe_delete istio default

info "Waiting for Istio components to terminate ..."
oc wait --for=delete istio/default --timeout=120s 2>/dev/null || true
oc wait --for=delete istiocni/default --timeout=120s 2>/dev/null || true
oc wait --for=delete ztunnel/default --timeout=120s 2>/dev/null || true
# istiod creates the GatewayClasses, but doesn't remove them
safe_delete gatewayclass istio istio-remote istio-waypoint
ok "Istio components removed"

# ----------------------------------------------------------------------------
# Step 7: Operator subscriptions and CSVs
# ----------------------------------------------------------------------------
info "Step 7: Removing operator subscriptions ..."
# Web Terminals are DevWorkspaces, delete them while the DevWorkspace controller still runs (it removes their finalizers)
oc delete devworkspaces.workspace.devfile.io -A -l console.openshift.io/terminal=true --ignore-not-found 2>/dev/null || true
oc delete devworkspacetemplates.workspace.devfile.io -A -l console.openshift.io/terminal=true --ignore-not-found 2>/dev/null || true
# The DevWorkspace operator comes with the Web Terminal, but Dev Spaces uses it too.
# Only remove it if install.sh installed it and no other DevWorkspaces are left
REMOVE_DEVWORKSPACE=false
if [[ "$(oc get namespace openshift-operators \
    -o jsonpath='{.metadata.annotations.servicemesh-workshop/devworkspace-operator}')" == "installed" ]]; then
  if [[ -z "$(oc get devworkspaces.workspace.devfile.io -A --no-headers 2>/dev/null)" ]]; then
    REMOVE_DEVWORKSPACE=true
    oc delete devworkspaceroutings.controller.devfile.io -A --all --ignore-not-found 2>/dev/null || true
  else
    warn "Other DevWorkspaces exist, keeping the DevWorkspace operator"
  fi
fi

safe_delete subscription web-terminal -n openshift-operators
if $REMOVE_DEVWORKSPACE; then
  oc delete subscription -n openshift-operators -l operators.coreos.com/devworkspace-operator.openshift-operators --ignore-not-found
fi
safe_delete subscription kiali-ossm -n openshift-operators
safe_delete subscription servicemeshoperator3 -n openshift-operators
safe_delete subscription tempo-product -n openshift-tempo-operator
safe_delete subscription opentelemetry-product -n openshift-opentelemetry-operator
safe_delete subscription cluster-observability-operator -n openshift-cluster-observability-operator

WORKSHOP_CSVS="kiali|servicemesh|tempo|opentelemetry|cluster-observability|web-terminal"
WORKSHOP_OLM_OWNERS="kiali-operator|servicemeshoperator3|tempo-operator|opentelemetry-operator|cluster-observability-operator|web-terminal"
if $REMOVE_DEVWORKSPACE; then
  WORKSHOP_CSVS+="|devworkspace-operator"
  WORKSHOP_OLM_OWNERS+="|devworkspace-operator"
fi

info "Removing ClusterServiceVersions ..."
for ns in openshift-operators openshift-tempo-operator openshift-opentelemetry-operator openshift-cluster-observability-operator; do
  for csv in $(oc get csv -n "$ns" -l '!olm.copiedFrom' -o name 2>/dev/null | grep -E "$WORKSHOP_CSVS" || true); do
    oc delete "$csv" -n "$ns" --ignore-not-found 2>/dev/null || true
    ok "Deleted ${csv} in ${ns}"
  done
done

# OLM doesn't remove cluster-scoped RBAC shipped in the bundles
for res in $(oc get clusterrole,clusterrolebinding -l olm.managed=true \
    -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} {.metadata.labels.olm\.owner} {.metadata.labels.app\.kubernetes\.io/name}{"\n"}{end}' 2>/dev/null \
    | grep -E " (${WORKSHOP_OLM_OWNERS})(\.| |$)" \
    | cut -d' ' -f1 || true); do
  oc delete "$res" --ignore-not-found 2>/dev/null || true
  ok "Deleted ${res}"
done
# The Perses roles of the Cluster Observability Operator don't always keep the olm.owner label
for res in $(oc get clusterrole -l olm.managed=true,app.kubernetes.io/part-of=perses-operator -o name 2>/dev/null); do
  oc delete "$res" --ignore-not-found 2>/dev/null || true
  ok "Deleted ${res}"
done

if $REMOVE_DEVWORKSPACE; then
  # The DevWorkspace controller creates its webhook server itself, OLM doesn't remove it.
  # Left behind without a running server, the webhooks would block pod exec cluster-wide
  safe_delete mutatingwebhookconfiguration controller.devfile.io
  safe_delete validatingwebhookconfiguration controller.devfile.io
  safe_delete deployment devworkspace-webhook-server -n openshift-operators
  safe_delete service devworkspace-webhookserver -n openshift-operators
  safe_delete serviceaccount devworkspace-webhook-server -n openshift-operators
  safe_delete secret devworkspace-webhookserver-tls -n openshift-operators
  safe_delete clusterrole devworkspace-webhook-server
  safe_delete clusterrolebinding devworkspace-webhook-server
  safe_delete clusterrolebinding devworkspace-controller-manager-service-system:auth-delegator
fi

# OLM doesn't remove CRDs either. CRDs also used by another installation of the same operator
# (e.g. a second rhbk-operator) carry its label as well, those only lose the workshop label.
# OLM truncates the operator names (<package>.<namespace>) to 63 characters.
info "Removing operator CRDs ..."
WORKSHOP_OPERATORS="kiali-ossm.openshift-operators servicemeshoperator3.openshift-operators
  tempo-product.openshift-tempo-operator opentelemetry-product.openshift-opentelemetry-operator
  cluster-observability-operator.openshift-cluster-observability rhbk-operator.servicemesh-keycloak
  web-terminal.openshift-operators"
$REMOVE_DEVWORKSPACE && WORKSHOP_OPERATORS+=" devworkspace-operator.openshift-operators"
for op in $WORKSHOP_OPERATORS; do
  for crd in $(oc get crd -l "operators.coreos.com/${op}" -o name 2>/dev/null); do
    [[ "$crd" =~ \.gateway\.networking\.(x-)?k8s\.io$ ]] && continue  # shipped with OpenShift
    if oc get "$crd" -o jsonpath='{.metadata.labels}' | grep -o '"operators.coreos.com/[^"]*"' | grep -vq "\"operators.coreos.com/${op}\""; then
      oc label "$crd" "operators.coreos.com/${op}-" >/dev/null
      ok "Kept ${crd} (used by another operator installation)"
    else
      oc delete "$crd" --ignore-not-found --wait=false >/dev/null
      ok "Deleted ${crd}"
    fi
  done
done
ok "Operator subscriptions, CSVs, and CRDs removed"

# ----------------------------------------------------------------------------
# Step 8: Namespaces
# ----------------------------------------------------------------------------
info "Step 8: Removing namespaces ..."
safe_delete_ns perses-dev
safe_delete_ns tempostack
safe_delete_ns istio-system
safe_delete_ns istio-cni
safe_delete_ns ztunnel
safe_delete_ns openshift-tempo-operator
safe_delete_ns openshift-opentelemetry-operator
safe_delete_ns openshift-cluster-observability-operator
# The console creates it for the Web Terminals of cluster admins
safe_delete_ns openshift-terminal

info "Waiting for namespaces to terminate ..."
oc wait --for=delete namespace/servicemesh-keycloak namespace/seaweedfs namespace/perses-dev \
  namespace/tempostack namespace/istio-system namespace/istio-cni namespace/ztunnel \
  namespace/openshift-tempo-operator namespace/openshift-opentelemetry-operator \
  namespace/openshift-cluster-observability-operator namespace/openshift-terminal --timeout=300s 2>/dev/null || true

# OLM keeps an Operator resource as long as components of the operator exist
for op in $WORKSHOP_OPERATORS; do
  safe_delete operators.operators.coreos.com "$op"
done

# ----------------------------------------------------------------------------
# Step 9: Revert cluster settings changed by install.sh
# ----------------------------------------------------------------------------
info "Step 9: Reverting cluster settings ..."
case "$(oc -n openshift-monitoring get configmap cluster-monitoring-config \
    -o jsonpath='{.metadata.annotations.servicemesh-workshop/user-workload-monitoring}' 2>/dev/null)" in
  created)
    oc -n openshift-monitoring delete configmap cluster-monitoring-config
    # Created by the cluster monitoring operator for user workload monitoring, but not removed
    safe_delete clusterrolebinding thanos-ruler-monitoring
    ok "Deleted cluster-monitoring-config (user workload monitoring disabled)"
    ;;
  enabled)
    monitoring_config=$(oc -n openshift-monitoring get configmap cluster-monitoring-config -o jsonpath='{.data.config\.yaml}' \
      | grep -vE '^enableUserWorkload:' || true)
    oc -n openshift-monitoring set data configmap/cluster-monitoring-config "config.yaml=${monitoring_config}"
    oc -n openshift-monitoring annotate configmap cluster-monitoring-config servicemesh-workshop/user-workload-monitoring-
    ok "Removed enableUserWorkload from cluster-monitoring-config"
    ;;
  *)
    info "User workload monitoring was not enabled by install.sh, leaving it as is"
    ;;
esac

if [[ "$(oc get namespace openshift-operators \
    -o jsonpath='{.metadata.annotations.servicemesh-workshop/pod-security-label-sync}')" == "unset" ]]; then
  oc label namespace openshift-operators security.openshift.io/scc.podSecurityLabelSync- \
    pod-security.kubernetes.io/audit- pod-security.kubernetes.io/audit-version- \
    pod-security.kubernetes.io/warn- pod-security.kubernetes.io/warn-version- >/dev/null
  oc annotate namespace openshift-operators security.openshift.io/MinimallySufficientPodSecurityStandard- \
    servicemesh-workshop/pod-security-label-sync- >/dev/null
  ok "Reverted Pod Security label sync on openshift-operators"
fi

if $REMOVE_DEVWORKSPACE; then
  oc annotate namespace openshift-operators servicemesh-workshop/devworkspace-operator- >/dev/null
  ok "Removed the DevWorkspace operator marker from openshift-operators"
fi

if [[ "$(oc get networks.operator.openshift.io cluster \
    -o jsonpath='{.metadata.annotations.servicemesh-workshop/routing-via-host}')" == "patched" ]]; then
  oc patch networks.operator.openshift.io cluster --type=json \
    -p='[{"op":"remove","path":"/spec/defaultNetwork/ovnKubernetesConfig/gatewayConfig/routingViaHost"}]'
  oc annotate networks.operator.openshift.io cluster servicemesh-workshop/routing-via-host-
  ok "Reverted OVN-Kubernetes local gateway mode"
else
  info "OVN-Kubernetes local gateway mode was not set by install.sh, leaving it as is"
fi

# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Cleanup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
warn "Namespace deletions may still be finalizing in the background."
warn "Console plugins were removed — you may need to refresh your browser."
echo ""
