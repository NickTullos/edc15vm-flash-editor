#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: build/build-release.sh [options]

Build self-contained release bundles for macOS, Linux, and Windows.

Options:
  --configuration <Debug|Release>   Build configuration (default: Release)
  --framework <tfm>                 Target framework (default: net7.0)
  --skip-tests                      Skip running dotnet test before publish
  -h, --help                        Show this help text
EOF
}

CONFIGURATION="Release"
FRAMEWORK="net7.0"
RUN_TESTS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --configuration)
      CONFIGURATION="${2:?Missing value for --configuration}"
      shift 2
      ;;
    --framework)
      FRAMEWORK="${2:?Missing value for --framework}"
      shift 2
      ;;
    --skip-tests)
      RUN_TESTS=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOLUTION="$REPO_ROOT/ALHFlashTool.sln"
PROJECT="$REPO_ROOT/src/ALHFlash.Tool/ALHFlash.Tool.csproj"
PROFILES_DIR="$REPO_ROOT/profiles"
README_FILE="$REPO_ROOT/README.md"

DIST_ROOT="$SCRIPT_DIR/dist"
PUBLISH_ROOT="$SCRIPT_DIR/publish"
TMP_ROOT="$SCRIPT_DIR/tmp"

TARGETS=(
  "macos-arm64|osx-arm64|zip|Modern M Series Macs|macOS arm64 zip"
  "macos-x64|osx-x64|zip|Older Legacy Macs|macOS x64 zip"
  "linux-x64|linux-x64|tar.gz|Most Common Linux|Linux x64 tar.gz"
  "linux-arm64|linux-arm64|tar.gz|ARM Linux|Linux arm64 tar.gz"
  "windows-x64|win-x64|zip|Most Common Windows|Windows x64 zip"
  "windows-arm64|win-arm64|zip|ARM Windows|Windows arm64 zip"
)

log() {
  printf '[build] %s\n' "$*"
}

die() {
  printf '[build] ERROR: %s\n' "$*" >&2
  exit 1
}

command -v dotnet >/dev/null 2>&1 || die "dotnet is required but was not found on PATH"
command -v python3 >/dev/null 2>&1 || die "python3 is required but was not found on PATH"

[[ -f "$SOLUTION" ]] || die "Could not find solution file at $SOLUTION"
[[ -f "$PROJECT" ]] || die "Could not find project file at $PROJECT"
[[ -d "$PROFILES_DIR" ]] || die "Could not find profiles directory at $PROFILES_DIR"

mkdir -p "$DIST_ROOT" "$PUBLISH_ROOT" "$TMP_ROOT"

VERSION_TAG="$(
  cd "$REPO_ROOT"
  git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null || true
)"

[[ -n "$VERSION_TAG" ]] || die "No SemVer tag found. Create a release tag like v1.0.0 before building."

VERSION_RAW="${VERSION_TAG#v}"
VERSION_SAFE="$(printf '%s' "$VERSION_RAW" | tr ' /' '__' | tr -cd '[:alnum:]._+-')"
COMMIT_SHA="$(cd "$REPO_ROOT" && git rev-parse HEAD)"
BUILD_TIME_UTC="$(python3 - <<'PY'
from datetime import datetime, timezone
print(datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"))
PY
)"

log "Repository root: $REPO_ROOT"
log "Version tag: $VERSION_TAG"
log "Version: $VERSION_RAW"
log "Commit: $COMMIT_SHA"
log "Configuration: $CONFIGURATION"
log "Framework: $FRAMEWORK"

update_readme_downloads() {
  local readme_path="$1"
  python3 - "$readme_path" "$VERSION_SAFE" "${TARGETS[@]}" <<'PY'
import pathlib
import sys

readme_path = pathlib.Path(sys.argv[1])
version_safe = sys.argv[2]
raw_targets = sys.argv[3:]

targets = []
for item in raw_targets:
    label, rid, archive_ext, display_label, link_label = item.split('|')
    targets.append((label, rid, archive_ext, display_label, link_label))

text = readme_path.read_text(encoding='utf-8')
start_marker = '## Downloads\n'
end_marker = '\nThe tool never edits the original file in place.'
start = text.find(start_marker)
if start == -1:
    raise SystemExit('Could not find README Downloads section.')
start += len(start_marker)
end = text.find(end_marker, start)
if end == -1:
    raise SystemExit('Could not find README Downloads section terminator.')

replacement_lines = ['']
for label, _rid, archive_ext, display_label, link_label in targets:
    archive_name = f'ALHFlashTool-{version_safe}-{label}.{archive_ext}'
    replacement_lines.append(f'- {display_label} [{link_label}](build/dist/{archive_name})')

replacement = '\n'.join(replacement_lines) + '\n'
updated = text[:start] + replacement + text[end:]
if updated != text:
    readme_path.write_text(updated, encoding='utf-8')
PY
}

update_readme_downloads "$README_FILE"

if [[ "$RUN_TESTS" -eq 1 ]]; then
  log "Running tests"
  dotnet test "$SOLUTION" -c "$CONFIGURATION"
else
  log "Skipping tests"
fi

copy_support_files() {
  local target_dir="$1"
  mkdir -p "$target_dir/original"
  mkdir -p "$target_dir/modified"
  mkdir -p "$target_dir/profiles"
  cp -R "$PROFILES_DIR"/. "$target_dir/profiles/"
  cp "$README_FILE" "$target_dir/README.md"
}

publish_target() {
  local label="$1"
  local rid="$2"
  local archive_ext="$3"
  local stage_dir="$PUBLISH_ROOT/$label"
  local archive_name="ALHFlashTool-${VERSION_SAFE}-${label}.${archive_ext}"
  local archive_path="$DIST_ROOT/$archive_name"

  log "Publishing $label ($rid)"
  rm -rf "$stage_dir"
  mkdir -p "$stage_dir"

  dotnet publish "$PROJECT" \
    -c "$CONFIGURATION" \
    -f "$FRAMEWORK" \
    -r "$rid" \
    --self-contained true \
    -p:PublishSingleFile=true \
    -p:IncludeNativeLibrariesForSelfExtract=true \
    -p:PublishTrimmed=false \
    -p:EnableCompressionInSingleFile=true \
    -p:DebugType=None \
    -p:DebugSymbols=false \
    -o "$stage_dir"

  copy_support_files "$stage_dir"

  log "Archiving $label"
  python3 - "$stage_dir" "$archive_path" "$archive_ext" <<'PY'
import os
import pathlib
import sys
import tarfile
import zipfile

source_dir = pathlib.Path(sys.argv[1])
archive_path = pathlib.Path(sys.argv[2])
archive_ext = sys.argv[3]

def iter_files(base: pathlib.Path):
    for path in sorted(base.rglob('*')):
        if path.is_file():
            yield path

def iter_dirs(base: pathlib.Path):
    dirs = [path for path in sorted(base.rglob('*')) if path.is_dir()]
    yield base
    for path in dirs:
        yield path

if archive_ext == 'zip':
    with zipfile.ZipFile(archive_path, 'w', compression=zipfile.ZIP_DEFLATED) as zf:
        for dir_path in iter_dirs(source_dir):
            rel = dir_path.relative_to(source_dir).as_posix()
            if rel == '.':
                continue
            zf.writestr(rel.rstrip('/') + '/', '')
        for file_path in iter_files(source_dir):
            zf.write(file_path, file_path.relative_to(source_dir).as_posix())
elif archive_ext == 'tar.gz':
    with tarfile.open(archive_path, 'w:gz') as tf:
        for dir_path in iter_dirs(source_dir):
            rel = dir_path.relative_to(source_dir).as_posix()
            if rel == '.':
                continue
            tf.add(dir_path, arcname=rel, recursive=False)
        for file_path in iter_files(source_dir):
            tf.add(file_path, arcname=file_path.relative_to(source_dir).as_posix())
else:
    raise SystemExit(f'Unsupported archive type: {archive_ext}')
PY

  local archive_sha256
  archive_sha256="$(python3 - "$archive_path" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
with path.open('rb') as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b''):
        digest.update(chunk)
print(digest.hexdigest())
PY
)"

  printf '%s\t%s\t%s\t%s\n' "$label" "$rid" "$archive_name" "$archive_sha256" >> "$TMP_ROOT/release-artifacts.tsv"
  log "Wrote $archive_name"
}

: > "$TMP_ROOT/release-artifacts.tsv"

for target in "${TARGETS[@]}"; do
  IFS='|' read -r label rid archive_ext _display_label _link_label <<< "$target"
  publish_target "$label" "$rid" "$archive_ext"
done

log "Writing manifest"
python3 - "$TMP_ROOT/release-artifacts.tsv" "$DIST_ROOT/release-manifest.json" "$VERSION_TAG" "$VERSION_RAW" "$VERSION_SAFE" "$COMMIT_SHA" "$BUILD_TIME_UTC" "$CONFIGURATION" "$FRAMEWORK" <<'PY'
import json
import pathlib
import sys

records_path = pathlib.Path(sys.argv[1])
manifest_path = pathlib.Path(sys.argv[2])
version_tag = sys.argv[3]
version_raw = sys.argv[4]
version_safe = sys.argv[5]
commit_sha = sys.argv[6]
build_time_utc = sys.argv[7]
configuration = sys.argv[8]
framework = sys.argv[9]

artifacts = []
for line in records_path.read_text().splitlines():
    if not line.strip():
        continue
    label, rid, archive_name, sha256 = line.split('\t')
    artifacts.append({
        'label': label,
        'rid': rid,
        'archive': archive_name,
        'sha256': sha256,
    })

manifest = {
    'app': 'ALHFlashTool',
    'versionTag': version_tag,
    'version': version_raw,
    'versionSafe': version_safe,
    'commit': commit_sha,
    'buildTimeUtc': build_time_utc,
    'configuration': configuration,
    'framework': framework,
    'artifacts': artifacts,
}

manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
PY

log "Release bundles are ready in $DIST_ROOT"
