# Workshop environment for the Web Terminal. Source it, don't run it:
#   source scripts/workshop-env.sh
# Source it again after a terminal restart, the downloaded tools and variables are gone then.

_workshop_env() {
  local cyan='\033[1;36m' green='\033[1;32m' yellow='\033[1;33m' nc='\033[0m'

  WORKSHOP_USER=$(oc whoami) || { echo -e "${yellow}[WARN]${nc}  Not logged in to OpenShift"; return 1; }
  export WORKSHOP_USER
  export APPS_NS="${WORKSHOP_USER}-apps" SIDECAR_NS="${WORKSHOP_USER}-sidecar" TERMINAL_NS="${WORKSHOP_USER}-terminal"

  # KEYCLOAK_HOST, ISTIO_VERSION, TOOLS_URL, KIALI_URL, CONSOLE_URL, written by setup-users.sh
  local info key value
  info=$(oc get configmap workshop-info -n "$TERMINAL_NS" \
    -o go-template='{{range $k, $v := .data}}{{$k}}={{$v}}{{"\n"}}{{end}}') || {
    echo -e "${yellow}[WARN]${nc}  ConfigMap workshop-info not found in ${TERMINAL_NS}. Has your admin run setup-users.sh?"
    return 1
  }
  while IFS='=' read -r key value; do
    [[ -n "$key" ]] && export "${key}=${value}"
  done <<<"$info"

  # The Web Terminal has /wto/bin/downloaded on the PATH. Elsewhere, fall back to ~/.local/bin
  local bin=/wto/bin/downloaded
  if [[ ! -w "$bin" ]]; then
    bin="${HOME}/.local/bin"
    mkdir -p "$bin"
    [[ ":${PATH}:" == *":${bin}:"* ]] || export PATH="${bin}:${PATH}"
  fi

  local istioctl_version
  istioctl_version=$(istioctl version --remote=false --short 2>/dev/null)  # "client version: 1.31.0"
  if [[ "${istioctl_version##* }" != "$ISTIO_VERSION" ]]; then
    echo -e "${cyan}[INFO]${nc}  Installing istioctl ${ISTIO_VERSION} ..."
    curl -fsSL "${TOOLS_URL}/istioctl.tar.gz" | tar -xz -C "$bin" istioctl || {
      echo -e "${yellow}[WARN]${nc}  Download of istioctl from ${TOOLS_URL} failed"
    }
  fi
  if ! command -v envsubst &>/dev/null; then
    echo -e "${cyan}[INFO]${nc}  Installing envsubst ..."
    curl -fsSL -o "${bin}/envsubst" "${TOOLS_URL}/envsubst" && chmod +x "${bin}/envsubst" || {
      echo -e "${yellow}[WARN]${nc}  Download of envsubst from ${TOOLS_URL} failed"
    }
  fi
  hash -r

  oc project "$APPS_NS" >/dev/null || return 1

  echo -e "${green}[OK]${nc}    Workshop environment for ${WORKSHOP_USER}"
  echo "        APPS_NS=${APPS_NS}  SIDECAR_NS=${SIDECAR_NS}  TERMINAL_NS=${TERMINAL_NS}"
  echo "        Current project: ${APPS_NS}"
}

_workshop_env
unset -f _workshop_env
