#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


API_VERSION = "2022-11-28"


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def github_request(
    token: str,
    method: str,
    path: str,
    *,
    query: dict[str, str] | None = None,
    payload: dict | list | None = None,
) -> object:
    url = f"https://api.github.com{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"

    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")

    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": API_VERSION,
            "User-Agent": "7dtd-mod-infra",
            "Content-Type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(request) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"GitHub API {method} {path} failed: {exc.code} {detail}") from exc

    if not body:
        return None

    return json.loads(body.decode("utf-8"))


def list_open_prs(token: str, repo: str, head_owner: str, head_branch: str, base_branch: str) -> list[dict]:
    response = github_request(
        token,
        "GET",
        f"/repos/{repo}/pulls",
        query={
            "state": "open",
            "head": f"{head_owner}:{head_branch}",
            "base": base_branch,
            "per_page": "50",
        },
    )
    assert isinstance(response, list)
    return response


def set_labels(token: str, repo: str, issue_number: int, labels: list[str]) -> None:
    github_request(
        token,
        "PUT",
        f"/repos/{repo}/issues/{issue_number}/labels",
        payload={"labels": labels},
    )


def command_close_if_exists(args: argparse.Namespace) -> int:
    token = os.environ.get("MANAGED_REPOS_TOKEN")
    if not token:
        return fail("MANAGED_REPOS_TOKEN is required")

    owner = args.repo.split("/", 1)[0]
    prs = list_open_prs(token, args.repo, owner, args.head_branch, args.base_branch)
    if not prs:
        return 0

    pr_number = int(prs[0]["number"])

    github_request(
        token,
        "POST",
        f"/repos/{args.repo}/issues/{pr_number}/comments",
        payload={"body": args.comment},
    )
    github_request(
        token,
        "PATCH",
        f"/repos/{args.repo}/pulls/{pr_number}",
        payload={"state": "closed"},
    )
    return 0


def command_upsert(args: argparse.Namespace) -> int:
    token = os.environ.get("MANAGED_REPOS_TOKEN")
    if not token:
        return fail("MANAGED_REPOS_TOKEN is required")

    owner = args.repo.split("/", 1)[0]
    prs = list_open_prs(token, args.repo, owner, args.head_branch, args.base_branch)

    if prs:
        pr_number = int(prs[0]["number"])
        github_request(
            token,
            "PATCH",
            f"/repos/{args.repo}/pulls/{pr_number}",
            payload={
                "title": args.title,
                "body": args.body,
                "state": "open",
                "base": args.base_branch,
            },
        )
        set_labels(token, args.repo, pr_number, args.labels)
        return 0

    created = github_request(
        token,
        "POST",
        f"/repos/{args.repo}/pulls",
        payload={
            "title": args.title,
            "head": args.head_branch,
            "base": args.base_branch,
            "body": args.body,
            "maintainer_can_modify": True,
        },
    )
    assert isinstance(created, dict)
    pr_number = int(created["number"])
    set_labels(token, args.repo, pr_number, args.labels)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage cross-repo pull requests via the GitHub API.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    close_parser = subparsers.add_parser("close-if-exists")
    close_parser.add_argument("--repo", required=True)
    close_parser.add_argument("--base-branch", required=True)
    close_parser.add_argument("--head-branch", required=True)
    close_parser.add_argument("--comment", required=True)

    upsert_parser = subparsers.add_parser("upsert")
    upsert_parser.add_argument("--repo", required=True)
    upsert_parser.add_argument("--base-branch", required=True)
    upsert_parser.add_argument("--head-branch", required=True)
    upsert_parser.add_argument("--title", required=True)
    upsert_parser.add_argument("--body", required=True)
    upsert_parser.add_argument("--labels", nargs="*", default=["chore", "dependencies"])

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        if args.command == "close-if-exists":
            return command_close_if_exists(args)
        if args.command == "upsert":
            return command_upsert(args)
    except RuntimeError as exc:
        return fail(str(exc))

    return fail(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
