#!/bin/bash
# Keep only the Bazel disk-cache entries this build used.
#
#   ci/bazel_cache_prune.sh <cache_dir> <marker_file> [--dry-run]
#
# <marker_file> is touched right before the build. Bazel updates the mtime of a disk-cache entry
# when it reads or writes it, so every file not newer than the marker was not used by this build.
# Without pruning the cache only grows (bazel-master-* went 3.9 -> 8.0 GB in two days) and the two
# caches no longer fit the repo's 10 GB, so GitHub evicts one and the next builds start cold.
#
# Safety: if pruning would keep less than a quarter of the cache, nothing is deleted (that would
# mean Bazel did not refresh mtimes, and deleting would throw the hits away).
set -euo pipefail

dir=${1:?cache dir}
marker=${2:?marker file}
mode=${3:-}

if [ ! -d "$dir" ] || [ ! -f "$marker" ]; then
  echo "no cache dir or marker; nothing to prune"
  exit 0
fi

kb_of() { awk '{s += $1} END {print s + 0}'; }
total_kb=$(find "$dir" -type f -exec du -k {} + | kb_of)
stale_kb=$(find "$dir" -type f ! -newer "$marker" -exec du -k {} + | kb_of)
stale_files=$(find "$dir" -type f ! -newer "$marker" | wc -l | tr -d ' ')
keep_kb=$((total_kb - stale_kb))
mb() { echo "$(( $1 / 1024 )) MB"; }

summary="bazel cache $(basename "$dir"): total $(mb "$total_kb"), used by this build $(mb "$keep_kb"), stale $(mb "$stale_kb") in $stale_files files"
echo "$summary"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$summary${mode:+ ($mode)}" >> "$GITHUB_STEP_SUMMARY"

if [ "$total_kb" -gt 0 ] && [ $((keep_kb * 4)) -lt "$total_kb" ]; then
  echo "::warning::only $(mb "$keep_kb") of $(mb "$total_kb") looks used; not pruning"
  exit 0
fi
if [ "$mode" = "--dry-run" ]; then
  echo "dry run: nothing deleted"
  exit 0
fi

find "$dir" -type f ! -newer "$marker" -delete
find "$dir" -mindepth 1 -type d -empty -delete
echo "pruned; cache is now $(du -sh "$dir" | cut -f1)"
