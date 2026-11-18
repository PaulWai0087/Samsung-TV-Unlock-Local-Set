#!/usr/bin/env python3
"""Build verified release assets from one immutable Git commit.

Run from a local checkout, for example:
    python tools/package_release.py --source-ref <40-hex-commit> \
        --version 1.0.2 --output-dir /path/to/release-assets

Only Python's standard library and Git are required. The working tree is never
packaged, no dependencies are downloaded, and no TV or helper code is executed.
Git supplies the content; fixed ZIP metadata and uncompressed members make the
release ZIP independent of Git and zlib compression versions.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


PREFIX = "Samsung-TV-Unlock-Local-Set/"
PACKAGE_MANIFEST = "Package-SHA256.txt"
CANONICAL_TIMESTAMP = (2000, 1, 1, 0, 0, 0)
CANONICAL_FILE_MODE = (stat.S_IFREG | 0o644) << 16
SHA256_RE = re.compile(r"[0-9a-fA-F]{64}")
NUMBER = r"(?:0|[1-9][0-9]*)"
PRERELEASE = r"(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
SEMVER_RE = re.compile(
    rf"{NUMBER}\.{NUMBER}\.{NUMBER}"
    rf"(?:-{PRERELEASE}(?:\.{PRERELEASE})*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


class ReleaseError(Exception):
    """An input, integrity or publication check failed."""


def source_ref_arg(value):
    if not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise argparse.ArgumentTypeError("source-ref must be a complete 40-hex Git commit")
    return value.lower()


def version_arg(value):
    if not SEMVER_RE.fullmatch(value):
        raise argparse.ArgumentTypeError("version must be strict SemVer, without a leading v")
    return value


def git_output(*arguments):
    result = subprocess.run(
        ["git", *arguments], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ReleaseError("Git failed: " + detail)
    return result.stdout


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def valid_relative_path(value):
    if not value or "\\" in value or "\x00" in value:
        return False
    path = PurePosixPath(value)
    return (
        not path.is_absolute()
        and all(part not in ("", ".", "..") for part in value.split("/"))
        and ":" not in value
    )


def unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReleaseError("Duplicate helper manifest key: " + key)
        result[key] = value
    return result


def verify_guide_page_count(data):
    # This repository's ReportLab guide has direct, uncompressed page objects.
    # Refuse a different structure instead of claiming to parse arbitrary PDFs.
    if not data.startswith(b"%PDF-") or b"%%EOF" not in data[-1024:]:
        raise ReleaseError("Archived guide is not a complete PDF")
    objects = re.findall(rb"(?ms)^[0-9]+\s+[0-9]+\s+obj\b(.*?)\bendobj\b", data)
    pages = [body for body in objects if re.search(rb"/Type\s*/Page\b", body)]
    trees = [body for body in objects if re.search(rb"/Type\s*/Pages\b", body)]
    declared = [int(value) for body in trees for value in re.findall(rb"/Count\s+([0-9]+)\b", body)]
    if len(pages) != 10 or declared != [10]:
        raise ReleaseError("Expected the repository's ten-page, direct-object PDF guide")
    return 10


def verify_archive(archive_path, source_ref, version):
    with zipfile.ZipFile(archive_path) as archive:
        if archive.comment != source_ref.encode("ascii"):
            raise ReleaseError("Git archive comment does not match the requested commit")
        failed_member = archive.testzip()
        if failed_member is not None:
            raise ReleaseError("ZIP CRC verification failed: " + failed_member)
        files = {}
        seen = set()
        for item in archive.infolist():
            if item.filename in seen:
                raise ReleaseError("Duplicate ZIP member: " + item.filename)
            seen.add(item.filename)
            if not item.filename.startswith(PREFIX):
                raise ReleaseError("ZIP member is outside the required prefix")
            if item.is_dir():
                continue
            relative = item.filename[len(PREFIX):]
            if not valid_relative_path(relative):
                raise ReleaseError("Invalid archive path: " + relative)
            mode = item.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise ReleaseError("Symbolic links are not release files: " + relative)
            files[relative] = item

        def read(relative):
            if relative not in files:
                raise ReleaseError("Missing archived file: " + relative)
            return archive.read(files[relative])

        expected = {}
        for line_no, line in enumerate(read(PACKAGE_MANIFEST).decode("utf-8-sig").splitlines(), 1):
            if not line.strip():
                continue
            match = re.fullmatch(r"([0-9a-fA-F]{64})  (.+)", line)
            if match is None:
                raise ReleaseError("Invalid package manifest line " + str(line_no))
            digest, relative = match.groups()
            if not valid_relative_path(relative) or relative in expected:
                raise ReleaseError("Invalid or duplicate package manifest path: " + relative)
            expected[relative] = digest.lower()
        if "LICENSE" not in expected:
            raise ReleaseError("The package manifest must include LICENSE")
        actual_files = set(files) - {PACKAGE_MANIFEST}
        if set(expected) != actual_files:
            missing = sorted(set(expected) - actual_files)
            unlisted = sorted(actual_files - set(expected))
            raise ReleaseError("Package manifest coverage mismatch: " + json.dumps(
                {"missing": missing, "unlisted": unlisted}, ensure_ascii=False
            ))
        for relative, digest in expected.items():
            if hashlib.sha256(read(relative)).hexdigest() != digest:
                raise ReleaseError("Package SHA256 mismatch: " + relative)

        version_text = read("VERSION.txt").decode("utf-8-sig")
        versions = re.findall(r"(?m)^QN90B Region Assistant ([^\s]+)(?:\s|$)", version_text)
        if versions != [version]:
            raise ReleaseError("Archived VERSION.txt does not match version " + version)

        helper_count = 0
        for stage in (1, 2):
            directory = "engines/stage" + str(stage) + "/"
            name = "QN90BStage" + str(stage)
            manifest = json.loads(
                read(directory + "Helper-SHA256.json").decode("utf-8-sig"),
                object_pairs_hook=unique_json_object,
            )
            required = {name + suffix for suffix in (".dll", ".runtimeconfig.json", ".deps.json")}
            if not isinstance(manifest, dict) or set(manifest) != required:
                raise ReleaseError("Unexpected helper manifest entries for stage " + str(stage))
            for filename, digest in manifest.items():
                if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
                    raise ReleaseError("Invalid helper hash: " + filename)
                if hashlib.sha256(read(directory + filename)).hexdigest() != digest.lower():
                    raise ReleaseError("Helper SHA256 mismatch: " + filename)
                helper_count += 1

        guide = read("guide/QN90B-Guide.pdf")
        pages = verify_guide_page_count(guide)
        return guide, len(expected), helper_count, pages


def canonicalize_archive(source_path, destination_path, source_ref):
    """Preserve verified Git bytes with a fixed, portable ZIP layout.

    Only file entries are emitted; their prefixed names represent directories.
    All files use mode 0644, a fixed DOS timestamp, and ZIP_STORED. Filenames are
    sorted by relative-path UTF-8 bytes. ASCII names use flags 0; other names use
    UTF-8 flag 0x800. The seekable output needs no data-descriptor flag. No extra
    fields, per-member comments, or ZIP64 records are used.
    """
    with zipfile.ZipFile(source_path) as source:
        members = sorted(
            (member for member in source.infolist() if not member.is_dir()),
            key=lambda member: member.filename[len(PREFIX):].encode("utf-8"),
        )
        names = [member.filename for member in members]
        with zipfile.ZipFile(
            destination_path, "x", compression=zipfile.ZIP_STORED, allowZip64=False
        ) as destination:
            destination.comment = source_ref.encode("ascii")
            for member in members:
                entry = zipfile.ZipInfo(member.filename, date_time=CANONICAL_TIMESTAMP)
                entry.compress_type = zipfile.ZIP_STORED
                entry.create_system = 3
                entry.create_version = 20
                entry.extract_version = 20
                entry.reserved = 0
                entry.volume = 0
                entry.internal_attr = 0
                entry.external_attr = CANONICAL_FILE_MODE
                entry.flag_bits = 0
                entry.extra = b""
                entry.comment = b""
                # zipfile deterministically sets 0x800 for non-ASCII names.
                destination.writestr(entry, source.read(member))

    # Check the on-disk metadata as well, including zipfile's encoding flags.
    with zipfile.ZipFile(destination_path) as archive:
        if archive.namelist() != names:
            raise ReleaseError("Canonical ZIP file order changed")
        for entry in archive.infolist():
            expected_flags = 0 if entry.filename.isascii() else 0x800
            if (
                entry.is_dir()
                or entry.date_time != CANONICAL_TIMESTAMP
                or entry.compress_type != zipfile.ZIP_STORED
                or entry.compress_size != entry.file_size
                or entry.create_system != 3
                or entry.create_version != 20
                or entry.extract_version != 20
                or entry.reserved != 0
                or entry.volume != 0
                or entry.internal_attr != 0
                or entry.external_attr != CANONICAL_FILE_MODE
                or entry.flag_bits != expected_flags
                or entry.extra != b""
                or entry.comment != b""
            ):
                raise ReleaseError("Canonical ZIP metadata mismatch: " + entry.filename)


def publish_exclusively(staged_paths, output_directory):
    # Exclusive creation also protects against another publisher winning after
    # the initial check. On failure remove only files created by this invocation.
    created = []
    try:
        for staged in staged_paths:
            destination = output_directory / staged.name
            with destination.open("xb") as target:
                created.append(destination)
                with staged.open("rb") as source:
                    shutil.copyfileobj(source, target)
                target.flush()
                os.fsync(target.fileno())
    except Exception:
        for path in reversed(created):
            try:
                path.unlink()
            except OSError:
                pass
        raise


def build_release(args):
    repository = git_output("rev-parse", "--show-toplevel").decode("utf-8").strip()
    object_type = git_output("-C", repository, "cat-file", "-t", args.source_ref).decode("ascii").strip()
    if object_type != "commit":
        raise ReleaseError("source-ref must identify a commit object, not a tag or tree")
    output = Path(args.output_dir).expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    names = [
        "Samsung-TV-Unlock-Local-Set-v" + args.version + "-Windows-x64.zip",
        "QN90B-Guide-v" + args.version + ".pdf",
        "SHA256SUMS.txt",
    ]
    existing = [name for name in names if os.path.lexists(output / name)]
    if existing:
        raise ReleaseError("Refusing to overwrite existing release assets: " + ", ".join(existing))

    with tempfile.TemporaryDirectory(prefix=".release-stage-", dir=output) as temporary:
        stage = Path(temporary)
        git_archive_path = stage / "source-git-archive.zip"
        archive_path = stage / names[0]
        with git_archive_path.open("xb") as destination:
            result = subprocess.run(
                ["git", "-C", repository, "archive", "--format=zip", "--prefix=" + PREFIX, args.source_ref],
                stdout=destination, stderr=subprocess.PIPE, check=False,
            )
        if result.returncode:
            raise ReleaseError("git archive failed: " + result.stderr.decode("utf-8", errors="replace").strip())

        # Validate the Git source before rewriting only ZIP container metadata.
        verify_archive(git_archive_path, args.source_ref, args.version)
        canonicalize_archive(git_archive_path, archive_path, args.source_ref)
        # The final published ZIP must pass all the original content checks too.
        guide, manifest_count, helper_count, pages = verify_archive(
            archive_path, args.source_ref, args.version
        )
        pdf_path = stage / names[1]
        pdf_path.write_bytes(guide)
        digest_lines = [sha256_file(path) + "  " + path.name for path in (archive_path, pdf_path)]
        sums_path = stage / names[2]
        sums_path.write_bytes(("\n".join(digest_lines) + "\n").encode("ascii"))
        paths = [archive_path, pdf_path, sums_path]
        assets = [
            {"filename": path.name, "size": path.stat().st_size, "sha256": sha256_file(path)}
            for path in paths
        ]
        publish_exclusively(paths, output)
        for asset in assets:
            published = output / asset["filename"]
            if published.stat().st_size != asset["size"] or sha256_file(published) != asset["sha256"]:
                raise ReleaseError("Published asset verification failed: " + asset["filename"])

    return {
        "success": True,
        "version": args.version,
        "sourceRef": args.source_ref,
        "archivePrefix": PREFIX,
        "packageManifestFilesVerified": manifest_count,
        "helperFilesVerified": helper_count,
        "guidePages": pages,
        "assets": assets,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source-ref", required=True, type=source_ref_arg)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--version", type=version_arg, default="1.0.2")
    args = parser.parse_args()
    try:
        summary = build_release(args)
    except (ReleaseError, OSError, UnicodeError, ValueError, zipfile.BadZipFile) as error:
        print("Release packaging failed: " + str(error), file=sys.stderr)
        return 1
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
