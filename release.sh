#!/usr/bin/env bash
# Build the release artifacts into dist/release/<version>/.
#
#   ./release.sh [--check] [--allow-dirty] [<version>] [target...]
#
# Targets are `linux`, `windows` and `flatpak`; all three run when none are
# named.
#
#   linux    tacky-linux-glibc<ver>  the GUI built in docker/Dockerfile's
#                                    Debian image, so it runs on any glibc at
#                                    least that old (`make linux`)
#   windows  tacky-windows.exe       the GUI cross-built in zippy's pinned
#                                    MinGW image (`make DOCKER=1 win-tacky`)
#   flatpak  tacky.flatpak           a single-file bundle, its runtime
#                                    fetched from flathub on install
#
# A SHA256SUMS over whatever is in the directory is rewritten at the end.
# Nothing is uploaded - the release page is a separate, deliberate step.
#
# <version> names the directory and is otherwise the tag's business: it
# defaults to the tag on HEAD, and to `git describe` for an untagged rehearsal.
# A version that is not the tag on HEAD is refused, so a directory called a0.5
# never holds something else's bytes.
#
# Every target builds HEAD. linux and windows build the working tree, which is
# why a dirty one is refused (--allow-dirty to rehearse anyway); the Flatpak builds
# HEAD's commit from GitHub, since flatpak-builder clones its sources, so HEAD
# has to be pushed there first. The manifest in flatpak/ follows main; the copy
# built here is pinned to the commit instead.
#
# Everything each selected target needs is checked before the first one builds,
# so a missing SDK does not surface after the linux leg has run. --check runs
# that and stops.
#
# Host requirements: docker for linux and windows; flatpak, flatpak-builder (or the
# org.flatpak.Builder app) and the freedesktop SDK the manifest names for the
# Flatpak.
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
cd "$root"

all_targets="linux windows flatpak"
manifest=flatpak/io.github.pounceandmiss.Tacky.yml
app_id=io.github.pounceandmiss.Tacky
app_repo=https://github.com/pounceandmiss/tacky.git
runtime_repo=https://dl.flathub.org/repo/flathub.flatpakrepo
work=build/release
logdir=$work/logs

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; $d'
}

die() { printf 'release.sh: %s\n' "$*" >&2; exit 1; }
note() { printf '\n== %s\n' "$*" >&2; }

# Logged to a file as well as the terminal, so a failure far into a build is
# still readable afterwards. pipefail keeps the build's status rather than
# tee's.
run_logged() {
    local name=$1; shift
    note "$name  (log: $logdir/$name.log)"
    "$@" 2>&1 | tee "$logdir/$name.log"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is not on PATH; needed for $2"
}

allow_dirty=0
check_only=0
version=
targets=

while [ "$#" -gt 0 ]; do
    case $1 in
        --check)       check_only=1 ;;
        --allow-dirty) allow_dirty=1 ;;
        -h|--help)     usage; exit 0 ;;
        -*)            die "unknown option $1" ;;
        linux|windows|flatpak) targets="$targets $1" ;;
        *[0-9]*)       [ -z "$version" ] || die "two versions given: $version and $1"
                       version=$1 ;;
        *)             die "unknown target $1 (want one of: $all_targets)" ;;
    esac
    shift
done
targets=${targets# }
[ -n "$targets" ] || targets=$all_targets

selected() { case " $targets " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# ---------------------------------------------------------------- preflight

preflight() {
    head=$(git rev-parse HEAD)

    local tag
    tag=$(git describe --exact-match --tags HEAD 2>/dev/null || true)
    if [ -n "$version" ]; then
        [ "$version" = "$tag" ] ||
            die "asked for $version but HEAD is ${tag:+tagged $tag}${tag:-untagged}; tag it first"
    elif [ -n "$tag" ]; then
        version=$tag
    else
        version=$(git describe --tags --always)
        # A warning, not an error: most runs are rehearsals, and the tag
        # lands once the artifacts are known good.
        note "HEAD is not tagged; building $version as a rehearsal"
    fi

    if [ "$allow_dirty" -eq 0 ]; then
        local dirty
        dirty=$(git status --porcelain)
        [ -z "$dirty" ] || die "the tree has uncommitted changes; commit them or pass --allow-dirty:
$dirty"
    fi

    [ -e zippy/zippy.mk ] ||
        die "zippy is empty; run  git submodule update --init --recursive"

    if selected linux; then
        need_cmd docker "the linux build, which builds entirely in docker/Dockerfile's image"
    fi

    if selected windows; then
        need_cmd docker "the windows build, which builds entirely in zippy's mingw image"
    fi

    if selected flatpak; then
        need_cmd flatpak "the Flatpak"
        if command -v flatpak-builder >/dev/null 2>&1; then
            builder=(flatpak-builder)
        elif flatpak info org.flatpak.Builder >/dev/null 2>&1; then
            builder=(flatpak run org.flatpak.Builder)
        else
            die "no flatpak-builder; install it, or  flatpak install flathub org.flatpak.Builder"
        fi

        local rv
        rv=$(sed -n "s/^runtime-version: *'\{0,1\}\([^']*\)'\{0,1\}$/\1/p" "$manifest")
        [ -n "$rv" ] || die "no runtime-version in $manifest"
        local ref
        for ref in org.freedesktop.Sdk//"$rv" org.freedesktop.Platform//"$rv"; do
            flatpak info "$ref" >/dev/null 2>&1 ||
                die "$ref is not installed; flatpak install flathub $ref"
        done

        # The sandboxed build cannot fetch, so a dep missing from the manifest
        # fails there - after every other source has downloaded.
        flatpak/sync-sources.sh --check

        # --allow-dirty can't reach this one: the Flatpak only ever sees what
        # GitHub has.
        git fetch -q "$app_repo" main ||
            die "could not fetch main from $app_repo"
        git merge-base --is-ancestor "$head" FETCH_HEAD ||
            die "HEAD ($head) is not on GitHub's main; push it first - the Flatpak builds from there"
        if [ "$allow_dirty" -eq 1 ] && [ -n "$(git status --porcelain)" ]; then
            note "the tree is dirty; the Flatpak builds $head without those changes"
        fi
    fi

    out=dist/release/$version
}

# ------------------------------------------------------------------ targets

build_linux() {
    # Last run's binaries would otherwise survive a failed export and get
    # picked up below.
    rm -f dist/*-glibc*
    run_logged linux make linux
    local bin
    bin=$(find dist -maxdepth 1 -name 'tacky-glibc*' -printf '%P\n')
    [ -n "$bin" ] || die "make linux left no dist/tacky-glibc*"
    cp "dist/$bin" "$out/tacky-linux-${bin#tacky-}"
}

build_windows() {
    # DOCKER=1 rather than a host mingw: the release is built by the pinned
    # toolchain, not whichever gcc this machine has. It gets a tree of its own
    # (build/windows-docker), so a host build never leaks into it.
    rm -f dist/tacky.exe
    run_logged windows make DOCKER=1 win-tacky
    [ -f dist/tacky.exe ] || die "make DOCKER=1 win-tacky left no dist/tacky.exe"
    cp dist/tacky.exe "$out/tacky-windows.exe"
}

build_flatpak() {
    local fw=$work/flatpak
    rm -rf "$fw"
    mkdir -p "$fw"
    cp flatpak/$app_id.desktop flatpak/$app_id.metainfo.xml "$fw/"

    # The app source pinned to HEAD rather than main, so what is built is what
    # was checked above even if main moves on mid-build.
    awk -v repo="$app_repo" -v head="$head" '
        prev && $0 ~ /^ *branch: main$/ { sub(/branch: main/, "commit: " head); n++ }
        { prev = ($0 ~ "url: " repo "$"); print }
        END { if (n != 1) exit 1 }
    ' "$manifest" > "$fw/$app_id.yml" ||
        die "no 'branch: main' under $app_repo in $manifest to pin"

    # No --disable-updates, unlike `make flatpak`: a release refetches rather
    # than trust a mirror. The state dir is the dev builds' all the same, so
    # unchanged sources and ccache carry over.
    run_logged flatpak "${builder[@]}" --user --ccache --force-clean \
        --state-dir="$root/flatpak/.flatpak-builder" \
        --repo="$fw/repo" "$fw/build-dir" "$fw/$app_id.yml"
    flatpak build-bundle --runtime-repo="$runtime_repo" \
        "$fw/repo" "$out/tacky.flatpak" "$app_id" master
}

# -------------------------------------------------------------------- drive

mkdir -p "$logdir"
preflight

if [ "$check_only" -eq 1 ]; then
    note "tacky $version: $targets - everything needed is in place"
    exit 0
fi

mkdir -p "$out"
note "tacky $version ($head): $targets"
for t in $all_targets; do
    if selected "$t"; then "build_$t"; fi
done

( cd "$out" && rm -f SHA256SUMS &&
  find . -maxdepth 1 -type f -printf '%P\n' | sort | xargs -r sha256sum > SHA256SUMS )

note "$out/"
ls -lh "$out" | grep -v '^total'
printf '\nUpload these to the release page for %s.\n' "$version" >&2
