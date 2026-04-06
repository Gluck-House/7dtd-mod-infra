#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "usage: update_managed_repo.sh <repo> <base_branch> <template_id> <template_src> <template_ref>" >&2
    exit 1
fi

repo="$1"
base_branch="$2"
template_id="$3"
template_src="$4"
template_ref="$5"
release_manifest_file=".github/release-please-manifest.json"
release_config_file=".github/release-please-config.json"
release_version_file="version.txt"

token="${MANAGED_REPOS_TOKEN:?MANAGED_REPOS_TOKEN is required}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

update_branch="chore/template-update-${template_id}"
commit_message="chore(template): update from ${template_id} ${template_ref}"
pr_title="$commit_message"
pr_body=$(
    cat <<EOF
Automated Copier update from \`${template_src}\`.

- Template ID: \`${template_id}\`
- Template ref: \`${template_ref}\`
- Managed by: \`7dtd-mod-infra\`
EOF
)

export GH_TOKEN="$token"

git clone "https://x-access-token:${token}@github.com/${repo}.git" "$work_dir/repo" >/dev/null 2>&1
git -C "$work_dir/repo" checkout "$base_branch" >/dev/null 2>&1

if [ ! -f "$work_dir/repo/.copier-answers.yml" ]; then
    echo "Repository ${repo} does not contain .copier-answers.yml" >&2
    exit 1
fi

current_mod_version="$(
    python - <<'PY' "$work_dir/repo"
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

repo_root = Path(sys.argv[1])
modinfo_path = next(repo_root.glob("*/resources/ModInfo.xml"), None)
if modinfo_path is None:
    raise SystemExit(0)

tree = ET.parse(modinfo_path)
version_node = tree.find("./Version")
if version_node is None:
    raise SystemExit(0)

print(version_node.attrib.get("value", ""))
PY
)"

had_release_manifest=false
[ -f "$work_dir/repo/$release_manifest_file" ] && had_release_manifest=true

had_release_config=false
[ -f "$work_dir/repo/$release_config_file" ] && had_release_config=true

had_release_version_file=false
[ -f "$work_dir/repo/$release_version_file" ] && had_release_version_file=true

git -C "$work_dir/repo" config user.name "github-actions[bot]"
git -C "$work_dir/repo" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$work_dir/repo" checkout -B "$update_branch" >/dev/null 2>&1

uvx copier update --defaults --skip-answered --vcs-ref "$template_ref" "$work_dir/repo"

if [ -n "$current_mod_version" ]; then
    if [ "$had_release_config" = false ] && [ -f "$work_dir/repo/$release_config_file" ]; then
        latest_release_tag="$(
            git -C "$work_dir/repo" tag --list --sort=-version:refname | grep -E '^(v)?[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true
        )"

        latest_release_sha=""
        if [ -n "$latest_release_tag" ]; then
            latest_release_sha="$(git -C "$work_dir/repo" rev-list -n 1 "$latest_release_tag" 2>/dev/null || true)"
        fi

        if [ -n "$latest_release_sha" ]; then
            python - <<'PY' "$work_dir/repo/$release_config_file" "$latest_release_sha"
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
bootstrap_sha = sys.argv[2]
config = json.loads(config_path.read_text(encoding="utf-8"))
config["bootstrap-sha"] = bootstrap_sha
config_path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")
PY
        fi
    fi

    if [ "$had_release_manifest" = false ] && [ -f "$work_dir/repo/$release_manifest_file" ]; then
        python - <<'PY' "$work_dir/repo/$release_manifest_file" "$current_mod_version"
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
version = sys.argv[2]
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
manifest["."] = version
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
PY
    fi

    if [ "$had_release_version_file" = false ] && [ -f "$work_dir/repo/$release_version_file" ]; then
        printf '%s\n' "$current_mod_version" > "$work_dir/repo/$release_version_file"
    fi
fi

if git -C "$work_dir/repo" diff --quiet; then
    echo "No template changes for ${repo}"
    [ -n "${GITHUB_OUTPUT:-}" ] && {
        printf 'changed=false\n' >> "$GITHUB_OUTPUT"
        printf 'repo=%s\n' "$repo" >> "$GITHUB_OUTPUT"
    }
    exit 0
fi

git -C "$work_dir/repo" add -A
git -C "$work_dir/repo" commit -m "$commit_message" >/dev/null
git -C "$work_dir/repo" push --force-with-lease origin "$update_branch" >/dev/null

existing_pr_number="$(
    gh pr list \
        --repo "$repo" \
        --state open \
        --head "$update_branch" \
        --json number \
        --jq '.[0].number // ""'
)"

if [ -n "$existing_pr_number" ]; then
    gh pr edit "$existing_pr_number" --repo "$repo" --title "$pr_title" --body "$pr_body" >/dev/null
    pr_url="$(gh pr view "$existing_pr_number" --repo "$repo" --json url --jq '.url')"
else
    pr_url="$(
        gh pr create \
            --repo "$repo" \
            --base "$base_branch" \
            --head "$update_branch" \
            --title "$pr_title" \
            --body "$pr_body"
    )"
fi

echo "Created or updated PR for ${repo}: ${pr_url}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        printf 'changed=true\n'
        printf 'repo=%s\n' "$repo"
        printf 'branch=%s\n' "$update_branch"
        printf 'pr_url=%s\n' "$pr_url"
    } >> "$GITHUB_OUTPUT"
fi
