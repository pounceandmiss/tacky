#!/usr/bin/env bash
# Rewrite the manifest's zippy dep sources from zippy.mk's pins.
#
#   flatpak/sync-sources.sh [--check]
#
# Everything below the manifest's "generated below this line" marker is
# replaced with `make flatpak-sources`. --check changes nothing and fails if
# the rewrite would, which is how release.sh finds a stale manifest in seconds
# rather than an hour into a sandboxed build that cannot fetch what it lacks.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
manifest=$root/flatpak/io.github.pounceandmiss.Tacky.yml
marker='# ---- generated below this line ----'

check=0
case ${1-} in
    --check) check=1 ;;
    '') ;;
    *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

grep -qF -- "$marker" "$manifest" || {
    echo "sync-sources.sh: no '$marker' line in $manifest" >&2; exit 1; }

sources=$(make -s -C "$root" flatpak-sources)
[ -n "$sources" ] || { echo "sync-sources.sh: make flatpak-sources printed nothing" >&2; exit 1; }

new=$(awk -v m="$marker" '{ print } index($0, m) { exit }' "$manifest"; printf '%s\n' "$sources")

if [ "$check" -eq 1 ]; then
    if ! diff -u "$manifest" <(printf '%s\n' "$new") >&2; then
        echo "sync-sources.sh: the manifest's dep sources are stale; run flatpak/sync-sources.sh and commit" >&2
        exit 1
    fi
    exit 0
fi

printf '%s\n' "$new" > "$manifest"
