#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import sys
import tarfile
import tempfile
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

REQUIRED_FILES = (
    "0Harmony.dll",
    "Assembly-CSharp.dll",
    "LogLibrary.dll",
    "UnityEngine.dll",
    "UnityEngine.CoreModule.dll",
    ".7dtd-version",
)


def fail(message: str) -> int:
    print(message, file=sys.stderr)
    return 1


def bundle_prefix(app_id: str, build_id: str) -> str:
    return f"7dtd-deps/app-{app_id}/build-{build_id}"


def bundle_key(app_id: str, build_id: str) -> str:
    return f"{bundle_prefix(app_id, build_id)}/deps.tar.gz"


def manifest_key(app_id: str, build_id: str) -> str:
    return f"{bundle_prefix(app_id, build_id)}/manifest.env"


def s3_client():
    access_key = os.environ.get("DEPS_S3_ACCESS_KEY_ID") or os.environ.get("AWS_ACCESS_KEY_ID")
    secret_key = os.environ.get("DEPS_S3_SECRET_ACCESS_KEY") or os.environ.get("AWS_SECRET_ACCESS_KEY")
    endpoint = os.environ.get("DEPS_S3_ENDPOINT")
    region = os.environ.get("DEPS_S3_REGION", "eu-west-2")
    force_path_style = os.environ.get("DEPS_S3_FORCE_PATH_STYLE", "true").lower() == "true"

    if not access_key or not secret_key:
        raise RuntimeError("DEPS_S3_ACCESS_KEY_ID and DEPS_S3_SECRET_ACCESS_KEY are required")

    return boto3.client(
        "s3",
        aws_access_key_id=access_key,
        aws_secret_access_key=secret_key,
        endpoint_url=endpoint,
        region_name=region,
        config=Config(s3={"addressing_style": "path" if force_path_style else "auto"}),
    )


def require_bucket() -> str:
    bucket = os.environ.get("DEPS_S3_BUCKET")
    if not bucket:
        raise RuntimeError("DEPS_S3_BUCKET is required")
    return bucket


def ensure_required_files(deps_dir: Path) -> None:
    missing = [name for name in REQUIRED_FILES if not (deps_dir / name).is_file()]
    if missing:
        raise RuntimeError(f"deps bundle source is missing required files: {', '.join(missing)}")


def command_exists(args: argparse.Namespace) -> int:
    client = s3_client()
    bucket = require_bucket()

    try:
        client.head_object(Bucket=bucket, Key=bundle_key(args.app_id, args.build_id))
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code", "")
        if error_code in {"404", "NoSuchKey", "NotFound"}:
            return 1
        raise

    return 0


def command_upload(args: argparse.Namespace) -> int:
    client = s3_client()
    bucket = require_bucket()
    deps_dir = Path(args.deps_dir).resolve()

    ensure_required_files(deps_dir)

    with tempfile.TemporaryDirectory() as tmp_dir:
        archive_path = Path(tmp_dir) / "deps.tar.gz"
        with tarfile.open(archive_path, "w:gz") as tar:
            for name in REQUIRED_FILES:
                tar.add(deps_dir / name, arcname=name)

        client.upload_file(str(archive_path), bucket, bundle_key(args.app_id, args.build_id))
        client.upload_file(str(deps_dir / ".7dtd-version"), bucket, manifest_key(args.app_id, args.build_id))

    print(bundle_prefix(args.app_id, args.build_id))
    return 0


def command_download(args: argparse.Namespace) -> int:
    client = s3_client()
    bucket = require_bucket()
    deps_dir = Path(args.deps_dir).resolve()

    shutil.rmtree(deps_dir, ignore_errors=True)
    deps_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp_dir:
        archive_path = Path(tmp_dir) / "deps.tar.gz"
        client.download_file(bucket, bundle_key(args.app_id, args.build_id), str(archive_path))

        with tarfile.open(archive_path, "r:gz") as tar:
            tar.extractall(deps_dir)

    ensure_required_files(deps_dir)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage immutable 7DTD dependency bundles in S3.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name in ("exists", "upload", "download"):
        subparser = subparsers.add_parser(name)
        subparser.add_argument("--app-id", required=True)
        subparser.add_argument("--build-id", required=True)

        if name in {"upload", "download"}:
            subparser.add_argument("--deps-dir", required=True)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    try:
        if args.command == "exists":
            return command_exists(args)
        if args.command == "upload":
            return command_upload(args)
        if args.command == "download":
            return command_download(args)
    except RuntimeError as exc:
        return fail(str(exc))
    except ClientError as exc:
        return fail(str(exc))

    return fail(f"unsupported command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
