#!/usr/bin/env bash
#
# demo-reset.sh — Resetea los recursos de la demo "2 trays -> HCP + 2 workers"
# en el site gb300-nvl72, CONSERVANDO la plataforma NICo, el site, el tenant ncx
# y el AgentServiceConfig (osImages arm64). Pensado para re-grabar entre tomas.
#
# Qué borra (en orden inverso de dependencias):
#   1. HCP:  HostedCluster + NodePool "gb300" (ns clusters) + InfraEnv/Agents (ns gb300)
#   2. NICo instances      gb300-worker-1 / gb300-worker-2
#   3. VPC                 gb300-flat
#   4. allocation (network) gb300-network   -> ip-block nvl72-network
#   5. allocation (compute) gb300-compute
#   6. instance-type       gb300-nvl72      (quita antes las machine-associations)
#   7. Core: machine force-delete (tray-1/2) -> expected-machine delete -> credential delete-bmc
#
# Qué NO toca: site, tenant, operadores/plataforma NICo, ACM/HyperShift, AgentServiceConfig.
#
# Uso:
#   DRY_RUN=1 ./demo-reset.sh     # imprime lo que haría, no borra nada  (haz esto primero)
#   ./demo-reset.sh               # ejecuta (pide confirmación)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuración (valores estables del lab; los UUID efímeros se descubren solos)
# ---------------------------------------------------------------------------
: "${KUBECONFIG:?exporta KUBECONFIG del cluster nico-hub}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-$HOME/.nico/ca-bundle.crt}"

SITE_ID="9caf9e20-e185-41e4-adb3-ce9f0bba61c9"   # gb300-nvl72 (se conserva)
API_URL="https://nico-api-grpc-nico-system.apps.nico-hub.nvidialaunchpad.internal:443"

# Trays (BMC MAC = clave estable del expected-machine)
BMC_MACS=("18:3d:2d:9b:b3:f2" "18:3d:2d:9b:b4:1c")   # tray-1, tray-2

# Nombres de los recursos de la demo (se recrean en cámara con estos nombres)
INSTANCE_NAMES=("gb300-worker-1" "gb300-worker-2")
VPC_NAME="gb300-flat"
ALLOC_NAMES=("gb300-network" "gb300-compute")   # network primero (depende de ip-block)
IPBLOCK_NAME="nvl72-network"
INSTANCE_TYPE_NAME="gb300-nvl72"

# HCP
HC_NAME="gb300"
HC_NS="clusters"
AGENT_NS="gb300"

DRY_RUN="${DRY_RUN:-0}"

# Wrappers de CLI --------------------------------------------------------------
nc()  { nicocli "$@"; }                                   # REST API (cloud)
cli() { nico-admin-cli --api-url "$API_URL" \
          --client-cert-path "$HOME/.nico/admin-tls.crt" \
          --client-key-path  "$HOME/.nico/admin-tls.key" \
          --forge-root-ca-path "$HOME/.nico/admin-ca.crt" "$@"; }  # Core gRPC (site)

run() {   # ejecuta o imprime según DRY_RUN
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] $*"
  else
    echo "  -> $*"
    "$@" || echo "     (aviso: el comando devolvió error, continúo)"
  fi
}

# Devuelve el .id de un recurso buscado por .name en un 'list --output json'
id_by_name() {  # $1=recurso (vpc|allocation|ip-block|instance|instance-type)  $2=nombre
  nc "$1" list --site-id "$SITE_ID" --output json 2>/dev/null \
    | jq -r --arg n "$2" '.[]? | select(.name==$n) | .id' | head -n1
}

confirm() {
  [[ "$DRY_RUN" == "1" ]] && return 0
  read -r -p "¿Seguro que quieres BORRAR los recursos de la demo en gb300-nvl72? [y/N] " a
  [[ "$a" == "y" || "$a" == "Y" ]] || { echo "Cancelado."; exit 0; }
}

# ---------------------------------------------------------------------------
echo "== demo-reset (site gb300-nvl72) =="
[[ "$DRY_RUN" == "1" ]] && echo "   MODO DRY-RUN: no se borra nada."
confirm

# 1) HCP ---------------------------------------------------------------------
echo "[1/7] HCP (HostedCluster/NodePool + Agents)"
if hcp destroy cluster agent --name "$HC_NAME" --namespace "$HC_NS" 2>/dev/null; then :; else
  run hcp destroy cluster agent --name "$HC_NAME" --namespace "$HC_NS"
fi
run oc delete infraenv "$HC_NAME" -n "$AGENT_NS" --ignore-not-found
run oc delete namespace "$AGENT_NS" --ignore-not-found   # borra Agents/BMH residuales

# 2) Instances ---------------------------------------------------------------
# OJO: 'instance delete' es ASÍNCRONO ("Deletion request was accepted"): el tray
# se desaprovisiona y la instance tarda en desaparecer. Todo lo que sigue (VPC,
# allocation compute, machine-association, instance-type, machine force-delete)
# falla si las instances aún existen -> hay que ESPERAR a que drenen.
echo "[2/7] NICo instances"
for name in "${INSTANCE_NAMES[@]}"; do
  iid="$(id_by_name instance "$name" || true)"
  [[ -n "$iid" ]] && run nc instance delete "$iid" || echo "  (ya no existe: $name)"
done

if [[ "$DRY_RUN" != "1" ]]; then
  echo "  esperando a que las instances drenen (timeout 600s)..."
  deadline=$(( $(date +%s) + 600 ))
  while :; do
    left="$(nc instance list --site-id "$SITE_ID" --output json 2>/dev/null | jq 'length' || echo '?')"
    [[ "$left" == "0" ]] && { echo "  instances borradas."; break; }
    (( $(date +%s) > deadline )) && { echo "  AVISO: timeout, quedan $left instance(s); revisa a mano."; break; }
    echo "    quedan $left instance(s)..."; sleep 10
  done
fi

# 3) VPC ---------------------------------------------------------------------
echo "[3/7] VPC"
vid="$(id_by_name vpc "$VPC_NAME" || true)"
[[ -n "$vid" ]] && run nc vpc delete "$vid" || echo "  (ya no existe: $VPC_NAME)"

# 4) Allocations + ip-block --------------------------------------------------
echo "[4/7] allocations + ip-block"
for name in "${ALLOC_NAMES[@]}"; do
  aid="$(id_by_name allocation "$name" || true)"
  [[ -n "$aid" ]] && run nc allocation delete "$aid" || echo "  (ya no existe: $name)"
done
bid="$(id_by_name ip-block "$IPBLOCK_NAME" || true)"
[[ -n "$bid" ]] && run nc ip-block delete "$bid" || echo "  (ya no existe: $IPBLOCK_NAME)"

# 5) + 6) Instance-type (quitar machine-associations y luego el tipo) --------
echo "[5/7] instance-type machine-associations + instance-type"
itid="$(id_by_name instance-type "$INSTANCE_TYPE_NAME" || true)"
if [[ -n "$itid" ]]; then
  # machine-association get devuelve los machineId asociados a este instance-type
  for mid in $(nc instance-type machine-association get --output json "$itid" 2>/dev/null \
                 | jq -r '.[]?.machineId'); do
    # DELETE /instance/type/{instanceTypeId}/machine/{id}  (routes.go:871-874)
    run nc instance-type machine-association delete "$itid" "$mid"
  done
  run nc instance-type delete "$itid"
else
  echo "  (ya no existe: $INSTANCE_TYPE_NAME)"
fi

# 7) Core: máquinas, expected-machines, credenciales BMC ---------------------
# ORDEN CRÍTICO: la credencial BMC por-MAC NO se borra hasta confirmar que la
# máquina ya no existe. El deprovision de la máquina (FactoryResetBmc) necesita
# esa credencial; si la borras antes, el controlador queda en MissingCredentials
# y la instance se atasca en Terminating. (Bug visto en la primera pasada.)

# machineId por BMC MAC: primero desde expected-machine list; si ya se borró el
# expected-machine en una pasada parcial, cae a machine show (evita huérfanas).
machine_id_for_mac() {
  local mac="$1" mid
  mid="$(nc expected-machine list --output json 2>/dev/null \
          | jq -r --arg m "${mac^^}" '.[]? | select((.bmcMacAddress|ascii_upcase)==$m) | .machineId' 2>/dev/null)"
  if [[ -z "$mid" || "$mid" == "null" ]]; then
    mid="$(cli machine show --output json 2>/dev/null \
            | jq -r --arg m "${mac^^}" '.[]? | select((.bmcMacAddress // ""|ascii_upcase)==$m) | .machineId' 2>/dev/null)"
  fi
  [[ "$mid" == "null" ]] && mid=""
  printf '%s' "$mid"
}

# ¿sigue existiendo esa máquina en Core? (0 = existe, 1 = ya no)
machine_exists() {
  local mid="$1"
  [[ -z "$mid" ]] && return 1
  cli machine show --output json 2>/dev/null \
    | jq -e --arg id "$mid" 'any(.[]?; .machineId==$id)' >/dev/null 2>&1
}

echo "[7/7] máquinas + expected-machines + credenciales BMC"
for mac in "${BMC_MACS[@]}"; do
  mid="$(machine_id_for_mac "$mac")"
  if [[ -n "$mid" ]]; then
    run cli machine force-delete --machine "$mid" --allow-delete-with-instance
  fi
  run cli expected-machine delete "$mac"

  # Solo limpiar la credencial BMC si la máquina YA no existe (evita el deadlock
  # MissingCredentials en el FactoryResetBmc del deprovision). Evita 401 al
  # re-registrar. En NVL72 usamos --bmc-retain-credentials, así que al re-añadir
  # el expected-machine NICo vuelve a crear la credencial.
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "  [dry-run] cli credential delete-bmc --kind=bmc-root --mac-address $mac (si la máquina ya no existe)"
  elif machine_exists "$mid"; then
    echo "  AVISO: la máquina $mid aún existe; NO borro su credencial BMC ($mac)."
    echo "         Espera a que el force-delete complete y bórrala a mano si quieres:"
    echo "           cli credential delete-bmc --kind=bmc-root --mac-address $mac"
  else
    run cli credential delete-bmc --kind=bmc-root --mac-address "$mac"
  fi
done

echo
echo "== Reset completado. =="
echo "Comprueba que queda limpio:"
echo "  nc instance list --output table && nc vpc list --output table"
echo "  nc allocation list --output table && nc ip-block list --output table"
echo "  nc instance-type list --output table"
echo "  cli machine show && cli expected-machine show"
echo
echo "Ahora ya puedes re-grabar desde 'PASO 1 - registrar expected-machine' de notes-nico.txt."
