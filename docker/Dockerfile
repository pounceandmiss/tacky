# syntax=docker/dockerfile:1.7
# Portable Linux build for Tacky.
#
# Builds the native binaries against Debian bookworm's glibc 2.36 so they run on
# distros older than the Arch host (which links glibc 2.43). zippy compiles its
# own Tcl/Tk and every C dep from source, so the only host requirements are a
# C/C++ toolchain, cmake, git and the X11 dev libs Tk/tkdnd link against.
#
# Driven by `make linux`, which exports the binaries to dist/ via docker build
# --output. The in-image build/ tree lives on a BuildKit cache mount and never
# touches the host's Arch-built build/.

FROM debian:bookworm AS build

# zip: Tk's configure uses the system zip(1) to assemble its zipfs archive;
# without it Tk falls back to a bundled "minizip" it can't build and the make
# dies with "No rule to make target 'minizip'".
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential cmake git curl file zip ca-certificates pkg-config \
        zlib1g-dev libx11-dev libxext-dev libxss-dev libxft-dev \
        libxcursor-dev libfontconfig-dev ccache \
    && rm -rf /var/lib/apt/lists/*

# Transparent ccache: its compiler shims shadow gcc/g++/cc so even the cmake
# deps get cached across rebuilds (the cache itself is the BuildKit mount below).
ENV PATH=/usr/lib/ccache:$PATH

WORKDIR /src
COPY . .

# build/ holds the dep checkouts and compiled objects; caching the whole tree
# gives incremental make across rebuilds. dist/ is a real layer (cache mounts
# don't persist into the image), so the binaries survive into export. Tag each
# with the image's glibc - the minimum a host needs to run it.
RUN --mount=type=cache,target=/src/build \
    --mount=type=cache,target=/root/.cache/ccache \
    make all \
    && ver=$(getconf GNU_LIBC_VERSION | awk '{print $2}') \
    && for b in tacky tackyd tackyd-json; do mv dist/$b dist/$b-glibc$ver; done

FROM scratch AS export
COPY --from=build /src/dist/*-glibc* /
