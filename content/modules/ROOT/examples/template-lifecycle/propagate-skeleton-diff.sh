#!/usr/bin/env bash
set -euo pipefail

#
# Propagate a scoped skeleton diff to every downstream repo created from the
# quarkus-app template, as an alternative to the scaffolder-relation-processor
# plugin's full-repo-diff merge requests (see disable-automated-lifecycle.sh).
#
# The plugin always compares the *entire current* skeleton against the
# *entire current* state of each downstream repo, so a project's own
# unrelated changes to skeleton-tracked files show up in the MR too. This
# script instead diffs the last two commits in GitLab's rhdh/rhdh-templates
# (via GitLab's compare API, scoped to templates/<template>/skeleton) and
# tries to apply exactly that patch to each downstream repo. A repo where
# the patch doesn't apply cleanly is skipped and reported instead of being
# silently overwritten.
#
# GitLab's already-pushed history is the source of truth. Cluster bootstrap
# imports this repo and commits Jinja substitutions; a later platform-engineer
# bump of the skeleton is the second commit the script diffs against.
#
# Prerequisites:
#   - oc CLI logged in to the target OpenShift cluster
#   - git, python3, curl available locally
#   - At least two commits already in rhdh/rhdh-templates for this template
#     (GitLab init plus a later skeleton/version bump)
#   - RHDH catalog reachable; RHDH_TOKEN is taken from backend-secret by default
#
# Usage:
#   ./propagate-skeleton-diff.sh                    # diff the last two pushed commits, open MRs
#   ./propagate-skeleton-diff.sh --dry-run           # show diff + matching repos, no MRs
#   ./propagate-skeleton-diff.sh --from-sha <sha> --to-sha <sha>
#

TEMPLATE_NAME="${TEMPLATE_NAME:-quarkus-app}"
RHDH_NAMESPACE="${RHDH_NAMESPACE:-rhdh}"
DRY_RUN=false
FROM_SHA=""
TO_SHA=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --from-sha) FROM_SHA="$2"; shift 2 ;;
    --to-sha) TO_SHA="$2"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

echo "==> Detecting cluster configuration..."
CLUSTER_SUBDOMAIN="${CLUSTER_SUBDOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
GITLAB_HOST="${GITLAB_HOST:-gitlab-gitlab.${CLUSTER_SUBDOMAIN}}"
GITLAB_TOKEN="${GITLAB_TOKEN:-$(oc get secret root-user-personal-token -n gitlab -o jsonpath='{.data.token}' | base64 -d)}"
RHDH_HOST="${RHDH_HOST:-backstage-developer-hub-rhdh.${CLUSTER_SUBDOMAIN}}"
RHDH_TOKEN="${RHDH_TOKEN:-}"

echo "    GitLab host : ${GITLAB_HOST}"
echo "    RHDH host   : ${RHDH_HOST}"

if [[ -z "${RHDH_TOKEN}" ]]; then
  echo "==> RHDH_TOKEN not set — using backend-secret (api-clients externalAccess)..."
  RHDH_TOKEN=$(oc get secret backend-secret -n "${RHDH_NAMESPACE}" -o jsonpath='{.data.BACKEND_SECRET}' 2>/dev/null | base64 -d || echo "")
  if [[ -n "${RHDH_TOKEN}" ]]; then
    echo "    Using BACKEND_SECRET from backend-secret in ${RHDH_NAMESPACE}"
  else
    echo "==> backend-secret not found — trying guest auth for a short-lived catalog token..."
    GUEST_RAW=$(curl -sk -X POST "https://${RHDH_HOST}/api/auth/guest/refresh" -w "\n%{http_code}" 2>/dev/null || true)
    GUEST_HTTP_CODE=$(echo "${GUEST_RAW}" | tail -1)
    GUEST_BODY=$(echo "${GUEST_RAW}" | sed '$d')
    if [[ "${GUEST_HTTP_CODE}" == "200" ]]; then
      RHDH_TOKEN=$(echo "${GUEST_BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('backstageIdentity',{}).get('token',''))" 2>/dev/null || echo "")
    fi
    if [[ -n "${RHDH_TOKEN}" ]]; then
      echo "    Obtained a guest token (guest auth provider is enabled on this cluster)"
    else
      echo "    Guest auth isn't available here (HTTP ${GUEST_HTTP_CODE}) — proceeding without a"
      echo "    token; the catalog call below will fail if this cluster enforces backend auth."
      echo "    Set RHDH_TOKEN to a valid bearer token to fix that."
    fi
  fi
fi

gitlab_api() {
  local path="$1"
  shift
  curl -sk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4${path}" "$@"
}

rhdh_api() {
  local path="$1"
  shift
  if [[ -n "${RHDH_TOKEN}" ]]; then
    curl -sk -H "Authorization: Bearer ${RHDH_TOKEN}" "https://${RHDH_HOST}${path}" "$@"
  else
    curl -sk "https://${RHDH_HOST}${path}" "$@"
  fi
}

echo "==> Looking up rhdh-templates project ID..."
RHDH_TEMPLATES_ID=$(gitlab_api "/projects?search=rhdh-templates" \
  | python3 -c "import sys,json; projects=[p for p in json.load(sys.stdin) if p['path_with_namespace']=='rhdh/rhdh-templates']; print(projects[0]['id'] if projects else '')")

if [[ -z "${RHDH_TEMPLATES_ID}" ]]; then
  echo "ERROR: Could not find rhdh/rhdh-templates project in GitLab."
  exit 1
fi

echo "==> Finding the last two pushed commits for templates/${TEMPLATE_NAME}..."
if [[ -z "${TO_SHA}" || -z "${FROM_SHA}" ]]; then
  COMMITS_JSON=$(gitlab_api "/projects/${RHDH_TEMPLATES_ID}/repository/commits?path=templates%2F${TEMPLATE_NAME}&ref_name=main&per_page=5")
  if [[ -z "${TO_SHA}" ]]; then
    TO_SHA=$(echo "${COMMITS_JSON}" | python3 -c "import sys,json; c=json.load(sys.stdin); print(c[0]['id'] if c else '')")
  fi
  if [[ -z "${FROM_SHA}" ]]; then
    FROM_SHA=$(echo "${COMMITS_JSON}" | python3 -c "import sys,json; c=json.load(sys.stdin); print(c[1]['id'] if len(c) > 1 else '')")
  fi
fi

if [[ -z "${TO_SHA}" ]]; then
  echo "ERROR: No commits found touching templates/${TEMPLATE_NAME} in rhdh/rhdh-templates."
  echo "       Confirm GitLab init imported this repo and the template path exists."
  exit 1
fi
if [[ -z "${FROM_SHA}" ]]; then
  echo "ERROR: Only one commit found touching templates/${TEMPLATE_NAME} — nothing to diff yet."
  echo "       Bump the skeleton and template-version in GitLab rhdh/rhdh-templates, then retry."
  exit 1
fi

echo "    Diffing ${FROM_SHA:0:8} -> ${TO_SHA:0:8}"

echo "==> Reading template-version at the target commit..."
TEMPLATE_YAML_AT_TO=$(gitlab_api "/projects/${RHDH_TEMPLATES_ID}/repository/files/templates%2F${TEMPLATE_NAME}%2Ftemplate.yaml/raw?ref=${TO_SHA}")
VERSION_LABEL=$(echo "${TEMPLATE_YAML_AT_TO}" | python3 -c "
import re, sys
content = sys.stdin.read()
m = re.search(r'backstage\.io/template-version:\s*[\"\']?([0-9][0-9A-Za-z.-]*)[\"\']?', content)
print(m.group(1) if m else 'unknown')
")

SKELETON_PREFIX="templates/${TEMPLATE_NAME}/skeleton/"
DIFF_FILE=$(mktemp)
trap 'rm -f "${DIFF_FILE}"' EXIT

echo "==> Fetching scoped diff from GitLab compare API..."
gitlab_api "/projects/${RHDH_TEMPLATES_ID}/repository/compare?from=${FROM_SHA}&to=${TO_SHA}" | python3 -c "
import sys, json

data = json.load(sys.stdin)
prefix = '${SKELETON_PREFIX}'
parts = []
changed_files = []

for d in data.get('diffs', []):
    new_path = d.get('new_path', '')
    old_path = d.get('old_path', '')
    if not (new_path.startswith(prefix) or old_path.startswith(prefix)):
        continue

    rel_new = new_path[len(prefix):] if new_path.startswith(prefix) else new_path
    rel_old = old_path[len(prefix):] if old_path.startswith(prefix) else old_path
    body = d.get('diff', '')

    header = [f'diff --git a/{rel_old} b/{rel_new}']
    if d.get('new_file'):
        header += ['new file mode 100644', '--- /dev/null', f'+++ b/{rel_new}']
        changed_files.append(f'created  {rel_new}')
    elif d.get('deleted_file'):
        header += ['deleted file mode 100644', f'--- a/{rel_old}', '+++ /dev/null']
        changed_files.append(f'deleted  {rel_old}')
    elif d.get('renamed_file'):
        header += [f'rename from {rel_old}', f'rename to {rel_new}', f'--- a/{rel_old}', f'+++ b/{rel_new}']
        changed_files.append(f'renamed  {rel_old} -> {rel_new}')
    else:
        header += [f'--- a/{rel_old}', f'+++ b/{rel_new}']
        changed_files.append(f'modified {rel_new}')

    parts.append('\n'.join(header) + '\n' + body)

with open('${DIFF_FILE}', 'w') as f:
    f.write('\n'.join(parts))
    if parts:
        f.write('\n')

for line in changed_files:
    print(line, file=sys.stderr)
" 2>"${DIFF_FILE}.stat"

if [[ ! -s "${DIFF_FILE}" ]]; then
  echo ""
  echo "==> No skeleton changes between ${FROM_SHA:0:8} and ${TO_SHA:0:8}. Nothing to propagate."
  rm -f "${DIFF_FILE}.stat"
  exit 0
fi

echo ""
echo "==> Skeleton changes to propagate:"
sed 's/^/    /' "${DIFF_FILE}.stat"
rm -f "${DIFF_FILE}.stat"
echo ""

echo "==> Finding downstream repos scaffolded from template:default/${TEMPLATE_NAME}..."
CATALOG_RAW=$(rhdh_api "/api/catalog/entities?filter=relations.scaffoldedFrom=template:default/${TEMPLATE_NAME}" -w "\n%{http_code}")
CATALOG_HTTP_CODE=$(echo "${CATALOG_RAW}" | tail -1)
CATALOG_RESPONSE=$(echo "${CATALOG_RAW}" | sed '$d')

if [[ "${CATALOG_HTTP_CODE}" != "200" ]]; then
  echo "ERROR: RHDH catalog API returned HTTP ${CATALOG_HTTP_CODE}:"
  echo "${CATALOG_RESPONSE}" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' || echo "    ${CATALOG_RESPONSE}"
  echo ""
  echo "    A non-200 here (401/403 in particular) almost always means the catalog API"
  echo "    requires authentication on this cluster. Set RHDH_TOKEN to a valid bearer"
  echo "    token and retry — e.g. a static token configured under"
  echo "    backend.auth.externalAccess in app-config-rhdh, or a signed-in user's token"
  echo "    (copy the Authorization header RHDH's own frontend sends, from your browser's"
  echo "    network tab, for a quick manual test)."
  exit 1
fi

REPOS=$(echo "${CATALOG_RESPONSE}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
entities = data.get('items', data) if isinstance(data, dict) else data
if not isinstance(entities, list):
    entities = []
for e in entities:
    if not isinstance(e, dict):
        continue
    ann = e.get('metadata', {}).get('annotations', {})
    loc = ann.get('backstage.io/source-location') or ann.get('backstage.io/managed-by-location', '')
    if loc.startswith('url:'):
        loc = loc[len('url:'):]
    loc = loc.split('/-/blob/')[0].rstrip('/')
    if loc:
        print(f\"{e['metadata']['name']}|{loc}\")
" || echo "")

if [[ -z "${REPOS}" ]]; then
  echo "    No entities found. Check that:"
  echo "    - apps have actually been scaffolded from this template"
  echo "    - the relation-processor plugin is enabled (it populates scaffoldedFrom)"
  echo "    - the entity actually has a scaffoldedFrom relation (not just the annotation) —"
  echo "      relations are only populated after the catalog processor has run once"
  exit 0
fi

REPO_COUNT=$(echo "${REPOS}" | grep -c .)
echo "    Found ${REPO_COUNT} downstream repo(s)"
echo ""

BRANCH="template-upgrade-v${VERSION_LABEL}"

while IFS='|' read -r COMPONENT_NAME REPO_URL; do
  [[ -z "${REPO_URL}" ]] && continue
  echo "==> ${COMPONENT_NAME} (${REPO_URL})"

  REPO_PATH=$(echo "${REPO_URL}" | sed -E 's#^https?://[^/]+/##')

  if [[ "${DRY_RUN}" == "true" ]]; then
    WORKDIR=$(mktemp -d)
    if git clone --quiet --depth 50 "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${REPO_PATH}.git" "${WORKDIR}" 2>/dev/null; then
      if (cd "${WORKDIR}" && git apply --check "${DIFF_FILE}") 2>/dev/null; then
        echo "    DRY RUN: patch applies cleanly — would open an MR on branch ${BRANCH}"
      else
        echo "    DRY RUN: patch does NOT apply cleanly — would be skipped and reported"
      fi
    else
      echo "    DRY RUN: could not clone repo to check — would be skipped and reported"
    fi
    rm -rf "${WORKDIR}"
    continue
  fi

  WORKDIR=$(mktemp -d)
  CLONE_ERR=$(mktemp)
  APPLY_ERR=$(mktemp)
  if ! git clone --quiet --depth 50 "https://oauth2:${GITLAB_TOKEN}@${GITLAB_HOST}/${REPO_PATH}.git" "${WORKDIR}" 2>"${CLONE_ERR}"; then
    echo "    SKIPPED: could not clone repo:"
    sed 's/^/             /' "${CLONE_ERR}"
    rm -rf "${WORKDIR}"; rm -f "${CLONE_ERR}" "${APPLY_ERR}"
    continue
  fi

  if ! (cd "${WORKDIR}" && git apply --check "${DIFF_FILE}") 2>"${APPLY_ERR}"; then
    echo "    SKIPPED: patch does not apply cleanly — this repo has diverged from the"
    echo "             skeleton in a conflicting way and needs a manual merge:"
    sed 's/^/             /' "${APPLY_ERR}"
    rm -rf "${WORKDIR}"; rm -f "${CLONE_ERR}" "${APPLY_ERR}"
    continue
  fi
  rm -f "${CLONE_ERR}" "${APPLY_ERR}"

  (
    cd "${WORKDIR}"
    git checkout -q -b "${BRANCH}"
    git apply "${DIFF_FILE}"
    git -c user.email="template-lifecycle-bot@localhost" -c user.name="Template Lifecycle Bot" \
      commit -aq -m "Template upgrade: sync skeleton changes to v${VERSION_LABEL}"
    git push --quiet origin "${BRANCH}"
  )

  PROJECT_ID=$(gitlab_api "/projects?search=$(basename "${REPO_PATH}")" \
    | python3 -c "
import sys, json
projects = [p for p in json.load(sys.stdin) if p['path_with_namespace'] == '${REPO_PATH}']
print(projects[0]['id'] if projects else '')
")

  if [[ -z "${PROJECT_ID}" ]]; then
    echo "    Pushed branch ${BRANCH}, but could not resolve the GitLab project ID to open"
    echo "    an MR automatically. Open one manually from the pushed branch."
    rm -rf "${WORKDIR}"
    continue
  fi

  MR_RESPONSE=$(gitlab_api "/projects/${PROJECT_ID}/merge_requests" -X POST \
    --data-urlencode "source_branch=${BRANCH}" \
    --data-urlencode "target_branch=main" \
    --data-urlencode "title=Template Upgrade: sync skeleton changes to v${VERSION_LABEL}" \
    --data-urlencode "description=Scoped diff between ${FROM_SHA:0:8} and ${TO_SHA:0:8} (${SKELETON_PREFIX}), propagated by propagate-skeleton-diff.sh. Unlike the relation-processor plugin's full-repo diff, this MR contains only the lines that changed in the template itself.")

  MR_URL=$(echo "${MR_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('web_url',''))" 2>/dev/null || echo "")
  if [[ -n "${MR_URL}" ]]; then
    echo "    MR opened: ${MR_URL}"
  else
    echo "    Pushed branch ${BRANCH}, but MR creation failed:"
    echo "${MR_RESPONSE}" | python3 -m json.tool 2>/dev/null | sed 's/^/    /' || echo "    ${MR_RESPONSE}"
  fi

  rm -rf "${WORKDIR}"
done <<< "${REPOS}"

echo ""
echo "==> Done."
