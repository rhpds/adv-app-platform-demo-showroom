#!/usr/bin/env bash
set -euo pipefail

#
# Disable the scaffolder-relation-processor plugin's automatic, full-repo-diff
# merge requests, in favor of the scoped propagate-skeleton-diff.sh workflow.
#
# The plugin's built-in PR feature always diffs the *current* skeleton against
# the *current* state of each downstream repo, so any project-specific change
# to a skeleton-tracked file shows up in the MR too — not just what actually
# changed in the template. This script turns that feature off so platform
# engineers can use propagate-skeleton-diff.sh instead, which only proposes
# the lines that changed between two template versions.
#
# It leaves the relation-processor plugin itself (and notifications) enabled,
# since propagate-skeleton-diff.sh still relies on the plugin for the
# scaffoldedFrom catalog relations it queries to find downstream repos.
#
# Because ArgoCD syncs app-config-rhdh from Git, this script also adds
# ignoreDifferences for that ConfigMap so the live toggle is not reverted.
# This is the one remaining out-of-band cluster patch; the plugin itself is
# enabled from Git in ocp-app-platform-demo-developer-hub-config.
#
# Prerequisites:
#   - oc CLI logged in to the target OpenShift cluster
#   - RHDH is running in the 'rhdh' namespace
#   - python3 available locally
#
# Usage:
#   ./disable-automated-lifecycle.sh
#   ./disable-automated-lifecycle.sh --dry-run
#

DRY_RUN=false
RHDH_NAMESPACE="${RHDH_NAMESPACE:-rhdh}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-developer-hub-application}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

echo "==> Checking RHDH namespace..."
if ! oc get namespace "${RHDH_NAMESPACE}" &>/dev/null; then
  echo "ERROR: Namespace '${RHDH_NAMESPACE}' not found. Set RHDH_NAMESPACE if different."
  exit 1
fi

echo "==> Checking current app-config-rhdh ConfigMap..."
CURRENT_APPCONFIG=$(oc get configmap app-config-rhdh -n "${RHDH_NAMESPACE}" -o jsonpath='{.data.app-config-rhdh\.yaml}')

is_pr_creation_enabled() {
  local current="$1"
  echo "${current}" | python3 -c "
import re, sys
content = sys.stdin.read()
sys.exit(0 if re.search(r'pullRequests:\s*\n\s*templateUpdate:\s*\n\s*enabled:\s*true', content) else 1)
"
}

if is_pr_creation_enabled "${CURRENT_APPCONFIG}"; then
  echo "    scaffolder.pullRequests.templateUpdate is enabled, will disable it"
  NEEDS_UPDATE=true
else
  echo "    scaffolder.pullRequests.templateUpdate is already disabled (or not configured)"
  NEEDS_UPDATE=false
fi

if [[ "${NEEDS_UPDATE}" == "false" ]]; then
  echo ""
  echo "==> Nothing to do. The plugin's automatic full-diff MRs are already disabled."
  echo "    Use ./propagate-skeleton-diff.sh to open scoped MRs instead."
  exit 0
fi

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "==> DRY RUN: Would make the following changes:"
  echo "    - Add ArgoCD ignoreDifferences for ConfigMap app-config-rhdh (if managed by ArgoCD)"
  echo "    - Set scaffolder.pullRequests.templateUpdate.enabled to false in app-config-rhdh"
  echo "    - Restart RHDH pod"
  echo ""
  echo "    To apply, run without --dry-run"
  exit 0
fi

echo "==> Checking ArgoCD management..."
if oc get application "${ARGOCD_APP_NAME}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
  echo "    RHDH is managed by ArgoCD, adding ignoreDifferences for app-config-rhdh..."
  oc patch application "${ARGOCD_APP_NAME}" -n "${ARGOCD_NAMESPACE}" --type=merge -p '{
    "spec": {
      "ignoreDifferences": [
        {
          "group": "",
          "kind": "ConfigMap",
          "name": "app-config-rhdh",
          "namespace": "'"${RHDH_NAMESPACE}"'",
          "jsonPointers": ["/data"]
        }
      ]
    }
  }'
  echo "    Done"
else
  echo "    No ArgoCD application found, skipping"
fi

echo "==> Updating app-config-rhdh ConfigMap..."
TMPFILE=$(mktemp)
trap 'rm -f "${TMPFILE}"' EXIT
echo "${CURRENT_APPCONFIG}" > "${TMPFILE}"

python3 -c "
import re
content = open('${TMPFILE}').read()
content = re.sub(
    r'(pullRequests:\s*\n\s*templateUpdate:\s*\n\s*enabled:)\s*true',
    r'\1 false',
    content,
)
open('${TMPFILE}', 'w').write(content)
"

oc create configmap app-config-rhdh -n "${RHDH_NAMESPACE}" \
  --from-file="app-config-rhdh.yaml=${TMPFILE}" \
  --dry-run=client -o yaml | oc apply -f -

echo "    Confirming the write actually stuck..."
APPLIED_APPCONFIG=$(oc get configmap app-config-rhdh -n "${RHDH_NAMESPACE}" -o jsonpath='{.data.app-config-rhdh\.yaml}')
if is_pr_creation_enabled "${APPLIED_APPCONFIG}"; then
  echo ""
  echo "ERROR: Applied the app-config-rhdh update, but re-reading it back shows"
  echo "       pullRequests.templateUpdate.enabled is still true. Something rejected"
  echo "       or reverted the change — check for an operator or GitOps controller"
  echo "       managing this ConfigMap without the ignoreDifferences patch."
  exit 1
fi
echo "    Done"

echo "==> Restarting RHDH pod..."
POD_NAME=$(oc get pods -n "${RHDH_NAMESPACE}" -o name | grep backstage-developer-hub | grep -v psql | head -1)
if [[ -n "${POD_NAME}" ]]; then
  oc delete "${POD_NAME}" -n "${RHDH_NAMESPACE}"
  echo "    Waiting for new pod to be ready..."
  oc rollout status deploy/backstage-developer-hub -n "${RHDH_NAMESPACE}" --timeout=300s
  echo "    Done"
else
  echo "    WARNING: Could not find RHDH pod to restart — restart manually to apply the config change"
fi

echo ""
echo "==> Automatic full-diff merge requests are disabled."
echo ""
echo "    The relation-processor plugin and notifications are left as-is: apps still"
echo "    get scaffoldedFrom relations, and owners can still be notified of an update."
echo "    Only the plugin's own MR creation is turned off."
echo ""
echo "    Use ./propagate-skeleton-diff.sh to open scoped, review-friendly MRs"
echo "    containing only what actually changed between two template versions."
echo ""
echo "    To re-enable automatic MRs later, remove the ArgoCD ignoreDifferences entry"
echo "    for app-config-rhdh and let Git sync restore templateUpdate.enabled: true."
