#!/usr/bin/env bash
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

wait_for_csv() {
  local ns=$1 csv_prefix=$2 timeout=${3:-300}
  info "Waiting up to ${timeout}s for CSV '${csv_prefix}*' in namespace '${ns}' to succeed ..."
  local elapsed=0
  while (( elapsed < timeout )); do
    local phase
    phase=$(oc get csv -n "$ns" -o jsonpath="{.items[?(@.metadata.name >= '${csv_prefix}')].status.phase}" 2>/dev/null || true)
    if [[ "$phase" == *"Succeeded"* ]]; then
      ok "CSV '${csv_prefix}*' succeeded in ${ns}"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  fail "Timed out waiting for CSV '${csv_prefix}*' in ${ns}"
}

wait_for_pods() {
  local ns=$1 timeout=${2:-300}
  info "Waiting up to ${timeout}s for pods in '${ns}' to be ready ..."
  local elapsed=0
  while (( elapsed < timeout )); do
    local not_ready
    not_ready=$(oc get pods -n "$ns" --no-headers 2>/dev/null | grep -cvE 'Running|Completed|Succeeded' || true)
    local total
    total=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if (( total > 0 && not_ready == 0 )); then
      ok "All pods ready in ${ns}"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "Some pods in '${ns}' may not be ready yet"
}

wait_for_daemonset() {
  local ns=$1 name=$2 timeout=${3:-300}
  info "Waiting up to ${timeout}s for DaemonSet '${name}' in '${ns}' ..."
  local elapsed=0
  while (( elapsed < timeout )); do
    local desired ready
    desired=$(oc get daemonset "$name" -n "$ns" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    ready=$(oc get daemonset "$name" -n "$ns" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
    if (( desired > 0 && desired == ready )); then
      ok "DaemonSet '${name}' ready (${ready}/${desired}) in ${ns}"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  warn "DaemonSet '${name}' in '${ns}' may not be fully ready yet"
}

# ============================================================================
echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} Service Mesh 3 Ambient - Installation${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# ----------------------------------------------------------------------------
# Step 1: Operators
# ----------------------------------------------------------------------------
info "Step 1: Installing operators ..."
oc apply -f "${SCRIPT_DIR}/k8s/operators/subscriptions.yml"

wait_for_csv openshift-operators kiali-operator
wait_for_csv openshift-operators servicemeshoperator3
wait_for_csv openshift-tempo-operator tempo-operator
wait_for_csv openshift-opentelemetry-operator opentelemetry-operator
wait_for_csv openshift-cluster-observability-operator cluster-observability-operator
ok "All operators installed"

# ----------------------------------------------------------------------------
# Step 2: Gateway API CRDs (shipped with OpenShift 4.19+)
# ----------------------------------------------------------------------------
info "Step 2: Checking Gateway API CRDs ..."
if oc get crd gateways.gateway.networking.k8s.io &>/dev/null; then
  ok "Gateway API CRDs present"
else
  fail "Gateway API CRDs not found. OpenShift Service Mesh 3.4 requires OpenShift 4.20 or later."
fi

# ----------------------------------------------------------------------------
# Step 3: OVN-Kubernetes local gateway mode
# ----------------------------------------------------------------------------
info "Step 3: Configuring OVN-Kubernetes for local gateway mode ..."
oc patch networks.operator.openshift.io cluster --type=merge -p '{
  "spec": {
    "defaultNetwork": {
      "ovnKubernetesConfig": {
        "gatewayConfig": {
          "routingViaHost": true
        }
      }
    }
  }
}'
ok "OVN-Kubernetes patched"

# ----------------------------------------------------------------------------
# Step 4: Istio, IstioCNI, ZTunnel
# ----------------------------------------------------------------------------
info "Step 4: Installing Istio, IstioCNI, and ZTunnel ..."
oc apply -k "${SCRIPT_DIR}/k8s/istio"

info "Waiting for istiod in istio-system ..."
oc wait --for=condition=Ready -n istio-system istio/default --timeout=300s 2>/dev/null || \
  wait_for_pods istio-system 300

wait_for_daemonset istio-cni istio-cni-node
wait_for_daemonset ztunnel ztunnel
ok "Istio components ready"

# ----------------------------------------------------------------------------
# Step 5: Observability - User workload monitoring
# ----------------------------------------------------------------------------
info "Step 5: Enabling user workload monitoring ..."
if oc -n openshift-monitoring get configmap cluster-monitoring-config &>/dev/null; then
  oc -n openshift-monitoring patch configmap cluster-monitoring-config \
    -p '{"data":{"config.yaml":"enableUserWorkload: true"}}'
else
  oc apply -f - <<'EOF'
kind: ConfigMap
apiVersion: v1
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
fi
ok "User workload monitoring enabled"

info "Waiting for user workload monitoring pods ..."
wait_for_pods openshift-user-workload-monitoring 300

# ----------------------------------------------------------------------------
# Step 6: Observability - Monitors, Perses, Kiali, OSSMConsole
# ----------------------------------------------------------------------------
info "Step 6: Installing observability stack (monitors, Perses, Kiali, OSSMConsole) ..."
oc apply -k "${SCRIPT_DIR}/k8s/observability"
wait_for_pods istio-system 300

info "Configuring Kiali links to the Perses dashboards in the OpenShift console ..."
CONSOLE_URL="https://$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')"
oc patch kiali kiali-user-workload-monitoring -n istio-system --type merge \
  -p "{\"spec\":{\"external_services\":{\"perses\":{\"external_url\":\"${CONSOLE_URL}\"}}}}"
ok "Observability stack installed"

# ----------------------------------------------------------------------------
# Step 7: Distributed tracing - TempoStack
# ----------------------------------------------------------------------------
info "Step 7: Setting up distributed tracing (TempoStack) ..."

oc apply -f "${SCRIPT_DIR}/k8s/tracing/ns.yml"

if oc get crd objectbucketclaims.objectbucket.io &>/dev/null; then
  info "ODF found, creating bucket claim ..."
  oc apply -f "${SCRIPT_DIR}/k8s/tracing/bucketclaim.yml"

  info "Waiting for bucket claim secret 'tempostorage' in tempostack namespace ..."
  elapsed=0
  while (( elapsed < 300 )); do
    if oc get secret tempostorage -n tempostack &>/dev/null; then
      break
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  if ! oc get secret tempostorage -n tempostack &>/dev/null; then
    fail "Timed out waiting for bucket claim secret. Is ODF configured?"
  fi
  ok "Bucket claim secret available"

  export S3_ENDPOINT="http://s3.openshift-storage.svc"
  export AWS_ACCESS_KEY_ID
  AWS_ACCESS_KEY_ID=$(oc get secret tempostorage -n tempostack -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 --decode)
  export AWS_SECRET_ACCESS_KEY
  AWS_SECRET_ACCESS_KEY=$(oc get secret tempostorage -n tempostack -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 --decode)
else
  info "ODF not found, deploying SeaweedFS as S3 storage ..."
  oc apply -f "${SCRIPT_DIR}/k8s/tracing/seaweedfs.yml"
  oc -n seaweedfs wait --for=condition=complete job/create-bucket --timeout=300s || \
    fail "Timed out waiting for the SeaweedFS bucket"
  ok "SeaweedFS bucket available"

  export S3_ENDPOINT="http://seaweedfs.seaweedfs.svc:8333"
  export AWS_ACCESS_KEY_ID="tempostorage"
  export AWS_SECRET_ACCESS_KEY="tempostorage"
fi

info "Creating TempoStack ..."
envsubst < "${SCRIPT_DIR}/k8s/tracing/tempostack.yml" | oc apply -f -

info "Applying OTel collector, network policies, telemetry, and Istio tracing config ..."
oc apply -f "${SCRIPT_DIR}/k8s/tracing/otel-collector.yml"
oc apply -f "${SCRIPT_DIR}/k8s/tracing/networkpolicies.yml"
oc apply -f "${SCRIPT_DIR}/k8s/tracing/telemetry.yml"
oc apply -f "${SCRIPT_DIR}/k8s/tracing/istio-update.yml"
ok "Tracing resources applied"

# ----------------------------------------------------------------------------
# Step 8: Distributed Tracing UI Plugin
# ----------------------------------------------------------------------------
info "Step 8: Installing Distributed Tracing UI Plugin ..."
oc apply -f "${SCRIPT_DIR}/k8s/tracing/uiplugin.yml"
ok "UI Plugin installed"

# ============================================================================
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN} Installation complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
info "Perses dashboards available at: Observe > Dashboards (Perses) in the OpenShift console"
echo ""
info "Kiali URL:"
echo "  https://$(oc get route -n istio-system kiali -o jsonpath='{.spec.host}' 2>/dev/null || echo '<not yet available>')"
echo ""
