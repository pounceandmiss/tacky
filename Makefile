# ==== Shared config ====

COMMON_DEPS := tdom mtls tcllib rtc rtcma omemo tclwuffs
COMMON_EXCL := build dist tests doc test_all.tcl test_gui.tcl \
               README.md LICENSE cleanup.resume zippy Makefile .git .gitignore

# ==== Per-binary config ====

tacky_SHELL := wish
tacky_DEPS  := $(COMMON_DEPS) tkwuffs tkdnd
tacky_SRC   := lib bin gui icons
tacky_ENT   := bin/tacky.tcl
tacky_ICON  := icons/tacky.ico

tackyd_SHELL := tclsh
tackyd_DEPS  := $(COMMON_DEPS)
tackyd_SRC   := lib bin
tackyd_ENT   := bin/tackyd.tcl

tackyd-json_SHELL := tclsh
tackyd-json_DEPS  := $(COMMON_DEPS)
tackyd-json_SRC   := lib bin
tackyd-json_ENT   := bin/tackyd-json.tcl

# ==== Targets ====

.PHONY: all \
	tacky tackyd tackyd-json lib \
	win win-tacky win-tackyd win-tackyd-json win-lib win-clean \
        android \
	linux flatpak flatpak-bundle flatpak-install \
        test test-gui tools wish tclsh clean dist-dir

all: tacky tackyd tackyd-json

# The three native binaries share one build tree so the heavy deps
# (libdatachannel etc.) compile once, not once per binary; binaries 2 and 3 just
# reuse the dep stamps in the shared PREFIX. Windows builds into a separate tree
# (below) - sharing stays within an OS, so Linux and Windows never share a dep
# source dir and their in-tree ELF/PE artifacts can't poison each other.
LINUX_BUILD := $(CURDIR)/build/linux
WIN_BUILD   := $(CURDIR)/build/windows

# The Windows bundler (zippy/build.tcl) runs on the host, so it needs a 9.0-line
# tclsh that runs natively; the cross-compiled PE tclsh can't. Reuse the one the
# native build produces, falling back to a tclsh9.0 on PATH.
WIN_HOST_TCLSH := $(LINUX_BUILD)/_build/local/bin/tclsh9.0
HOST_TCLSH     := $(if $(wildcard $(WIN_HOST_TCLSH)),$(WIN_HOST_TCLSH),tclsh9.0)

tacky tackyd tackyd-json: %: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$($*_DEPS)" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=$(LINUX_BUILD) \
	    app
	cp $(LINUX_BUILD)/$* dist/$*

# libtacky.a: the taco backend as a linked C library (embed/tacky.c drives the
# interp on a private thread; see embed/tacky.h). Same deps/sources as the
# tackyd-json daemon, but with no entry script - the shim, not a main.tcl, runs
# the show. Shares the native build tree so it reuses the already-built deps.
lib: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    SHELL_TYPE=tclsh \
	    DEPS="$(tackyd-json_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(CURDIR)/embed/tacky.c \
	    LIB_NAME=tacky \
	    BASEDIR=$(LINUX_BUILD) \
	    lib
	cp $(LINUX_BUILD)/libtacky.a dist/libtacky.a

# ==== Windows cross-build ====
# Static .exe binaries via MinGW-w64 (zippy/windows.mk). Same per-binary config
# as the native build; TARGET_OS=windows swaps in the win/ recipes and bundles
# with a host tclsh9.0. All three share build/windows (deps compile once), kept
# separate from build/linux so ELF/PE artifacts never cross; ships $*.exe.

win: win-tacky win-tackyd win-tackyd-json

win-tacky win-tackyd win-tackyd-json: win-%: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    TARGET_OS=windows \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$($*_DEPS)" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    $(if $($*_ICON),WIN_ICON=$(CURDIR)/$($*_ICON)) \
	    HOST_TCLSH=$(HOST_TCLSH) \
	    BASEDIR=$(WIN_BUILD) \
	    win-app
	cp $(WIN_BUILD)/$*.exe dist/$*.exe

# Windows libtacky.a: the same static-library build as `lib`, cross-compiled to
# a MinGW PE archive. Ships alongside the native one as dist/libtacky-win.a.
win-lib: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    TARGET_OS=windows \
	    SHELL_TYPE=tclsh \
	    DEPS="$(tackyd-json_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(CURDIR)/embed/tacky.c \
	    LIB_NAME=tacky \
	    HOST_TCLSH=$(HOST_TCLSH) \
	    BASEDIR=$(WIN_BUILD) \
	    win-lib
	cp $(WIN_BUILD)/libtacky.a dist/libtacky-win.a

# ==== Android cross-build ====
# The daemon (tackyd-json) for arm64-v8a, staged as a jniLibs/<abi>/ subtree an
# Android app drops straight into app/src/main/jniLibs/. There is no host NDK, so
# this routes through zippy's ndk docker profile (like `make linux`). The inner
# make runs in the container at /src, so BASEDIR is the container path, not
# $(CURDIR)/...; pre-create build/android host-owned so its tree (and the output
# binary/jniLibs) land back in the bind-mounted project as the host user. No
# cache-mount isolation is needed - nothing host-native ever builds Android, so
# build/android can't be poisoned. Output:
# dist/jniLibs/arm64-v8a/{libtackyd_json.so, libc++_shared.so}.

ANDROID_BUILD := build/android

android: dist-dir
	mkdir -p $(ANDROID_BUILD)
	zippy/in_docker.sh ndk \
	make -f zippy/zippy.mk \
	    TARGET_OS=android \
	    BIN_NAME=tackyd-json \
	    SHELL_TYPE=$(tackyd-json_SHELL) \
	    DEPS="$(tackyd-json_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="$(tackyd-json_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=/src/$(ANDROID_BUILD) \
	    android-jnilibs
	mkdir -p dist/jniLibs
	cp -r $(ANDROID_BUILD)/jniLibs/. dist/jniLibs/

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

$(LINUX_BUILD)/tclsh: Makefile
	$(MAKE) -f zippy/zippy.mk \
	    SHELL_TYPE=tclsh \
	    DEPS="$(COMMON_DEPS)" \
	    BASEDIR=$(LINUX_BUILD) \
	    tclsh

$(LINUX_BUILD)/wish: Makefile
	$(MAKE) -f zippy/zippy.mk \
	    SHELL_TYPE=wish \
	    DEPS="$(COMMON_DEPS) tkwuffs tkdnd" \
	    BASEDIR=$(LINUX_BUILD) \
	    wish

dist-dir:
	mkdir -p dist

clean:
	rm -rf build dist

# Drop the Windows build trees and .exe outputs, keeping the fetched dep
# sources under build/*/_build/deps so a rebuild doesn't re-clone. Use after a
# dep pin bump to force a clean PE rebuild from the existing sources.
win-clean:
	rm -rf build/*/_build-win
	rm -f build/*/*.exe build/*/*.exe.debug dist/*.exe
