#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 Red Hat, Inc. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Creates a new NICo tenant end-to-end:
#   1. Keycloak: realm role, client, service account attributes, protocol mappers
#   2. NICo REST API: tenant-account create (as Provider) + accept (as Tenant)
#
# Usage:
#   ./create-tenant.sh <tenant-org-name>
#   ./create-tenant.sh tenant2
#
# Prerequisites:
#   - KUBECONFIG set to the hub cluster
#   - jq, curl, base64 available
#   - Access to Keycloak admin API and NICo REST API

set -euo pipefail

TENANT_ORG="${1:?Usage: $0 <tenant-org-name>}"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
KC_REALM="nico"
KC_NAMESPACE="rhbk-operator"
NICO_REST_NAMESPACE="nico-rest"

# Derive URLs from cluster
CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
KC_URL="https://keycloak-${KC_NAMESPACE}.${CLUSTER_DOMAIN}"
API_URL="https://nico-rest-api-${NICO_REST_NAMESPACE}.${CLUSTER_DOMAIN}"

# Provider org (the existing ncx org that owns the infrastructure)
PROVIDER_ORG="ncx"

echo "=== NICo Tenant Creation ==="
echo "Tenant org:    ${TENANT_ORG}"
echo "Keycloak:      ${KC_URL}"
echo "NICo REST API: ${API_URL}"
echo ""

# ---------------------------------------------------------------------------
# Step 0: Keycloak admin token
# ---------------------------------------------------------------------------
echo "[0/6] Obtaining Keycloak admin token..."
_ADMIN_USER=$(oc get secret keycloak-admin-secret -n "${KC_NAMESPACE}" \
  -o jsonpath='{.data.username}' | base64 -d)
_ADMIN_PASS=$(oc get secret keycloak-admin-secret -n "${KC_NAMESPACE}" \
  -o jsonpath='{.data.password}' | base64 -d)
ADMIN_TOKEN=$(curl -sk -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli \
  -d "username=${_ADMIN_USER}" -d "password=${_ADMIN_PASS}" | jq -r .access_token)

if [[ -z "${ADMIN_TOKEN}" || "${ADMIN_TOKEN}" == "null" ]]; then
  echo "ERROR: Failed to obtain Keycloak admin token" >&2
  exit 1
fi
echo "  OK"

# ---------------------------------------------------------------------------
# Step 1: Create realm role
# ---------------------------------------------------------------------------
ROLE_NAME="${TENANT_ORG}:NICO_TENANT_ADMIN"
echo "[1/6] Creating realm role '${ROLE_NAME}'..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KC_URL}/admin/realms/${KC_REALM}/roles" \
  -d "{\"name\": \"${ROLE_NAME}\"}")

case "${HTTP_CODE}" in
  201) echo "  Created" ;;
  409) echo "  Already exists (OK)" ;;
  *)   echo "  ERROR: HTTP ${HTTP_CODE}" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Step 2: Create Keycloak client
# ---------------------------------------------------------------------------
CLIENT_ID="${TENANT_ORG}-service"
echo "[2/6] Creating Keycloak client '${CLIENT_ID}'..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients" \
  -d "{
    \"clientId\": \"${CLIENT_ID}\",
    \"name\": \"NICo ${TENANT_ORG} Service Account\",
    \"enabled\": true,
    \"clientAuthenticatorType\": \"client-secret\",
    \"serviceAccountsEnabled\": true,
    \"standardFlowEnabled\": false,
    \"directAccessGrantsEnabled\": false,
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"bearerOnly\": false
  }")

case "${HTTP_CODE}" in
  201) echo "  Created" ;;
  409) echo "  Already exists (OK)" ;;
  *)   echo "  ERROR: HTTP ${HTTP_CODE}" >&2; exit 1 ;;
esac

# Get client UUID
CLIENT_UUID=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients?clientId=${CLIENT_ID}" | jq -r '.[0].id')
echo "  Client UUID: ${CLIENT_UUID}"

# ---------------------------------------------------------------------------
# Step 3: Assign realm role to service account
# ---------------------------------------------------------------------------
echo "[3/6] Assigning role '${ROLE_NAME}' to service account..."
SA_USER_ID=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}/service-account-user" | jq -r '.id')

ROLE_ID=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KC_URL}/admin/realms/${KC_REALM}/roles/${ROLE_NAME}" | jq -r '.id')

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KC_URL}/admin/realms/${KC_REALM}/users/${SA_USER_ID}/role-mappings/realm" \
  -d "[{\"id\": \"${ROLE_ID}\", \"name\": \"${ROLE_NAME}\"}]")

case "${HTTP_CODE}" in
  204) echo "  Assigned" ;;
  409) echo "  Already assigned (OK)" ;;
  *)   echo "  WARNING: HTTP ${HTTP_CODE} (may already be assigned)" ;;
esac

# ---------------------------------------------------------------------------
# Step 4: Set oidc_id attribute on service account user
# ---------------------------------------------------------------------------
OIDC_ID="${CLIENT_ID}-oidc-001"
echo "[4/6] Setting oidc_id='${OIDC_ID}' on service account user..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X PUT \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KC_URL}/admin/realms/${KC_REALM}/users/${SA_USER_ID}" \
  -d "{\"attributes\": {\"oidc_id\": [\"${OIDC_ID}\"]}}")

if [[ "${HTTP_CODE}" == "204" ]]; then
  echo "  Set"
else
  echo "  ERROR: HTTP ${HTTP_CODE}" >&2; exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: Create protocol mappers (oidc_id + Client ID)
# ---------------------------------------------------------------------------
echo "[5/6] Creating protocol mappers..."

# oidc_id mapper
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
  -d '{
    "name": "oidc_id",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usermodel-attribute-mapper",
    "consentRequired": false,
    "config": {
      "introspection.token.claim": "true",
      "userinfo.token.claim": "true",
      "user.attribute": "oidc_id",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "oidc_id",
      "jsonType.label": "String"
    }
  }')
case "${HTTP_CODE}" in
  201) echo "  oidc_id mapper: Created" ;;
  409) echo "  oidc_id mapper: Already exists (OK)" ;;
  *)   echo "  oidc_id mapper: ERROR HTTP ${HTTP_CODE}" >&2; exit 1 ;;
esac

# Client ID mapper
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  -H "Content-Type: application/json" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}/protocol-mappers/models" \
  -d '{
    "name": "Client ID",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-usersessionmodel-note-mapper",
    "consentRequired": false,
    "config": {
      "user.session.note": "clientId",
      "introspection.token.claim": "true",
      "userinfo.token.claim": "true",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "client_id",
      "jsonType.label": "String"
    }
  }')
case "${HTTP_CODE}" in
  201) echo "  Client ID mapper: Created" ;;
  409) echo "  Client ID mapper: Already exists (OK)" ;;
  *)   echo "  Client ID mapper: ERROR HTTP ${HTTP_CODE}" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Step 6: NICo REST API — create + accept tenant account
# ---------------------------------------------------------------------------
echo "[6/6] Creating and accepting NICo tenant account..."

# Get Provider token (ncx)
_NCX_UUID=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients?clientId=ncx-service" | jq -r '.[0].id')
_NCX_SECRET=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients/${_NCX_UUID}" | jq -r '.secret')
PROVIDER_TOKEN=$(curl -sk -X POST "${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=ncx-service" \
  --data-urlencode "client_secret=${_NCX_SECRET}" \
  | jq -r .access_token)

# Create tenant-account (as Provider)
ACCOUNT_RESPONSE=$(curl -sk -X POST -H "Authorization: Bearer ${PROVIDER_TOKEN}" \
  -H "Content-Type: application/json" \
  "${API_URL}/v2/org/${PROVIDER_ORG}/nico/tenant/account" \
  -d "{\"tenantOrg\": \"${TENANT_ORG}\"}" \
  -w "\n%{http_code}")

ACCOUNT_HTTP=$(echo "${ACCOUNT_RESPONSE}" | tail -1)
ACCOUNT_BODY=$(echo "${ACCOUNT_RESPONSE}" | sed '$d')

case "${ACCOUNT_HTTP}" in
  201)
    ACCOUNT_ID=$(echo "${ACCOUNT_BODY}" | jq -r '.id')
    echo "  Tenant account created: ${ACCOUNT_ID}"
    ;;
  409)
    echo "  Tenant account already exists, looking up..."
    ACCOUNT_ID=$(curl -sk -H "Authorization: Bearer ${PROVIDER_TOKEN}" \
      "${API_URL}/v2/org/${PROVIDER_ORG}/nico/tenant/account" \
      | jq -r ".items[] | select(.tenantOrg==\"${TENANT_ORG}\") | .id")
    echo "  Found: ${ACCOUNT_ID}"
    ;;
  *)
    echo "  ERROR creating tenant account: HTTP ${ACCOUNT_HTTP}" >&2
    echo "  ${ACCOUNT_BODY}" >&2
    exit 1
    ;;
esac

# Get Tenant token
CLIENT_SECRET=$(curl -sk -H "Authorization: Bearer ${ADMIN_TOKEN}" \
  "${KC_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}" | jq -r '.secret')
TENANT_TOKEN=$(curl -sk -X POST "${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${CLIENT_ID}" \
  --data-urlencode "client_secret=${CLIENT_SECRET}" \
  | jq -r .access_token)

# Auto-create tenant entity
curl -sk -H "Authorization: Bearer ${TENANT_TOKEN}" \
  "${API_URL}/v2/org/${TENANT_ORG}/nico/tenant/current" > /dev/null 2>&1

# Accept tenant-account (as Tenant)
ACCEPT_RESPONSE=$(curl -sk -X PATCH -H "Authorization: Bearer ${TENANT_TOKEN}" \
  -H "Content-Type: application/json" \
  "${API_URL}/v2/org/${TENANT_ORG}/nico/tenant/account/${ACCOUNT_ID}" \
  -d '{}' -w "\n%{http_code}")

ACCEPT_HTTP=$(echo "${ACCEPT_RESPONSE}" | tail -1)
ACCEPT_BODY=$(echo "${ACCEPT_RESPONSE}" | sed '$d')
FINAL_STATUS=$(echo "${ACCEPT_BODY}" | jq -r '.status // "unknown"')

if [[ "${ACCEPT_HTTP}" == "200" && "${FINAL_STATUS}" == "Ready" ]]; then
  echo "  Tenant account accepted: Ready"
else
  echo "  WARNING: HTTP ${ACCEPT_HTTP}, status: ${FINAL_STATUS}" >&2
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TENANT_ID=$(echo "${ACCEPT_BODY}" | jq -r '.tenantId // "unknown"')

echo ""
echo "=== Tenant '${TENANT_ORG}' Ready ==="
echo "Keycloak client:    ${CLIENT_ID}"
echo "Client secret:      ${CLIENT_SECRET}"
echo "Tenant ID:          ${TENANT_ID}"
echo "Tenant Account ID:  ${ACCOUNT_ID}"
echo ""
echo "Get a token:"
echo "  curl -sk -X POST '${KC_URL}/realms/${KC_REALM}/protocol/openid-connect/token' \\"
echo "    --data-urlencode 'grant_type=client_credentials' \\"
echo "    --data-urlencode 'client_id=${CLIENT_ID}' \\"
echo "    --data-urlencode 'client_secret=${CLIENT_SECRET}' | jq -r .access_token"
echo ""
echo "Next steps (as Provider with ncx token):"
echo "  1. Create compute allocation:  nicocli allocation create --tenant-org ${TENANT_ORG} ..."
echo "  2. Create network allocation:  nicocli allocation create --tenant-org ${TENANT_ORG} ..."
echo "  3. Create VPC (as Tenant):     nicocli vpc create ..."
echo "  4. Create Instance (as Tenant): nicocli instance create ..."
