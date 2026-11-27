#!/usr/bin/env python3
"""Offline verifier for spec-lock.json and synced rabbitcontrol-spec generated files.

Security invariants:
- Zero network calls; standard library only.
- Rejects symlinks on spec-lock.json, the generated directory, any ancestor inside the
  repository, any tracked target file, and any entry inside the generated directory.
- Restricts all tracked targets to POSIX relative paths under `RabbitControlIOS/Generated/`.
- Fails on any unregistered file or subdirectory entry under `RabbitControlIOS/Generated/`.
- Strictly verifies lowercase 64-hex SHA-256 checksums for every tracked file.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import re
import stat
import sys
from typing import Any

SPEC_REPO = "TokenBoom/rabbitcontrol-spec"
ALLOWED_PREFIX = "RabbitControlIOS/Generated/"
ALLOWED_DIR_PARTS = ("RabbitControlIOS", "Generated")
DRIVE_PREFIX_RE = re.compile(r"^[A-Za-z]:")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


def sha256_regular_file_nofollow(path: pathlib.Path) -> str:
    """Hash a regular file while refusing to follow symlinks on the leaf."""
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    if hasattr(os, "O_BINARY"):
        flags |= os.O_BINARY
    fd = os.open(str(path), flags)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError(f"not a regular file: {path}")
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb", closefd=False) as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                digest.update(chunk)
        return digest.hexdigest()
    finally:
        os.close(fd)


def check_no_symlinks_under(repo_root: pathlib.Path, rel_parts: tuple[str, ...]) -> None:
    """Assert that no path component from repo_root through rel_parts is a symlink."""
    cur = repo_root
    for part in rel_parts:
        cur = cur / part
        if cur.is_symlink():
            raise ValueError(f"symlink is forbidden: {cur}")


def validate_target_path(
    raw_target: Any, repo_root: pathlib.Path, repo_root_resolved: pathlib.Path
) -> tuple[pathlib.Path, str]:
    if not isinstance(raw_target, str) or not raw_target:
        raise ValueError("target must be a non-empty string")
    if "\x00" in raw_target or "\\" in raw_target:
        raise ValueError(
            f"target must use POSIX '/' separators without NUL or backslashes: {raw_target!r}"
        )
    if (
        raw_target.startswith("/")
        or raw_target.endswith("/")
        or DRIVE_PREFIX_RE.match(raw_target)
    ):
        raise ValueError(f"target must be a relative POSIX file path: {raw_target!r}")

    segments = raw_target.split("/")
    for seg in segments:
        if seg in ("", ".", ".."):
            raise ValueError(
                f"target must not contain empty, '.', or '..' segments: {raw_target!r}"
            )
        if seg == ".git":
            raise ValueError(f"target must not reference '.git': {raw_target!r}")

    normalized = "/".join(segments)
    if not normalized.startswith(ALLOWED_PREFIX):
        raise ValueError(
            f"target {normalized!r} is outside allowed directory {ALLOWED_PREFIX!r}"
        )

    check_no_symlinks_under(repo_root, tuple(segments))

    candidate = repo_root.joinpath(*segments)
    if not candidate.exists():
        raise ValueError(f"missing synced file: {normalized}")
    if candidate.is_symlink() or not candidate.is_file():
        raise ValueError(f"target must be a regular non-symlink file: {normalized}")

    resolved = candidate.resolve(strict=True)
    allowed_dir_resolved = repo_root_resolved.joinpath(*ALLOWED_DIR_PARTS).resolve(
        strict=True
    )
    try:
        resolved.relative_to(allowed_dir_resolved)
    except ValueError as exc:
        raise ValueError(
            f"target {normalized!r} resolves outside {ALLOWED_PREFIX!r}: {resolved}"
        ) from exc

    try:
        rel_resolved = resolved.relative_to(repo_root_resolved)
    except ValueError as exc:
        raise ValueError(
            f"target {normalized!r} escapes repository root: {resolved}"
        ) from exc

    if rel_resolved.as_posix() != normalized:
        raise ValueError(
            f"target {normalized!r} resolves to unexpected path {rel_resolved.as_posix()!r}"
        )

    return candidate, normalized


def scan_generated_tree(
    repo_root: pathlib.Path, generated_dir: pathlib.Path
) -> tuple[set[str], list[str]]:
    """Walk generated_dir without following symlinks, collecting all files and errors."""
    discovered: set[str] = set()
    errors: list[str] = []

    def _walk(cur_dir: pathlib.Path) -> None:
        try:
            entries = sorted(os.scandir(cur_dir), key=lambda e: e.name)
        except OSError as exc:
            errors.append(f"failed to scan directory {cur_dir}: {exc}")
            return

        for entry in entries:
            entry_path = pathlib.Path(entry.path)
            rel_posix = entry_path.relative_to(repo_root).as_posix()
            if entry.is_symlink():
                errors.append(f"symlink forbidden inside generated dir: {rel_posix}")
                continue
            if entry.is_dir(follow_symlinks=False):
                _walk(entry_path)
            elif entry.is_file(follow_symlinks=False):
                discovered.add(rel_posix)
            else:
                errors.append(
                    f"non-regular filesystem entry inside generated dir: {rel_posix}"
                )

    _walk(generated_dir)
    return discovered, errors


def verify(repo_root: pathlib.Path) -> int:
    failures: list[str] = []
    repo_root_resolved = repo_root.resolve(strict=True)

    lock_path = repo_root / "spec-lock.json"
    if lock_path.is_symlink():
        print(f"ERROR: spec-lock.json must not be a symlink: {lock_path}", file=sys.stderr)
        return 1
    if not lock_path.is_file():
        print(f"ERROR: spec-lock.json not found: {lock_path}", file=sys.stderr)
        return 1

    try:
        check_no_symlinks_under(repo_root, ALLOWED_DIR_PARTS)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    generated_dir = repo_root.joinpath(*ALLOWED_DIR_PARTS)
    if not generated_dir.is_dir() or generated_dir.is_symlink():
        print(
            f"ERROR: generated directory missing or invalid: {generated_dir}",
            file=sys.stderr,
        )
        return 1

    try:
        lock_data = json.loads(lock_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"ERROR: failed to parse spec-lock.json: {exc}", file=sys.stderr)
        return 1

    if not isinstance(lock_data, dict):
        print("ERROR: spec-lock.json root must be a JSON object", file=sys.stderr)
        return 1

    spec_repo = lock_data.get("spec_repo")
    spec_version = lock_data.get("spec_version")
    files = lock_data.get("files")

    if spec_repo != SPEC_REPO:
        failures.append(f"spec_repo mismatch: got {spec_repo!r}, expected {SPEC_REPO!r}")
    if not isinstance(spec_version, str) or not spec_version.strip():
        failures.append(f"spec_version must be a non-empty string, got {spec_version!r}")
    if not isinstance(files, list) or not files:
        failures.append("spec-lock.json 'files' must be a non-empty list")
        files = []

    tracked_targets: set[str] = set()
    for idx, item in enumerate(files):
        if not isinstance(item, dict):
            failures.append(f"files[{idx}] is not an object")
            continue

        artifact = item.get("artifact")
        source = item.get("source")
        target = item.get("target")
        expected_sha = item.get("sha256")

        if not isinstance(artifact, str) or not artifact.strip():
            failures.append(f"files[{idx}].artifact must be a non-empty string")
        if not isinstance(source, str) or not source.strip():
            failures.append(f"files[{idx}].source must be a non-empty string")
        if not isinstance(expected_sha, str) or not SHA256_RE.match(expected_sha):
            failures.append(
                f"files[{idx}].sha256 must be a 64-char lowercase hex SHA-256, got {expected_sha!r}"
            )
            continue

        try:
            target_path, normalized = validate_target_path(
                target, repo_root, repo_root_resolved
            )
        except ValueError as exc:
            failures.append(f"files[{idx}]: {exc}")
            continue

        if normalized in tracked_targets:
            failures.append(f"duplicate target in spec-lock.json: {normalized!r}")
            continue
        tracked_targets.add(normalized)

        try:
            actual_sha = sha256_regular_file_nofollow(target_path)
        except (OSError, ValueError) as exc:
            failures.append(f"failed to hash {normalized}: {exc}")
            continue

        if actual_sha != expected_sha:
            failures.append(
                f"SHA-256 mismatch for {normalized} (hand-edited or stale):\n"
                f"  lock:   {expected_sha}\n"
                f"  actual: {actual_sha}"
            )

    discovered_files, scan_errors = scan_generated_tree(repo_root, generated_dir)
    failures.extend(scan_errors)

    unregistered = sorted(discovered_files - tracked_targets)
    for rel in unregistered:
        failures.append(
            f"unregistered file in {ALLOWED_PREFIX}: {rel} (not listed in spec-lock.json)"
        )

    if failures:
        print(
            "ERROR: spec-lock verification failed:\n- " + "\n- ".join(failures),
            file=sys.stderr,
        )
        return 1

    print(
        f"OK: verified {len(tracked_targets)} synced spec file(s) "
        f"under {ALLOWED_PREFIX} ({SPEC_REPO} v{spec_version})."
    )
    return 0


def main() -> int:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    return verify(repo_root)


if __name__ == "__main__":
    raise SystemExit(main())
