# ==== Shared config ====
# The build system, a submodule by default; a checkout elsewhere (a worktree
# of zippy under development, say) is named with ZIPPY=path.
ZIPPY ?= zippy

# dist/ is what CMake and the other consumers import, so an archive that comes
# out byte-identical has to keep its mtime: a fresh one makes every dependent
# relink for nothing, and this build is link-bound. cmp on a warm file costs
# milliseconds against the tens of megabytes the copy would move.
copy-if-changed = cmp -s $(1) $(2) || cp $(1) $(2)

COMMON_DEPS := tdom mtls tcllib rtc rtcma rtcmv omemo tclwuffs
COMMON_EXCL := build dist tests doc test_all.tcl test_gui.tcl \
               README.md LICENSE cleanup.resume zippy Makefile .git .gitignore

# zippy wires up only tkdnd's X11 XDND backend and errors out on TARGET_OS=macos;
# without it the GUI just loses drag-to-send. The mac targets name that target
# outright; the native ones only hit it when the host is the Mac, and every
# other cross-build keeps tkdnd.
MACOS_DEPS_EXCL := tkdnd
macos-deps = $(filter-out $(MACOS_DEPS_EXCL),$(1))

ifeq ($(shell uname -s),Darwin)
  NATIVE_DEPS_EXCL := $(MACOS_DEPS_EXCL)
endif
native-deps = $(filter-out $(NATIVE_DEPS_EXCL),$(1))

# No Tk video view on Windows. rtcmv builds without a camera there: receive-only.
WIN_DEPS_EXCL := rtcmv_tk
win-deps = $(filter-out $(WIN_DEPS_EXCL),$(1))

# Android has no Tk. rtcmv builds without a camera there: receive-only.
ANDROID_DEPS_EXCL := rtcmv_tk
android-deps = $(filter-out $(ANDROID_DEPS_EXCL),$(1))

# ==== Per-binary config ====

tacky_SHELL := wish
tacky_DEPS  := $(COMMON_DEPS) tkwuffs tkdnd rtcmv_tk
tacky_SRC   := lib bin gui
tacky_ENT   := bin/tacky.tcl
tacky_ICON  := gui/icons/tacky.ico

tackyd_SHELL := tclsh
tackyd_DEPS  := $(COMMON_DEPS)
tackyd_SRC   := lib bin
tackyd_ENT   := bin/tackyd.tcl

tackyd-json_SHELL := tclsh
tackyd-json_DEPS  := $(COMMON_DEPS)
tackyd-json_SRC   := lib bin
tackyd-json_ENT   := bin/tackyd-json.tcl

# The browser backend (see `wasm` below). The same sources as libtacky.a, and
# a shorter dep list: no mtls, rtc*, tclwuffs - a page's TLS, WebRTC and
# image decoding are the browser's, and the modules that used them require
# them only where they are used.
wasm_DEPS := tdom tcllib omemo

# ==== Targets ====

.PHONY: all \
	tacky tackyd tackyd-json lib \
	win win-tacky win-tackyd win-tackyd-json win-lib win-clean \
	mac mac-guard mac-tacky mac-tackyd mac-tackyd-json mac-lib mac-clean \
        android android-lib \
	wasm wasm-tcltest wasm-test wasm-test-browser wasm-serve \
	linux webrtc-so android-webrtc-so win-webrtc-dll flatpak flatpak-bundle flatpak-install \
        test test-gui test-gui-headless test-lib tools wish tclsh clean dist-dir

all: tacky tackyd tackyd-json

# The three native binaries share one build tree so the heavy deps
# (libdatachannel etc.) compile once, not once per binary; binaries 2 and 3 just
# reuse the dep stamps in the shared PREFIX. Every other platform gets its own
# tree (below), and each tree belongs to one toolchain, so no two ever share
# compiled artifacts.
LINUX_BUILD := $(CURDIR)/build/linux
# The mac targets are native (see mac-guard), so on a Mac they and the plain
# build are the same compiler against the same deps - one tree serves both, and
# `make mac` after a dev build is a relink rather than a second WebRTC build.
MAC_BUILD   := $(LINUX_BUILD)

# One source cache shared by the native and Windows trees. zippy defaults
# DEPSDIR to $(BASEDIR)/_build/deps, which would give each target here its own
# copy of every dep; the sources are platform-neutral and compiled output still
# isolates by BASEDIR.
#
# Android is excluded: omemo and tclwuffs have no out-of-tree build and zippy
# only redirects them to an isolated copy under WIN, so an android build would
# leave its objects in the shared checkout.
DEPS_DIR := $(CURDIR)/build/deps

tacky tackyd tackyd-json: %: dist-dir
	$(MAKE) -f $(ZIPPY)/zippy.mk \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$(call native-deps,$($*_DEPS))" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=$(LINUX_BUILD) \
	    DEPSDIR=$(DEPS_DIR) \
	    app
	$(call copy-if-changed,$(LINUX_BUILD)/$*,dist/$*)

# libtacky.a: the taco backend as a linked C library (embed/tacky.c drives the
# interp on a private thread; see embed/tacky.h). Same deps/sources as the
# tackyd-json daemon, but with no entry script - the shim, not a main.tcl, runs
# the show. Shares the native build tree so it reuses the already-built deps.
lib: dist-dir
	$(MAKE) -f $(ZIPPY)/zippy.mk \
	    SHELL_TYPE=tclsh \
	    DEPS="$(tackyd-json_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(CURDIR)/embed/tacky.c \
	    LIB_NAME=tacky \
	    BASEDIR=$(LINUX_BUILD) \
	    DEPSDIR=$(DEPS_DIR) \
	    lib
	$(call copy-if-changed,$(LINUX_BUILD)/libtacky.a,dist/libtacky.a)

# dist/wasm/: the taco backend for a browser, and everything a page needs to
# use it, in one directory to copy onto a site. embed/tacky_wasm.c drives the
# interpreter; wasm/src/ is the page's side of it, and the files locate each
# other relative to their own URLs so the directory can live anywhere on the
# origin.
#
#   tacky.mjs, tacky.wasm   the backend
#   worker.js               the Web Worker it runs in
#   opfs-pool.js            the storage pool, opened before the interpreter
#   client.js, media-host.js, index.js   what a page imports
#   index.d.ts, package.json             the contract: its types and version
#
# The directory is an npm package as it stands (`npm pack dist/wasm`), though
# it is not published; the manifest is there so the surface has a version and
# a consumer has types. wasm/src/index.d.ts is that surface: a change to it is
# a change to the version in wasm/src/package.json.
#
# The build itself is the same shape as libtacky.a - zippy's `lib` target with
# the emscripten overlay, then one emcc link here - in its own tree, like every
# other platform. EXPORTED_FUNCTIONS is what pulls the shim out of the archive:
# the linker roots on them, and EMSCRIPTEN_KEEPALIVE alone does not make an
# archive member a root.
#
#   make wasm            emcc on PATH                -> build/wasm/
#   make DOCKER=1 wasm   zippy's pinned emsdk image  -> build/wasm-docker/
#
# A tree belongs to one toolchain, so the two never share one: emcc's output
# moves between releases, and a distro package moves under you. Separate
# BASEDIRs do it rather than a docker cache mount (IN_DOCKER_BUILD_SUBDIR=
# turns that off), so the container tree stays under build/ for `make clean`.
# Under DOCKER=1 the inner make and the final link both run in the container at
# /src, so BASEDIR, the shim path and HOST_TCLSH (the image's tcl9.0) are
# container paths - and ZIPPY has to be inside the project, since only the
# project is mounted. That is the submodule's own path, so only a zippy
# checked out elsewhere (ZIPPY=../zippy-wasm) has to build without docker.
ifdef DOCKER
  WASM_BUILD := build/wasm-docker
  WASM_MAKE  := IN_DOCKER_BUILD_SUBDIR= \
                IN_DOCKER_CCACHE_DIR=/src/$(WASM_BUILD)/.ccache \
                $(ZIPPY)/in_docker.sh emsdk make
  WASM_EMCC  := IN_DOCKER_BUILD_SUBDIR= $(ZIPPY)/in_docker.sh emsdk emcc
  WASM_ROOT  := /src
  WASM_TCLSH := /usr/local/bin/tclsh9.0
else
  WASM_BUILD := build/wasm
  WASM_MAKE  := $(MAKE)
  WASM_EMCC  := emcc
  WASM_ROOT  := $(CURDIR)
  # Reuse the native tree's when it is there; otherwise say nothing and let
  # zippy build its own (emscripten.mk's NATIVE_TCLSH).
  WASM_TCLSH := $(wildcard $(LINUX_BUILD)/_build/local/bin/tclsh9.0)
endif
WASM_DIST  := dist/wasm
# The shared dep cache from whichever root the inner make sees: under DOCKER=1
# that is the container's /src, not the host's $(CURDIR).
WASM_DEPS_DIR := $(WASM_ROOT)/build/deps

# `wasm` and `wasm-tcltest` share one build tree, so Tcl and the deps are built
# once - but they also share its scripts.zip, and the two want different
# contents: one excludes tests/, the other carries it. zippy.mk derives the zip
# from the source files alone, so make cannot see that the excludes changed and
# would hand whichever target runs second the other one's zip. Dropping it
# costs the seconds it takes to rebuild, and is the difference between shipping
# the whole test suite inside dist/wasm/tacky.wasm and not.
WASM_DROP_ZIP = rm -f $(WASM_BUILD)/_build-emscripten/scripts.zip \
	               $(WASM_BUILD)/_build-emscripten/scripts.o
-include $(ZIPPY)/emscripten/link.mk
wasm: dist-dir
	mkdir -p $(WASM_BUILD)
	$(WASM_DROP_ZIP)
	$(WASM_MAKE) -f $(ZIPPY)/zippy.mk TARGET_OS=emscripten \
	    SHELL_TYPE=tclsh \
	    DEPS="$(wasm_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(WASM_ROOT)/embed/tacky_wasm.c \
	    LIB_NAME=tacky \
	    BASEDIR=$(WASM_ROOT)/$(WASM_BUILD) \
	    DEPSDIR=$(WASM_DEPS_DIR) \
	    $(if $(WASM_TCLSH),HOST_TCLSH=$(WASM_TCLSH),) \
	    lib
	mkdir -p $(WASM_DIST)
	cp $(ZIPPY)/emscripten/opfs-pool.js wasm/src/*.js wasm/src/index.d.ts wasm/src/package.json $(WASM_DIST)/
	$(WASM_EMCC) -O2 -o $(WASM_DIST)/tacky.mjs $(WASM_BUILD)/libtacky.a $(ZIPPY_EM_LDFLAGS) \
	    -sEXPORT_NAME=createTacky \
	    -sEXPORTED_FUNCTIONS=_tacky_boot,_tacky_start,_tacky_persist,_tacky_run,_opfsvfs_register

# build/wasm/tacky-tcltest.mjs: the same interpreter with tacky's own Tcl test
# suite bundled beside lib/, driven through zippy_eval. Tacky has hundreds of
# tests; running those in wasm says far more about the port than anything
# written again in JavaScript, and says it about the code that ships.
#
# Same build tree as `wasm`, so the deps are shared; the script zip differs
# (it carries tests/), so switching between the two targets rebuilds it - see
# WASM_DROP_ZIP.
WASM_TEST_EXCL := $(filter-out tests test_all.tcl,$(COMMON_EXCL))
wasm-tcltest: $(WASM_BUILD)/tacky-tcltest.mjs

.PHONY: $(WASM_BUILD)/tacky-tcltest.mjs
$(WASM_BUILD)/tacky-tcltest.mjs:
	mkdir -p $(WASM_BUILD)
	$(WASM_DROP_ZIP)
	$(WASM_MAKE) -f $(ZIPPY)/zippy.mk TARGET_OS=emscripten \
	    SHELL_TYPE=tclsh \
	    DEPS="$(wasm_DEPS)" \
	    SOURCES="lib bin tests" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(WASM_TEST_EXCL)" \
	    BIN_NAME=tacky-tcltest \
	    BASEDIR=$(WASM_ROOT)/$(WASM_BUILD) \
	    DEPSDIR=$(WASM_DEPS_DIR) \
	    $(if $(WASM_TCLSH),HOST_TCLSH=$(WASM_TCLSH),) \
	    app

# The two builds must not run at once - one build tree, one scripts.zip.
.NOTPARALLEL: wasm wasm-tcltest

XMPP_WS_URL ?= ws://127.0.0.1:5280/xmpp-websocket

# The wasm suite under node: the JSON protocol in and out of the backend, the
# same backend on the OPFS pool a browser gives it across a simulated reload
# (that one needs zippy's mock OPFS directory, hence $(ZIPPY)), then tacky's
# own Tcl tests inside the wasm interpreter.
#
# The networked half joins in when a server is up, the way test_all.tcl picks
# up tests/taco_integration - so run it the same way:
#
#   tests/servers/with_prosody.sh make wasm-test
#
# which adds an XMPP session over RFC 7395, XEP-0363 up and down over the
# browser's own HTTP stack, and the integration suite over the WebSocket.
#
# Each check runs even if an earlier one failed, and the target fails at the
# end if any did - a suite that stops at the first failure tells you least
# when you most want the rest of it.
WASM_NET_CHECKS :=
WASM_NET_BROWSER_CHECKS :=
ifdef XMPP_SERVER
WASM_NET_CHECKS := \
	node wasm/test/xmpp.mjs || rc=1; \
	node wasm/test/http.mjs || rc=1; \
	XMPP_WS_URL=$(XMPP_WS_URL) node wasm/test/tcl.mjs \
	    $(WASM_BUILD)/tacky-tcltest.mjs --dir taco_integration || rc=1;
WASM_NET_BROWSER_CHECKS := \
	node wasm/test/browser.mjs --scenario session || rc=1; \
	node wasm/test/browser.mjs --scenario call || rc=1;
endif

wasm-test: wasm wasm-tcltest
	@rc=0; \
	node wasm/test/host.mjs $(WASM_DIST)/tacky.mjs || rc=1; \
	node wasm/test/opfs.mjs $(WASM_DIST)/tacky.mjs $(ZIPPY) || rc=1; \
	node wasm/test/tcl.mjs $(WASM_BUILD)/tacky-tcltest.mjs --dir taco || rc=1; \
	$(WASM_NET_CHECKS) \
	exit $$rc

# The same thing where none of it is simulated: a module Worker, postMessage,
# and the browser's own OPFS, visited twice so the second page finds what the
# first stored. Needs chromium on PATH (CHROMIUM=... to name another). Under
# with_prosody.sh it also places a call, with the media half in the page.
wasm-test-browser: wasm wasm-tcltest
	@rc=0; \
	node wasm/test/browser.mjs || rc=1; \
	node wasm/test/browser.mjs --scenario tcl || rc=1; \
	$(WASM_NET_BROWSER_CHECKS) \
	exit $$rc

# The same smoke page, to open in your own browser.
wasm-serve: wasm
	node wasm/test/serve.mjs 8099 $(WASM_DIST) wasm/test

# zippy has no mac-app/.dmg target - TARGET_OS=macos just retargets `app`.
# It is also not a cross target: it leaves CROSS_OVERLAY unset and builds with
# the host toolchain, so off a Mac these would emit a Linux binary under a
# -macos name rather than fail. The mac targets exist for the platform-suffixed
# dist artifacts (dist/libtacky-macos.a has no other producer); a Mac dev builds
# and tests through the native targets above.
mac-guard:
	@[ "$$(uname -s)" = Darwin ] || { \
	    echo "make: macOS builds are native; run this on a Mac" >&2; exit 1; }

mac: mac-tacky mac-tackyd mac-tackyd-json

mac-tacky mac-tackyd mac-tackyd-json: mac-%: mac-guard dist-dir
	$(MAKE) -f $(ZIPPY)/zippy.mk \
	    TARGET_OS=macos \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$(call macos-deps,$($*_DEPS))" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=$(MAC_BUILD) \
	    DEPSDIR=$(DEPS_DIR) \
	    app
	$(call copy-if-changed,$(MAC_BUILD)/$*,dist/$*-macos)

mac-lib: mac-guard dist-dir
	$(MAKE) -f $(ZIPPY)/zippy.mk \
	    TARGET_OS=macos \
	    SHELL_TYPE=tclsh \
	    DEPS="$(tackyd-json_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(CURDIR)/embed/tacky.c \
	    LIB_NAME=tacky \
	    BASEDIR=$(MAC_BUILD) \
	    DEPSDIR=$(DEPS_DIR) \
	    lib
	$(call copy-if-changed,$(MAC_BUILD)/libtacky.a,dist/libtacky-macos.a)

# The mac build shares the native tree, so this drops only the macOS dist
# outputs; `clean` handles the tree itself.
mac-clean:
	rm -f dist/*-macos dist/*-macos.a dist/*-macos.debug

# ==== Windows cross-build ====
# Static .exe binaries via MinGW-w64 (zippy/windows.mk). Same per-binary config
# as the native build; TARGET_OS=windows swaps in the win/ recipes and bundles
# with a host tclsh9.0. The three binaries share one tree (deps compile once),
# kept separate from build/linux so ELF/PE artifacts never cross; ships $*.exe.
#
#   make win            host mingw-w64 (Arch: gcc 16)  -> build/windows/
#   make DOCKER=1 win   zippy's pinned mingw profile   -> build/windows-docker/
#
# A tree belongs to one toolchain: a gcc 16 object wants libgcc symbols gcc 12's
# runtime lacks, and a shared _build-win would link that with nothing reporting
# it. Separate BASEDIRs do it, not a docker cache mount (IN_DOCKER_BUILD_SUBDIR=
# turns it off), so the container tree stays under build/ for `make clean`.
# Under DOCKER=1 the inner make runs at /src, so BASEDIR, the shim/icon paths and
# HOST_TCLSH (the image's tcl9.0) are container paths, and build/windows-docker
# is pre-created host-owned so the tree lands back as the host user. The host
# bundler needs a natively runnable 9.0 tclsh - the cross PE one can't - so
# reuse the native build's, else a tclsh9.0 on PATH.

ifdef DOCKER
  WIN_BUILD := build/windows-docker
  WIN_MAKE  := IN_DOCKER_BUILD_SUBDIR= \
               IN_DOCKER_CCACHE_DIR=/src/$(WIN_BUILD)/.ccache \
               $(ZIPPY)/in_docker.sh mingw make
  WIN_ROOT  := /src
  WIN_TCLSH := /usr/local/bin/tclsh9.0
else
  WIN_HOST_TCLSH := $(LINUX_BUILD)/_build/local/bin/tclsh9.0
  WIN_BUILD := build/windows
  WIN_MAKE  := $(MAKE)
  WIN_ROOT  := $(CURDIR)
  WIN_TCLSH := $(if $(wildcard $(WIN_HOST_TCLSH)),$(WIN_HOST_TCLSH),tclsh9.0)
endif

# The shared dep cache from whichever root the inner make sees: under DOCKER=1
# that is the container's /src, not the host's $(CURDIR).
WIN_DEPS_DIR := $(WIN_ROOT)/build/deps

win: win-tacky win-tackyd win-tackyd-json

win-tacky win-tackyd win-tackyd-json: win-%: dist-dir
	mkdir -p $(WIN_BUILD)
	$(WIN_MAKE) -f $(ZIPPY)/zippy.mk \
	    TARGET_OS=windows \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$(call win-deps,$($*_DEPS))" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    $(if $($*_ICON),WIN_ICON=$(WIN_ROOT)/$($*_ICON)) \
	    HOST_TCLSH=$(WIN_TCLSH) \
	    BASEDIR=$(WIN_ROOT)/$(WIN_BUILD) \
	    DEPSDIR=$(WIN_DEPS_DIR) \
	    win-app
	$(call copy-if-changed,$(WIN_BUILD)/$*.exe,dist/$*.exe)

# Windows libtacky.a: the same static-library build as `lib`, cross-compiled to
# a MinGW PE archive. Ships alongside the native one as dist/libtacky-win.a.
win-lib: dist-dir
	mkdir -p $(WIN_BUILD)
	$(WIN_MAKE) -f $(ZIPPY)/zippy.mk \
	    TARGET_OS=windows \
	    SHELL_TYPE=tclsh \
	    DEPS="$(call win-deps,$(tackyd-json_DEPS))" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(WIN_ROOT)/embed/tacky.c \
	    LIB_NAME=tacky \
	    HOST_TCLSH=$(WIN_TCLSH) \
	    BASEDIR=$(WIN_ROOT)/$(WIN_BUILD) \
	    DEPSDIR=$(WIN_DEPS_DIR) \
	    win-lib
	$(call copy-if-changed,$(WIN_BUILD)/libtacky.a,dist/libtacky-win.a)

# ==== Android cross-build ====
# The daemon (tackyd-json) for arm64-v8a, staged as a jniLibs/<abi>/ subtree an
# Android app drops straight into app/src/main/jniLibs/. There is usually no host
# NDK, so this routes through zippy's ndk docker profile by default (like `make
# linux`); ANDROID_DOCKER below is for the case where there is one. Under docker
# the inner make runs in the container at /src, so BASEDIR is the container path
# rather than $(CURDIR)/...; pre-create build/android host-owned so its tree (and
# the output binary/jniLibs) land back in the bind-mounted project as the host
# user.
# IN_DOCKER_BUILD_SUBDIR= turns off the cache mount as the Windows targets do:
# BASEDIR isolates the tree, and only the ndk container ever writes it. Output:
# dist/jniLibs/arm64-v8a/{libtackyd_json.so, libc++_shared.so}.

ANDROID_BUILD := build/android

# ANDROID_DOCKER=0 uses an NDK already on the machine instead of the ndk image:
# android.mk wants $ANDROID_NDK set and the API-versioned clang wrappers on PATH,
# which is what that image otherwise provides. It is for a caller already inside
# a container carrying an NDK, where nesting docker to reach the same toolchain
# would mean a socket mount and root-owned output. Same arrangement as DOCKER=1
# on the Windows targets, with the default the other way round.
ANDROID_DOCKER ?= 1
ifeq ($(ANDROID_DOCKER),0)
  ANDROID_MAKE := $(MAKE)
  ANDROID_ROOT := $(CURDIR)
else
  ANDROID_MAKE := IN_DOCKER_BUILD_SUBDIR= \
                  IN_DOCKER_CCACHE_DIR=/src/$(ANDROID_BUILD)/.ccache \
                  $(ZIPPY)/in_docker.sh ndk make
  ANDROID_ROOT := /src
endif

android: dist-dir
	mkdir -p $(ANDROID_BUILD)
	$(ANDROID_MAKE) -f $(ZIPPY)/zippy.mk \
	    TARGET_OS=android \
	    BIN_NAME=tackyd-json \
	    SHELL_TYPE=$(tackyd-json_SHELL) \
	    DEPS="$(call android-deps,$(tackyd-json_DEPS))" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="$(tackyd-json_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=$(ANDROID_ROOT)/$(ANDROID_BUILD) \
	    android-jnilibs
	mkdir -p dist/jniLibs
	cp -r $(ANDROID_BUILD)/jniLibs/. dist/jniLibs/

# Android libtacky.a: the `lib` static-library build cross-compiled to a bionic
# arm64 archive, routed through the ndk docker profile like `android` (the two
# share build/android, so the dep stamps compile once). Ships alongside the
# native and MinGW ones as dist/libtacky-android.a.
android-lib: dist-dir
	mkdir -p $(ANDROID_BUILD)
	$(ANDROID_MAKE) -f $(ZIPPY)/zippy.mk \
	    TARGET_OS=android \
	    SHELL_TYPE=tclsh \
	    DEPS="$(call android-deps,$(tackyd-json_DEPS))" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(ANDROID_ROOT)/embed/tacky.c \
	    LIB_NAME=tacky \
	    BASEDIR=$(ANDROID_ROOT)/$(ANDROID_BUILD) \
	    android-lib
	$(call copy-if-changed,$(ANDROID_BUILD)/libtacky.a,dist/libtacky-android.a)

# ==== Portable Linux build ====
# Build the native binaries against an older glibc (Debian bookworm, 2.36) so
# they run on distros older than the Arch host (which links 2.43). The compile
# runs in the container via docker/Dockerfile; the binaries export into dist/
# with a -glibc<version> suffix (e.g. tacky-glibc2.36), so they sit alongside
# the native and Windows builds without clobbering dist/tacky. Only glibc is
# pinned older - the GUI binary still dynamically links libX11/libXft/etc.

LINUX_OUT := dist

linux: dist-dir
	DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --output $(LINUX_OUT) .

# ==== libwebrtc media backend ====
# dist/libtacky_webrtc.so from the rtc-webrtc repo; not part of `all`. Needs a
# native build first. Host build: ship the one built in quack's Rocky 9 image.

WEBRTC_SRC ?= $(HOME)/dev/tacky_calls/rtc-webrtc
WEBRTC_BUILD := $(CURDIR)/build/webrtc
WEBRTC_TCL_PREFIX ?= $(LINUX_BUILD)/_build/local

# The .so compiles in rtc-mv's frame ring at zippy's pinned commit.
WEBRTC_RTCMV_COMMIT := $(shell sed -n 's/^RTCMV_COMMIT[[:space:]]*:=[[:space:]]*//p' \
                          $(ZIPPY)/zippy.mk)
WEBRTC_RTCMV_SRC ?= $(DEPS_DIR)/rtc-mv-$(WEBRTC_RTCMV_COMMIT)

webrtc-so: dist-dir
	@[ -f "$(WEBRTC_SRC)/CMakeLists.txt" ] || { \
	    echo "make: no wrapper sources at $(WEBRTC_SRC);" >&2; \
	    echo "    set WEBRTC_SRC=<path to the rtc-webrtc checkout>" >&2; exit 1; }
	@{ [ -f "$(WEBRTC_SRC)/third_party/webrtc/lib/libwebrtc.a" ] && \
	   [ -x "$(WEBRTC_SRC)/third_party/clang/bin/clang++" ]; } || { \
	    echo "make: $(WEBRTC_SRC)/third_party is incomplete; see its README.md" >&2; \
	    exit 1; }
	@[ -f "$(WEBRTC_TCL_PREFIX)/include/tcl.h" ] || { \
	    echo "make: no Tcl headers at $(WEBRTC_TCL_PREFIX); run make tclsh first" >&2; \
	    exit 1; }
	@[ -f "$(WEBRTC_RTCMV_SRC)/include/rtcmv.h" ] || { \
	    echo "make: no rtc-mv sources at $(WEBRTC_RTCMV_SRC); run make tclsh first" >&2; \
	    exit 1; }
	cmake -S $(WEBRTC_SRC) -B $(WEBRTC_BUILD) -DTCL_PREFIX=$(WEBRTC_TCL_PREFIX) \
	    -DRTCMV_SRC=$(WEBRTC_RTCMV_SRC)
	cmake --build $(WEBRTC_BUILD)
	$(call copy-if-changed,$(WEBRTC_BUILD)/libtacky_webrtc.so,dist/libtacky_webrtc.so)

# The same backend for Android arm64-v8a. Needs android-lib and $ANDROID_NDK.
ANDROID_WEBRTC_BUILD := $(abspath $(ANDROID_BUILD))/webrtc
ANDROID_WEBRTC_TCL_PREFIX := $(abspath $(ANDROID_BUILD))/_build-android/local
ANDROID_WEBRTC_RTCMV_SRC := $(abspath $(ANDROID_BUILD))/_build/deps/rtc-mv-$(WEBRTC_RTCMV_COMMIT)

android-webrtc-so: dist-dir
	@[ -n "$(ANDROID_NDK)" ] || { echo "make: ANDROID_NDK is unset" >&2; exit 1; }
	@{ [ -f "$(WEBRTC_SRC)/third_party/webrtc-android/lib/arm64-v8a/libwebrtc.a" ] && \
	   [ -x "$(WEBRTC_SRC)/third_party/clang/bin/clang++" ]; } || { \
	    echo "make: $(WEBRTC_SRC)/third_party is incomplete; see its README.md" >&2; \
	    exit 1; }
	@[ -f "$(ANDROID_WEBRTC_TCL_PREFIX)/include/tcl.h" ] || { \
	    echo "make: no Tcl headers at $(ANDROID_WEBRTC_TCL_PREFIX); run make android-lib first" >&2; \
	    exit 1; }
	@[ -f "$(ANDROID_WEBRTC_RTCMV_SRC)/include/rtcmv.h" ] || { \
	    echo "make: no rtc-mv sources at $(ANDROID_WEBRTC_RTCMV_SRC); run make android-lib first" >&2; \
	    exit 1; }
	cmake -S $(WEBRTC_SRC) -B $(ANDROID_WEBRTC_BUILD) -DWEBRTC_ANDROID_NDK=$(ANDROID_NDK) \
	    -DTCL_PREFIX=$(ANDROID_WEBRTC_TCL_PREFIX) -DRTCMV_SRC=$(ANDROID_WEBRTC_RTCMV_SRC)
	cmake --build $(ANDROID_WEBRTC_BUILD)
	$(call copy-if-changed,$(ANDROID_WEBRTC_BUILD)/libtacky_webrtc.so,dist/libtacky_webrtc-android.so)
	$(call copy-if-changed,$(WEBRTC_SRC)/third_party/webrtc-android/jar/webrtc.jar,dist/webrtc-android.jar)

# The same backend for Windows x64, built with clang-cl. Needs win-lib.
WIN_WEBRTC_BUILD := $(WIN_ROOT)/$(WIN_BUILD)/webrtc
WIN_WEBRTC_SDK ?= $(WEBRTC_SRC)/third_party/xwin
WIN_WEBRTC_TCL_VER := $(shell sed -n 's/^TCL_VER[[:space:]]*:=[[:space:]]*//p' $(CURDIR)/$(ZIPPY)/zippy.mk)

win-webrtc-dll: dist-dir
	@{ [ -f "$(WEBRTC_SRC)/third_party/webrtc-windows/lib/webrtc.lib" ] && \
	   [ -x "$(WEBRTC_SRC)/third_party/clang/bin/clang-cl" ] && \
	   [ -d "$(WIN_WEBRTC_SDK)/crt" ]; } || { \
	    echo "make: $(WEBRTC_SRC)/third_party is incomplete; see its README.md" >&2; \
	    exit 1; }
	@[ -f "$(WIN_DEPS_DIR)/rtc-mv-$(WEBRTC_RTCMV_COMMIT)/include/rtcmv.h" ] || { \
	    echo "make: no rtc-mv sources in $(WIN_DEPS_DIR); run make win-lib first" >&2; \
	    exit 1; }
	cmake -S $(WEBRTC_SRC) -B $(WIN_WEBRTC_BUILD) -G Ninja \
	    -DWEBRTC_WINDOWS_SDK=$(WIN_WEBRTC_SDK) \
	    -DTCL_SRC=$(WIN_DEPS_DIR)/tcl$(WIN_WEBRTC_TCL_VER) \
	    -DRTCMV_SRC=$(WIN_DEPS_DIR)/rtc-mv-$(WEBRTC_RTCMV_COMMIT)
	cmake --build $(WIN_WEBRTC_BUILD)
	$(call copy-if-changed,$(WIN_WEBRTC_BUILD)/libtacky_webrtc.dll,dist/libtacky_webrtc-win.dll)

# ==== Flatpak ====
# Opt-in packaging layer (not part of `all`). Needs flatpak + the
# org.flatpak.Builder app installed; the SDK/runtime are pulled from flathub on
# first build. The manifest re-runs `make tacky` inside the SDK sandbox, so
# these are wrappers around flatpak-builder, not zippy build steps.
#
#   flatpak         build + install into the user flatpak (dev iteration)
#   flatpak-bundle  export to an OSTree repo and pack the shareable tacky.flatpak
#   flatpak-install install that bundle locally to test the shippable artifact

FLATPAK_APP     := io.github.pounceandmiss.Tacky
FLATPAK_BUILDER := flatpak run org.flatpak.Builder
# Embedded so `flatpak install tacky.flatpak` can fetch the runtime itself.
FLATPAK_RUNTIME_REPO := https://dl.flathub.org/repo/flathub.flatpakrepo

# --disable-updates: reuse the cached git mirrors / downloads instead of
#   re-fetching branch refs, git-lfs and submodules on every run; genuinely
#   missing sources (e.g. after a commit-pin bump) are still downloaded.
# --ccache: builder 1.4.9 doesn't auto-enable ccache (the SDK-detection
#   auto-enable is newer), so without this every rebuild recompiles all deps
#   from scratch. The cache persists in flatpak/.flatpak-builder/ccache and the
#   dep sources are identical run-to-run, so this turns rebuilds into link-time.
FLATPAK_FLAGS := --user --ccache --disable-updates --force-clean

flatpak:
	cd flatpak && $(FLATPAK_BUILDER) $(FLATPAK_FLAGS) --install \
	    --install-deps-from=flathub build-dir $(FLATPAK_APP).yml

flatpak-bundle:
	cd flatpak && $(FLATPAK_BUILDER) $(FLATPAK_FLAGS) --repo=repo \
	    build-dir $(FLATPAK_APP).yml
	cd flatpak && flatpak build-bundle --runtime-repo=$(FLATPAK_RUNTIME_REPO) \
	    repo tacky.flatpak $(FLATPAK_APP) master

flatpak-install:
	cd flatpak && flatpak install --user --reinstall -y tacky.flatpak

# ==== Dev interpreters ====
# Standalone zipfs interpreters with all deps baked in (system tclsh9.0 can't
# find rtc/rtcma). Run the app or tests from source without a full bundle:
# e.g. `make wish && build/linux/wish bin/tacky.tcl`.
#
# Built into $(LINUX_BUILD) alongside the app so they share its dep clones and
# compiled stamps; wish's DEPS are a subset of tacky's. Depend on this Makefile
# so editing COMMON_DEPS forces a rebuild.

tools: tclsh wish
tclsh: $(LINUX_BUILD)/tclsh
wish: $(LINUX_BUILD)/wish

test: $(LINUX_BUILD)/tclsh
	$(LINUX_BUILD)/tclsh test_all.tcl

test-gui: $(LINUX_BUILD)/wish
	$(LINUX_BUILD)/wish test_gui.tcl

# xvfb-run's default screen is 640x480, shorter than the geometry some tests
# request; the DPI is pinned because point-sized fonts shift every metric.
test-gui-headless: $(LINUX_BUILD)/wish
	xvfb-run -a -s "-screen 0 1280x1024x24 -dpi 96" $(LINUX_BUILD)/wish test_gui.tcl

# C-ABI smoke test: compile the standalone driver against dist/libtacky.a and run
# the create -> request -> destroy cycle. Exercises the static-archive link
# boundary that test_embed.tcl (Tcl-level) can't. Opt-in - not part of `test`,
# which builds no C. Extend the link line if a bundled dep needs more system libs.
test-lib: lib
	$(CXX) -pthread -I embed -o $(LINUX_BUILD)/lib_driver tests/lib_driver.c \
	    -Wl,--start-group dist/libtacky.a -Wl,--end-group \
	    -ldl -lz -lm -static-libstdc++
	$(LINUX_BUILD)/lib_driver

$(LINUX_BUILD)/tclsh: Makefile
	$(MAKE) -f $(ZIPPY)/zippy.mk \
	    SHELL_TYPE=tclsh \
	    DEPS="$(COMMON_DEPS)" \
	    BASEDIR=$(LINUX_BUILD) \
	    DEPSDIR=$(DEPS_DIR) \
	    tclsh

# tackygui.tcl globs and sources every gui/*.tcl file, callwindow.tcl
# included, so this dev shell needs rtcmv_tk too - it's not just a
# release-binary concern.
$(LINUX_BUILD)/wish: Makefile
	$(MAKE) -f $(ZIPPY)/zippy.mk \
	    SHELL_TYPE=wish \
	    DEPS="$(call native-deps,$(COMMON_DEPS) tkwuffs tkdnd rtcmv_tk)" \
	    BASEDIR=$(LINUX_BUILD) \
	    DEPSDIR=$(DEPS_DIR) \
	    wish

dist-dir:
	mkdir -p dist

clean:
	rm -rf build dist

# Drop the Windows build trees and .exe outputs (both flavours). The fetched dep
# sources live in build/deps, not under the per-target tree, so a rebuild doesn't
# re-clone. Use after a dep pin bump to force a clean PE rebuild.
win-clean:
	rm -rf build/windows*/_build-win
	rm -f build/windows*/*.exe build/windows*/*.exe.debug dist/*.exe
