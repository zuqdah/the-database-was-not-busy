#!/usr/bin/env bash
#
# Creates the one thing the drill does not create for itself: a free Azure SQL
# Database to run against. The drill builds and drops its own tables on every
# run.
#
# Entra-only authentication, so no SQL password exists anywhere in this lab.
#
# Needs: az, node.
set -euo pipefail

RESOURCE_GROUP="rg-sqllab-lograte"
SERVER=""
DATABASE="lograte"
LOCATION=""
# Regions are walked rather than assumed. Measured: East US and East US 2 both
# answered RegionDoesNotAllowProvisioning for a new logical server on the same
# day that Central US accepted one. Neither quota nor any published list predicts
# this, exactly as with VM capacity.
CANDIDATE_REGIONS="centralus southcentralus westus2 westus3 canadacentral northeurope"

usage() {
  cat <<'USAGE'
Usage: scripts/bootstrap.sh [--resource-group name] [--server name] [--database name] [--location region]

  --resource-group  Defaults to rg-sqllab-lograte.
  --server          Logical server name. Generated if not given. Must be globally unique.
  --database        Defaults to lograte.
  --location        Pin a region. Without it, candidate regions are tried in order until
                    one accepts a new logical server.

The free offer fixes ONE region per subscription at first creation, so whichever
region succeeds here is the region for every free database in this subscription.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --resource-group) RESOURCE_GROUP="${2:-}"; shift 2 ;;
    --server) SERVER="${2:-}"; shift 2 ;;
    --database) DATABASE="${2:-}"; shift 2 ;;
    --location) LOCATION="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

say() { printf '\n== %s\n' "$1"; }
note() { printf '   %s\n' "$1"; }

# ------------------------------------------------------------------ preflight

say "Checking prerequisites"
for tool in az node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "$tool is not on PATH." >&2; exit 1; }
done
az account show >/dev/null 2>&1 || { echo "Not signed in to az. Run: az login" >&2; exit 1; }

UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv)
OID=$(az ad signed-in-user show --query id -o tsv)
note "signing in as ${UPN}"

if [ -z "$SERVER" ]; then
  SERVER="sqllab-lograte-$(tr -dc 'a-z0-9' </dev/urandom | head -c 8)"
fi

# --------------------------------------------------------------- the server

say "Looking for an existing server"
EXISTING=$(az sql server list -g "$RESOURCE_GROUP" --query "[0].name" -o tsv 2>/dev/null || true)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  SERVER="$EXISTING"
  LOCATION=$(az sql server show -g "$RESOURCE_GROUP" -n "$SERVER" --query location -o tsv)
  note "reusing ${SERVER} in ${LOCATION}"
else
  az group create -n "$RESOURCE_GROUP" -l "${LOCATION:-centralus}" -o none
  REGIONS="${LOCATION:-$CANDIDATE_REGIONS}"
  CREATED=""
  for region in $REGIONS; do
    # A fresh name per attempt. A half-failed create reserves the server name at
    # the ARM level while az sql server list shows nothing, so retrying the same
    # name in another region fails with InvalidResourceLocation and looks like a
    # region problem when it is a name collision.
    attempt="${SERVER}-${region}"
    printf '   %-18s %s ... ' "$region" "$attempt"
    if az sql server create -g "$RESOURCE_GROUP" -n "$attempt" -l "$region" \
        --enable-ad-only-auth --external-admin-principal-type User \
        --external-admin-name "$UPN" --external-admin-sid "$OID" -o none 2>/dev/null; then
      echo "created"
      SERVER="$attempt"
      LOCATION="$region"
      CREATED=yes
      break
    fi
    echo "refused"
  done
  if [ -z "$CREATED" ]; then
    echo "   No candidate region accepted a new logical server. Azure refuses these per-region" >&2
    echo "   and per-day with RegionDoesNotAllowProvisioning; try again later or pass --location." >&2
    exit 1
  fi
fi

# ------------------------------------------------------------- the firewall

say "Allowing this machine through the firewall"
# The client IP comes out of Azure's own error message rather than a third-party
# IP echo service: the server tells you which address it refused.
EXISTING_RULE=$(az sql server firewall-rule list -g "$RESOURCE_GROUP" -s "$SERVER" --query "[?name=='dev-machine'].startIpAddress | [0]" -o tsv 2>/dev/null || true)
if [ -n "$EXISTING_RULE" ] && [ "$EXISTING_RULE" != "None" ]; then
  note "rule already present for ${EXISTING_RULE}"
else
  note "provoking a connection so the server names the client address"
  IP=$(az sql db list -g "$RESOURCE_GROUP" -s "$SERVER" -o none 2>&1 | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)
  if [ -z "$IP" ]; then
    note "could not determine the client address automatically."
    note "Run any query against ${SERVER}.database.windows.net and take the address out of"
    note "the error, then: az sql server firewall-rule create -g ${RESOURCE_GROUP} -s ${SERVER} -n dev-machine --start-ip-address <ip> --end-ip-address <ip>"
  else
    az sql server firewall-rule create -g "$RESOURCE_GROUP" -s "$SERVER" -n dev-machine \
      --start-ip-address "$IP" --end-ip-address "$IP" -o none
    note "allowed ${IP}"
  fi
fi

# ------------------------------------------------------------- the database

say "Creating the free database"
if az sql db show -g "$RESOURCE_GROUP" -s "$SERVER" -n "$DATABASE" -o none 2>/dev/null; then
  note "reusing ${DATABASE}"
else
  # Serverless General Purpose with the free limit applied. AutoPause on
  # exhaustion rather than billing: the alternative is a one-way switch to paid,
  # and nothing about this lab is worth an accidental invoice.
  az sql db create -g "$RESOURCE_GROUP" -s "$SERVER" -n "$DATABASE" \
    --edition GeneralPurpose --compute-model Serverless --family Gen5 --capacity 4 \
    --use-free-limit --free-limit-exhaustion-behavior AutoPause \
    --backup-storage-redundancy Local -o none
  note "created ${DATABASE}"
fi

FREE=$(az sql db show -g "$RESOURCE_GROUP" -s "$SERVER" -n "$DATABASE" --query "{free:useFreeLimit,behaviour:freeLimitExhaustionBehavior,sku:currentSku.name}" -o tsv)
note "free limit / behaviour / sku: ${FREE}"

say "Done"
cat <<EOF

  Server     ${SERVER}.database.windows.net
  Database   ${DATABASE}
  Region     ${LOCATION}

  Run the drill:

    pwsh ./scripts/Invoke-ThrottleDrill.ps1 -Server ${SERVER} -Database ${DATABASE}

  The database auto-pauses after an hour idle. The first connection afterwards
  fails while it resumes; the drill retries with backoff, which is what any
  application against a serverless database needs to do.
EOF
