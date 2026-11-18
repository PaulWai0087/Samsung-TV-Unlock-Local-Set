#!/usr/bin/env python3
"""Publish exactly the reviewed release request; --publish enables remote writes.

Without --publish, this only builds and checks the three local release assets.
Publishing checks the pinned Windows CI run, creates a draft, downloads and
verifies every uploaded byte, then publishes it. Existing releases/tags are never
replaced, and a failed draft is kept for inspection. No TV code is executed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from package_release import ReleaseError, build_release, sha256_file


REPOSITORY = "PaulWai0087/Samsung-TV-Unlock-Local-Set"


def require(condition, message):
    if not condition:
        raise ReleaseError(message)


def command(arguments, optional_404=False):
    result = subprocess.run(arguments, capture_output=True, text=True, check=False)
    if result.returncode:
        if optional_404 and re.search(r"\(HTTP 404\)", result.stderr):
            return None
        raise ReleaseError("Command failed: " + arguments[0] + "\n" + result.stderr.strip())
    return result.stdout


def api(path, optional_404=False):
    output = command([
        "gh", "api", "--hostname", "github.com", "repos/" + REPOSITORY + "/" + path
    ], optional_404=optional_404)
    return None if output is None else json.loads(output)


def validate_request(path):
    request = json.loads(path.read_text(encoding="utf-8"))
    require(request.get("repository") == REPOSITORY, "Unexpected release repository")
    require(re.fullmatch(r"[0-9a-f]{40}", request.get("sourceCommit", "")), "Expected full source commit")
    require(re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", request.get("version", "")), "Expected a stable version")
    require(request.get("tag") == "v" + request["version"], "Version/tag mismatch")
    require(type(request.get("validationRunId")) is int and request["validationRunId"] > 0, "Expected pinned validation run")
    require(isinstance(request.get("title"), str) and request["title"].strip(), "Missing release title")
    require(request.get("notesFile") == "release/RELEASE-NOTES-" + request["tag"] + ".md", "Unexpected release notes path")
    names = {
        "Samsung-TV-Unlock-Local-Set-" + request["tag"] + "-Windows-x64.zip",
        "QN90B-Guide-" + request["tag"] + ".pdf", "SHA256SUMS.txt"
    }
    assets = request.get("assets", [])
    require(isinstance(assets, list) and len(assets) == 3, "Expected exactly three assets")
    require({item.get("filename") for item in assets} == names, "Unexpected asset names")
    for item in assets:
        require(type(item.get("size")) is int and item["size"] > 0, "Invalid asset size")
        require(re.fullmatch(r"[0-9a-f]{64}", item.get("sha256", "")), "Invalid asset hash")
    return request


def check_assets(directory, expected):
    require({p.name for p in directory.iterdir()} == {a["filename"] for a in expected}, "Asset directory has unexpected files")
    for item in expected:
        path = directory / item["filename"]
        require(path.is_file() and not path.is_symlink(), "Asset is not a regular file")
        require(path.stat().st_size == item["size"], "Asset size mismatch: " + path.name)
        require(sha256_file(path) == item["sha256"], "Asset hash mismatch: " + path.name)


def check_validation(request):
    run = api("actions/runs/" + str(request["validationRunId"]))
    require(run.get("head_sha") == request["sourceCommit"], "Validation was for a different commit")
    require(run.get("path") == ".github/workflows/offline-validation.yml", "Unexpected validation workflow")
    require(run.get("repository", {}).get("full_name") == REPOSITORY, "Unexpected validation repository")
    require(run.get("event") == "push" and run.get("head_branch") == "main", "Expected main branch push validation")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "Pinned validation did not pass")


def find_release(tag):
    # Refuse to infer absence if the listing might be incomplete.
    releases = api("releases?per_page=100")
    require(isinstance(releases, list) and len(releases) < 100, "Release listing needs explicit pagination review")
    matches = [release for release in releases if release.get("tag_name") == tag]
    require(len(matches) <= 1, "Multiple releases use this tag")
    return matches[0] if matches else None


def check_release_metadata(release, request, notes, draft):
    require(isinstance(release, dict), "Release could not be read back")
    require(release.get("tag_name") == request["tag"], "Published tag mismatch")
    require(release.get("target_commitish") == request["sourceCommit"], "Published source target mismatch")
    require(release.get("draft") is draft and release.get("prerelease") is False, "Release visibility/type mismatch")
    require(release.get("name") == request["title"], "Release title mismatch")
    require(release.get("body", "").strip() == notes.strip(), "Release notes mismatch")
    assets = release.get("assets", [])
    expected = {item["filename"]: item for item in request["assets"]}
    require(len(assets) == 3 and {a.get("name") for a in assets} == set(expected), "Uploaded asset set mismatch")
    for asset in assets:
        item = expected[asset["name"]]
        require(asset.get("state") == "uploaded" and asset.get("size") == item["size"], "Uploaded asset size/state mismatch")
        digest = asset.get("digest")
        if digest is not None:
            require(digest == "sha256:" + item["sha256"], "GitHub asset digest mismatch")


def publish(request, directory, notes_path, notes):
    check_validation(request)
    require(find_release(request["tag"]) is None, "Release already exists; refusing to overwrite it")
    require(api("git/ref/tags/" + request["tag"], optional_404=True) is None, "Tag already exists; refusing to replace it")
    paths = [str(directory / asset["filename"]) for asset in request["assets"]]
    print("Creating draft release and uploading three verified assets.", flush=True)
    command([
        "gh", "release", "create", request["tag"], *paths,
        "--repo", REPOSITORY, "--target", request["sourceCommit"],
        "--title", request["title"], "--notes-file", str(notes_path), "--draft"
    ])
    release = find_release(request["tag"])
    check_release_metadata(release, request, notes, draft=True)
    release_id = release["id"]
    # Verification uses downloaded bytes, even when GitHub supplies a digest.
    with tempfile.TemporaryDirectory(prefix="release-download-") as temporary:
        destination = Path(temporary)
        command([
            "gh", "release", "download", request["tag"],
            "--repo", REPOSITORY, "--dir", str(destination)
        ])
        check_assets(destination, request["assets"])
    check_release_metadata(api("releases/" + str(release_id)), request, notes, draft=True)
    # A concurrent tag creator must not silently redirect the reviewed release.
    ref = api("git/ref/tags/" + request["tag"], optional_404=True)
    if ref is not None:
        require(ref.get("object", {}).get("type") == "commit" and ref["object"]["sha"] == request["sourceCommit"], "Tag moved before publication")
    print("All uploaded bytes match. Publishing the release.", flush=True)
    command(["gh", "release", "edit", request["tag"], "--repo", REPOSITORY, "--draft=false", "--latest"])
    published = api("releases/" + str(release_id))
    check_release_metadata(published, request, notes, draft=False)
    ref = api("git/ref/tags/" + request["tag"])
    require(ref.get("object", {}).get("type") == "commit" and ref["object"]["sha"] == request["sourceCommit"], "Published tag does not match the verified source")
    require(api("releases/latest").get("id") == release_id, "Release was not marked Latest")
    print(json.dumps({
        "published": True, "url": published["html_url"],
        "tag": request["tag"], "sourceCommit": request["sourceCommit"],
        "assets": [{"name": a["name"], "url": a["browser_download_url"], "size": a["size"], "digest": a.get("digest")} for a in published["assets"]]
    }, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--request", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--publish", action="store_true", help="Create and publish the requested GitHub release")
    args = parser.parse_args()
    try:
        request = validate_request(args.request)
        command(["git", "merge-base", "--is-ancestor", request["sourceCommit"], "HEAD"])
        notes_path = Path(request["notesFile"])
        notes = notes_path.read_text(encoding="utf-8")
        require(request["sourceCommit"] in notes, "Notes do not identify the release source")
        require(str(request["validationRunId"]) in notes, "Notes do not identify the validation run")
        summary = build_release(argparse.Namespace(
            source_ref=request["sourceCommit"], version=request["version"], output_dir=args.output_dir
        ))
        check_assets(args.output_dir, request["assets"])
        print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)
        if args.publish:
            publish(request, args.output_dir.resolve(), notes_path.resolve(), notes)
        else:
            print("Local packaging verified. No GitHub writes requested.")
        return 0
    except (ReleaseError, OSError, ValueError, KeyError, TypeError) as error:
        print("Release stopped: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
