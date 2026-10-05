#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Generates a Keycloak JWT for a NICo tenant service account.
# Usage:
#   keycloak_token_gen_tenant.sh <tenant-org>
#   keycloak_token_gen_tenant.sh tenant2
#
# The client name is derived as <tenant-org>-service (e.g. tenant2-service).
# Designed to be used as nicocli --token-command:
#   nicocli --org tenant2 --token-command "utils/keycloak_token_gen_tenant.sh tenant2" vpc list

set -euo pipefail

TENANT_ORG="${1:?Usage: $0 <tenant-org>}"
CLIENT_ID="${TENANT_ORG}-service"

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster \
  -o jsonpath='{.spec.domain}' 2>/dev/null)

if [[ -z "$CLUSTER_DOMAIN" ]]; then
  echo "Error: could not resolve cluster ingress domain. Is KUBECONFIG set and oc logged in?" >&2
  exit 1
fi

KC_URL="https://keycloak-rhbk-operator.${CLUSTER_DOMAIN}"

_ADMIN_USER=$(oc get secret keycloak-admin-secret -n rhbk-operator \
  -o jsonpath='{.data.username}' | base64 -d)
_ADMIN_PASS=$(oc get secret keycloak-admin-secret -n rhbk-operator \
  -o jsonpath='{.data.password}' | base64 -d)

_ADMIN_TOKEN=$(curl -sk -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=admin-cli" \
  --data-urlencode "username=$_ADMIN_USER" \
  --data-urlencode "password=$_ADMIN_PASS" \
  | jq -r .access_token)

_CLIENT_UUID=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')

if [[ -z "$_CLIENT_UUID" || "$_CLIENT_UUID" == "null" ]]; then
  echo "Error: client '${CLIENT_ID}' not found in Keycloak realm nico" >&2
  exit 1
fi

_CLIENT_SECRET=$(curl -sk -H "Authorization: Bearer $_ADMIN_TOKEN" \
  "$KC_URL/admin/realms/nico/clients/$_CLIENT_UUID" | jq -r .secret)

TOKEN=$(curl -sk -X POST "$KC_URL/realms/nico/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=$_CLIENT_SECRET" \
  | jq -r .access_token)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "Error: failed to acquire token for ${CLIENT_ID}" >&2
  exit 1
fi

echo "$TOKEN"
