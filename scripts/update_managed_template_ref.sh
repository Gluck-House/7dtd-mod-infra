#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "usage: update_managed_template_ref.sh <repo> <base_branch> <template_id> <template_ref>" >&2
    exit 1
fi

repo="$1"
base_branch="$2"
template_id="$3"
template_ref="$4"

token="${MANAGED_REPOS_TOKEN:?MANAGED_REPOS_TOKEN is required}"
config_file="config/managed-templates.yml"
update_branch="chore/template-release-${template_id}"
commit_message="chore(template): bump ${template_id} to ${template_ref}"
pr_title="$commit_message"
pr_body=$(
    cat <<EOF
Automated promotion of a released template ref.

- Template ID: \`${template_id}\`
- Template ref: \`${template_ref}\`
- Managed by: \`7dtd-mod-infra\`
EOF
)

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pr_script="$scripts_dir/manage_repo_pull_request.py"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
export GH_TOKEN="$token"
export MANAGED_REPOS_TOKEN="$token"

close_stale_pr() {
    uv run python "$pr_script" close-if-exists \
        --repo "$repo" \
        --base-branch "$base_branch" \
        --head-branch "$update_branch" \
        --comment "Managed template ref is already current. Closing automated promotion PR." >/dev/null

    if git ls-remote --exit-code --heads origin "$update_branch" >/dev/null 2>&1; then
        git push origin ":refs/heads/${update_branch}" >/dev/null
    fi
}

uv run --with pyyaml python - <<'PY' "$config_file" "$template_id" "$template_ref"
from __future__ import annotations

import sys
from pathlib import Path

import yaml

config_path = Path(sys.argv[1])
template_id = sys.argv[2]
template_ref = sys.argv[3]

config = yaml.safe_load(config_path.read_text(encoding="utf-8"))
templates = config.get("templates", [])
template = next((item for item in templates if item.get("id") == template_id), None)
if template is None:
    raise SystemExit(f"template id not found in manifest: {template_id}")

template["ref"] = template_ref
template.pop("version", None)

config_path.write_text(yaml.safe_dump(config, sort_keys=False), encoding="utf-8")
PY

git add "$config_file"
if git diff --cached --quiet -- "$config_file"; then
    echo "Managed template ref is already current for ${template_id}"
    close_stale_pr
    exit 0
fi

git checkout -B "$update_branch" >/dev/null 2>&1
git commit -m "$commit_message" >/dev/null
git push --force-with-lease origin "$update_branch" >/dev/null

uv run python "$pr_script" upsert \
    --repo "$repo" \
    --base-branch "$base_branch" \
    --head-branch "$update_branch" \
    --title "$pr_title" \
    --body "$pr_body" \
    --labels chore dependencies >/dev/null

echo "Created or updated template promotion PR for ${repo}"
