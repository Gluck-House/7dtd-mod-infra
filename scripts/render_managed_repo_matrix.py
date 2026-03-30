#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import yaml


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def write_outputs(matrix: list[dict[str, str]]) -> None:
    github_output = os.environ.get("GITHUB_OUTPUT")
    if not github_output:
        print(json.dumps(matrix, indent=2))
        return

    with Path(github_output).open("a", encoding="utf-8") as handle:
        handle.write(f"matrix={json.dumps(matrix)}\n")
        handle.write(f"repo_count={len(matrix)}\n")


def main() -> int:
    if len(sys.argv) != 3:
        return fail("usage: render_managed_repo_matrix.py <manifest> <repo_selector>")

    manifest_path = Path(sys.argv[1])
    repo_selector = sys.argv[2]
    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))

    seen: set[tuple[str, str]] = set()
    matrix: list[dict[str, str]] = []

    for template in manifest.get("templates", []):
        for repo_item in template.get("repos", []):
            if repo_item.get("enabled", True) is not True:
                continue

            repo_name = repo_item["repo"]
            if repo_selector != "all" and repo_selector != repo_name:
                continue

            branch = repo_item.get("branch", "main")
            key = (repo_name, branch)
            if key in seen:
                continue
            seen.add(key)

            matrix.append({"repo": repo_name, "branch": branch})

    if repo_selector != "all" and not matrix:
        return fail(f"repo selector did not match any enabled repo: {repo_selector}")

    write_outputs(matrix)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
