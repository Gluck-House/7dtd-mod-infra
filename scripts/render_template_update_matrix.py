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


def write_outputs(matrix: list[dict[str, str]], template_id: str, template_src: str, template_ref: str) -> None:
    github_output = os.environ.get("GITHUB_OUTPUT")
    if not github_output:
        print(json.dumps(matrix, indent=2))
        return

    with Path(github_output).open("a", encoding="utf-8") as handle:
        handle.write(f"matrix={json.dumps(matrix)}\n")
        handle.write(f"template_id={template_id}\n")
        handle.write(f"template_src={template_src}\n")
        handle.write(f"template_ref={template_ref}\n")
        handle.write(f"repo_count={len(matrix)}\n")


def main() -> int:
    if len(sys.argv) != 5:
        return fail(
            "usage: render_template_update_matrix.py <manifest> <template_id> <repo_selector> <ref_override>"
        )

    manifest_path = Path(sys.argv[1])
    template_id = sys.argv[2]
    repo_selector = sys.argv[3]
    ref_override = sys.argv[4]

    manifest = yaml.safe_load(manifest_path.read_text(encoding="utf-8"))
    templates = manifest.get("templates", [])
    if template_id == "all" and ref_override:
        return fail("template_ref override requires a specific template_id; it cannot be used with template_id=all")

    selected_templates: list[dict[str, str]] = []
    if template_id == "all":
        selected_templates = templates
    else:
        template = next((item for item in templates if item.get("id") == template_id), None)
        if template is None:
            return fail(f"template id not found in manifest: {template_id}")
        selected_templates = [template]

    matrix: list[dict[str, str]] = []
    for template in selected_templates:
        resolved_template_id = template["id"]
        template_src = template["src"]
        template_ref = ref_override or template.get("ref") or f"v{template['version']}"

        for repo_item in template.get("repos", []):
            if repo_item.get("enabled", True) is not True:
                continue

            repo_name = repo_item["repo"]
            if repo_selector != "all" and repo_selector != repo_name:
                continue

            matrix.append(
                {
                    "repo": repo_name,
                    "branch": repo_item.get("branch", "main"),
                    "template_id": resolved_template_id,
                    "template_src": template_src,
                    "template_ref": template_ref,
                }
            )

    if repo_selector != "all" and not matrix:
        return fail(f"repo selector did not match any enabled repo for template '{template_id}': {repo_selector}")

    write_outputs(matrix, template_id, "", "")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
