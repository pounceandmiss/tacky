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
        android android-lib \
	linux flatpak flatpak-bundle flatpak-install \
        test test-gui test-gui-headless test-lib tools wish tclsh clean dist-dir

all: tacky tackyd tackyd-json

# The three native binaries share one build tree so the heavy deps
# (libdatachannel etc.) compile once, not once per binary; binaries 2 and 3 just
# reuse the dep stamps in the shared PREFIX. Every other platform gets its own
# tree (below), and each tree belongs to one toolchain, so no two ever share a
# dep source dir or poison each other's artifacts.
LINUX_BUILD := $(CURDIR)/build/linux

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
               zippy/in_docker.sh mingw make
  WIN_ROOT  := /src
  WIN_TCLSH := /usr/local/bin/tclsh9.0
else
  WIN_HOST_TCLSH := $(LINUX_BUILD)/_build/local/bin/tclsh9.0
  WIN_BUILD := build/windows
  WIN_MAKE  := $(MAKE)
  WIN_ROOT  := $(CURDIR)
  WIN_TCLSH := $(if $(wildcard $(WIN_HOST_TCLSH)),$(WIN_HOST_TCLSH),tclsh9.0)
endif

win: win-tacky win-tackyd win-tackyd-json

win-tacky win-tackyd win-tackyd-json: win-%: dist-dir
	mkdir -p $(WIN_BUILD)
	$(WIN_MAKE) -f zippy/zippy.mk \
	    TARGET_OS=windows \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$($*_DEPS)" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    $(if $($*_ICON),WIN_ICON=$(WIN_ROOT)/$($*_ICON)) \
	    HOST_TCLSH=$(WIN_TCLSH) \
	    BASEDIR=$(WIN_ROOT)/$(WIN_BUILD) \
	    win-app
	cp $(WIN_BUILD)/$*.exe dist/$*.exe

# Windows libtacky.a: the same static-library build as `lib`, cross-compiled to
# a MinGW PE archive. Ships alongside the native one as dist/libtacky-win.a.
win-lib: dist-dir
	mkdir -p $(WIN_BUILD)
	$(WIN_MAKE) -f zippy/zippy.mk \
	    TARGET_OS=windows \
	    SHELL_TYPE=tclsh \
	    DEPS="$(tackyd-json_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=$(WIN_ROOT)/embed/tacky.c \
	    LIB_NAME=tacky \
	    HOST_TCLSH=$(WIN_TCLSH) \
	    BASEDIR=$(WIN_ROOT)/$(WIN_BUILD) \
	    win-lib
	cp $(WIN_BUILD)/libtacky.a dist/libtacky-win.a

# ==== Android cross-build ====
# The daemon (tackyd-json) for arm64-v8a, staged as a jniLibs/<abi>/ subtree an
# Android app drops straight into app/src/main/jniLibs/. There is no host NDK, so
# this routes through zippy's ndk docker profile (like `make linux`). The inner
# make runs in the container at /src, so BASEDIR is the container path, not
# $(CURDIR)/...; pre-create build/android host-owned so its tree (and the output
# binary/jniLibs) land back in the bind-mounted project as the host user.
# IN_DOCKER_BUILD_SUBDIR= turns off the cache mount as the Windows targets do:
# BASEDIR isolates the tree, and only the ndk container ever writes it. Output:
# dist/jniLibs/arm64-v8a/{libtackyd_json.so, libc++_shared.so}.

ANDROID_BUILD := build/android

android: dist-dir
	mkdir -p $(ANDROID_BUILD)
	IN_DOCKER_BUILD_SUBDIR= \
	IN_DOCKER_CCACHE_DIR=/src/$(ANDROID_BUILD)/.ccache \
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

# Android libtacky.a: the `lib` static-library build cross-compiled to a bionic
# arm64 archive, routed through the ndk docker profile like `android` (the two
# share build/android, so the dep stamps compile once). Ships alongside the
# native and MinGW ones as dist/libtacky-android.a.
android-lib: dist-dir
	mkdir -p $(ANDROID_BUILD)
	IN_DOCKER_BUILD_SUBDIR= \
	IN_DOCKER_CCACHE_DIR=/src/$(ANDROID_BUILD)/.ccache \
	zippy/in_docker.sh ndk \
	make -f zippy/zippy.mk \
	    TARGET_OS=android \
	    SHELL_TYPE=tclsh \
	    DEPS="$(tackyd-json_DEPS)" \
	    SOURCES="$(tackyd-json_SRC)" \
	    ENTRY_SCRIPT="" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    LIB_SHIM_SRC=/src/embed/tacky.c \
	    LIB_NAME=tacky \
	    BASEDIR=/src/$(ANDROID_BUILD) \
	    android-lib
	cp $(ANDROID_BUILD)/libtacky.a dist/libtacky-android.a

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

# Drop the Windows build trees and .exe outputs (both flavours), keeping the
# fetched dep sources under build/windows*/_build/deps so a rebuild doesn't
# re-clone. Use after a dep pin bump to force a clean PE rebuild from the
# existing sources.
win-clean:
	rm -rf build/windows*/_build-win
	rm -f build/windows*/*.exe build/windows*/*.exe.debug dist/*.exe
