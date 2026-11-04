#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:?exporta el kubeconfig de nico-hub}"
BUNDLE="${HOME}/.nico/ca-bundle.crt"

n() { SSL_CERT_FILE="$BUNDLE" nicocli "$@"; }

echo "############ NICo scaffolding (provider ncx) ############"
echo "## site";           n site list --output table
echo "## tenants";        n tenant current --output table          || true
echo "## instance-types"; n instance-type list --output table   || true
echo "## ip-blocks";      n ip-block list --output table        || true
echo "## allocations";    n allocation list --output table      || true
echo "## vpc";            n vpc list --output table             || true

echo "############ machines (gRPC admin-cli) ############"
nico-admin-cli \
  --api-url https://nico-api-grpc-nico-system.apps.nico-hub.nvidialaunchpad.internal:443 \
  --client-cert-path ~/.nico/admin-tls.crt \
  --client-key-path  ~/.nico/admin-tls.key \
  --forge-root-ca-path ~/.nico/admin-ca.crt \
  machine show

echo "############ ACM / HyperShift presente? ############"
oc get agentserviceconfig -A 2>/dev/null || echo "NO AgentServiceConfig"
oc -n multicluster-engine get mce -o jsonpath='{.items[0].spec.overrides.components[?(@.name=="hypershift")]}{"\n"}' 2>/dev/null || true
oc api-resources 2>/dev/null | grep -iE "hostedcluster|nodepool|infraenv|^agents" || echo "faltan CRDs de HyperShift/Assisted"

echo "############ RHCOS arm64 reales para 4.22 (osImages) ############"
# requiere el openshift-install de 4.22.9; si no está, dímelo y lo sacamos del mirror
openshift-install coreos print-stream-json 2>/dev/null | jq -r '
  "version: \(.architectures.aarch64.artifacts.metal.release)",
  "iso:     \(.architectures.aarch64.artifacts.metal.formats.iso.disk.location)",
  "rootfs:  \(.architectures.aarch64.artifacts.metal.formats.pxe.rootfs.location)"
' || echo "no hay openshift-install 4.22 en PATH"
