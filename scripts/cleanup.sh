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
# Step 1: UI Plugins (Distributed Tracing + Perses Monitoring)
# ----------------------------------------------------------------------------
info "Step 1: Removing UI Plugins ..."
safe_delete uiplugin distributed-tracing
safe_delete uiplugin monitoring

# ----------------------------------------------------------------------------
# Step 2: Tracing resources
# ----------------------------------------------------------------------------
info "Step 2: Removing tracing resources ..."
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
# Step 3: Observability stack
# ----------------------------------------------------------------------------
info "Step 3: Removing observability stack ..."
oc delete -k "${SCRIPT_DIR}/k8s/observability" --ignore-not-found 2>/dev/null || true
ok "Observability resources removed"

# ----------------------------------------------------------------------------
# Step 4: Istio, IstioCNI, ZTunnel
# ----------------------------------------------------------------------------
info "Step 4: Removing Istio, IstioCNI, and ZTunnel ..."
safe_delete ztunnel default
safe_delete istiocni default
safe_delete istio default

info "Waiting for Istio components to terminate ..."
oc wait --for=delete istio/default --timeout=120s 2>/dev/null || true
oc wait --for=delete istiocni/default --timeout=120s 2>/dev/null || true
oc wait --for=delete ztunnel/default --timeout=120s 2>/dev/null || true
ok "Istio components removed"

# ----------------------------------------------------------------------------
# Step 5: Operator subscriptions and CSVs
# ----------------------------------------------------------------------------
info "Step 5: Removing operator subscriptions ..."
safe_delete subscription kiali-ossm -n openshift-operators
safe_delete subscription servicemeshoperator3 -n openshift-operators
safe_delete subscription tempo-product -n openshift-tempo-operator
safe_delete subscription opentelemetry-product -n openshift-opentelemetry-operator
safe_delete subscription cluster-observability-operator -n openshift-cluster-observability-operator

info "Removing ClusterServiceVersions ..."
for ns in openshift-operators openshift-tempo-operator openshift-opentelemetry-operator openshift-cluster-observability-operator; do
  for csv in $(oc get csv -n "$ns" -o name 2>/dev/null | grep -E 'kiali|servicemesh|tempo|opentelemetry|cluster-observability' || true); do
    oc delete "$csv" -n "$ns" --ignore-not-found 2>/dev/null || true
    ok "Deleted ${csv} in ${ns}"
  done
done
ok "Operator subscriptions and CSVs removed"

# ----------------------------------------------------------------------------
# Step 6: Namespaces
# ----------------------------------------------------------------------------
info "Step 6: Removing namespaces ..."
safe_delete_ns perses-dev
safe_delete_ns tempostack
safe_delete_ns istio-system
safe_delete_ns istio-cni
safe_delete_ns ztunnel
safe_delete_ns openshift-tempo-operator
safe_delete_ns openshift-opentelemetry-operator
safe_delete_ns openshift-cluster-observability-operator

# ----------------------------------------------------------------------------
# Step 7: Revert OVN-Kubernetes gateway config (optional)
# ----------------------------------------------------------------------------
info "Step 7: Reverting OVN-Kubernetes local gateway mode ..."
oc patch networks.operator.openshift.io cluster --type=json \
  -p='[{"op":"remove","path":"/spec/defaultNetwork/ovnKubernetesConfig/gatewayConfig/routingViaHost"}]' 2>/dev/null || \
  warn "Could not revert OVN-Kubernetes gateway config (may already be default)"

# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Cleanup complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
warn "Namespace deletions may still be finalizing in the background."
warn "Console plugins were removed — you may need to refresh your browser."
echo ""
