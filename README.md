# 7DTD Mod Infra

This repository contains the shared build and automation infrastructure for Gluck House 7 Days to Die mod repositories.

Its job is to hold reusable GitHub Actions workflows, composite actions, and related CI helpers that can be consumed by multiple standalone mod repositories.

## Purpose

Each mod should remain in its own repository, but the automation around those repos should be consistent.

This repository exists to provide that shared automation layer so mod repositories do not need to duplicate large workflow files or maintain slightly different copies of the same CI logic.

Typical responsibilities for this repository include:

- reusable build workflows invoked with `workflow_call`
- shared composite actions for downloading pinned 7DTD dependencies
- shared automation for checking whether a pinned 7DTD build is stale and opening update PRs
- central publishing of immutable 7DTD dependency bundles
- standard packaging and artifact upload steps
- release and publishing workflow building blocks

## What Belongs Here

Once scaffolded, this repository will typically contain a structure close to this:

```text
.
├── config/
│   └── managed-templates.yml
├── .github/
│   ├── actions/
│   │   ├── setup-7dtd-deps/
│   │   ├── check-7dtd-build/
│   │   └── package-mod/
│   └── workflows/
│       ├── build-mod.yml
│       ├── release-mod.yml
│       ├── update-managed-template.yml
│       └── update-7dtd-version.yml
├── scripts/
│   ├── render_template_update_matrix.py
│   └── update_managed_repo.sh
├── LICENSE
└── README.md
```

The exact layout may evolve, but the core idea should stay the same: this repo owns reusable automation, not mod source code.

## What Does Not Belong Here

This repository should not become a monorepo for mods and should not hold the canonical source for individual mod projects.

In particular, mod repositories should continue to own:

- their source code
- their solution and project files
- their resource and packaging layout
- their repo-local `.github/7dtd-version.env` pin
- their top-level build wrapper workflow that calls into this repository

The Copier template repository is responsible for defining the default repository shape. This infrastructure repository is responsible for the shared automation those generated repositories consume.

## Consumption Model

The intended usage pattern is:

1. A mod repository is created from the `7dtd-mod-template` Copier template.
2. That repo includes thin workflow wrappers.
3. Those wrappers call reusable workflows from this repository by pinned ref.
4. The mod repo supplies inputs such as solution path, artifact path, and packaging details.

This keeps mod repositories independent while still centralizing CI behavior.

## Managed Template Updates

This repository now includes the first scaffold for managing Copier-based template rollouts across mod repositories.

The source of truth is [config/managed-templates.yml](/home/luke/repos/7dtd-mod-infra/config/managed-templates.yml), which uses a template-first layout:

```yaml
templates:
  - id: standard-mod
    src: https://github.com/Gluck-House/7dtd-mod-template
    version: 0.1.0
    repos:
      - repo: Gluck-House/7dtd-timeloop
        branch: main
        enabled: true
```

The intended rollout flow is:

1. Change `7dtd-mod-template`.
2. Tag that repository with a SemVer tag such as `v0.1.0`.
3. Update the managed template version in this repository if needed.
4. Push the manifest change to `main` in this repository, or wait for the daily scheduled run.
5. The workflow clones each selected managed repo, runs `uvx copier update`, pushes a stable template branch, and opens or updates a PR if there is a diff.
6. Use a manual workflow run only when you want to target a specific repo or override the template ref.

### Workflow Triggers

The [update-managed-template.yml](/home/luke/repos/7dtd-mod-infra/.github/workflows/update-managed-template.yml) workflow runs:

- automatically on pushes to `main`
- automatically once per day on a schedule
- manually via `workflow_dispatch`

Automatic runs use `all` and `all`, so every enabled template and every enabled repo in the manifest is evaluated.

Each managed repo uses one rolling update branch per template. If a PR is already open for a given repo and template, later runs force-push fresh changes to that same branch and update the existing PR instead of opening a new one.

### Workflow Inputs

The [update-managed-template.yml](/home/luke/repos/7dtd-mod-infra/.github/workflows/update-managed-template.yml) workflow accepts:

- `template_id`: manifest template id such as `standard-mod`, or `all`
- `repo`: `all` or one repo in `owner/name` form
- `template_ref`: optional override tag, branch, or SHA

If `template_ref` is left blank, the workflow resolves each manifest `version` to a git tag in the form `v<version>`.

`template_ref` should only be used when `template_id` targets a single template. It is intentionally not supported with `template_id=all`.

### Token Requirement

Cross-repository PR creation requires a token that can push branches and open pull requests in the managed repositories.

Create a secret named `MANAGED_REPOS_TOKEN` in this repository with access to the target mod repositories. A GitHub App installation token or fine-grained personal access token is the right shape for this.

The workflow does not use the default `GITHUB_TOKEN` for cross-repo pushes because that token is normally scoped to the current repository only.

### Shared Dependency Bundle Access

Downstream build workflows now fetch pinned 7DTD dependency bundles from shared S3 storage.

Because reusable workflows execute in the caller repository context, the consuming mod repositories need access to the S3 credentials and bucket settings used for bundle download.

Provide these in the consuming repositories, or as organization-level secrets and variables:

- secret: `_7DTD_S3_ACCESS_KEY_ID`
- secret: `_7DTD_S3_SECRET_ACCESS_KEY`
- variable: `_7DTD_S3_BUCKET`
- variable: `_7DTD_S3_ENDPOINT`
- variable: `_7DTD_S3_FORCE_PATH_STYLE`
- variable: `_7DTD_S3_REGION`

## Template Versioning

For the template repository itself, the lowest-friction versioning model is to use git tags as the source of truth.

Recommended pattern:

- use SemVer-style tags like `v0.1.0`, `v0.1.1`, `v0.2.0`
- create a tag when the template is in a rollout-ready state
- point managed repositories at tags, not template `main`

This keeps updates reproducible and makes it possible to roll a set of repositories forward in a controlled way.

At this stage, a separate `VERSION` file in the template repository is not necessary. The manifest in this repository can store the human-facing version number, and the workflow can derive the git ref as `v<version>`.

## Design Principles

- Keep mod repositories standalone.
- Centralize automation logic here, not in each mod repo.
- Keep version pinning decisions in the consuming mod repo.
- Prefer reusable workflows and composite actions over copied workflow YAML.
- Avoid committing game DLLs unless redistribution has been explicitly cleared.

## Reusable Workflows

This repository now owns the shared workflows that downstream mod repositories consume directly, plus the central workflow that manages 7DTD pin updates across repos:

- [reusable-build.yml](/home/luke/repos/7dtd-mod-infra/.github/workflows/reusable-build.yml): downloads the exact pinned dependency bundle from shared S3 storage, runs the repo-local build entry point, and stages the packaged artifact
- [update-managed-7dtd-build.yml](/home/luke/repos/7dtd-mod-infra/.github/workflows/update-managed-7dtd-build.yml): runs the normal daily cross-repo pinned-build update loop from infra

The current split is intentional:

- downstream repos still own `build.sh`, their source tree, and `.github/7dtd-version.env`
- downstream repos may keep a local `scripts/download_7dtd_server.sh` helper for developer builds, but they no longer need repo-local update workflows or repo-local build-check scripts
- this repository owns the daily Steam query, dependency bundle publication, and PR orchestration for pinned build updates
- shared dependency bundles are stored immutably in S3 by `APP_ID` and `BUILD_ID`, so different repos can stay pinned to different game builds safely

## Status

This repository now contains:

- a template-first manifest in [managed-templates.yml](/home/luke/repos/7dtd-mod-infra/config/managed-templates.yml)
- helper scripts for resolving update targets and applying Copier updates
- an automated workflow for raising update PRs into managed repositories
- reusable workflows for shared mod build and 7DTD pin update automation

The next step is to keep extracting shared workflow logic from downstream repos into these reusable workflows, then use Copier rollouts to apply the wrapper changes consistently.
