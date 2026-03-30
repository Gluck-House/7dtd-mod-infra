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

token="${MANAGED_REPOS_TOKEN:?MANAGED_REPOS_TOKEN is required}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

safe_ref="$(printf '%s' "$template_ref" | tr '/:@ ' '----')"
update_branch="chore/template-update-${template_id}-${safe_ref}"
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

git -C "$work_dir/repo" config user.name "github-actions[bot]"
git -C "$work_dir/repo" config user.email "41898282+github-actions[bot]@users.noreply.github.com"

uvx copier update --defaults --skip-answered --vcs-ref "$template_ref" "$work_dir/repo"

if git -C "$work_dir/repo" diff --quiet; then
    echo "No template changes for ${repo}"
    [ -n "${GITHUB_OUTPUT:-}" ] && {
        printf 'changed=false\n' >> "$GITHUB_OUTPUT"
        printf 'repo=%s\n' "$repo" >> "$GITHUB_OUTPUT"
    }
    exit 0
fi

git -C "$work_dir/repo" checkout -B "$update_branch" >/dev/null 2>&1
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
