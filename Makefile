# ==== Shared config ====

COMMON_DEPS := tdom mtls tcllib rtc rtcma omemo tclwuffs
COMMON_EXCL := build dist tests doc test_all.tcl test_gui.tcl \
               README.md LICENSE cleanup.resume zippy Makefile .git .gitignore

# Until the Windows cert-store fix lands upstream, pull mtls from our fork
# (overrides zippy.mk's chpock default). No effect off Windows: the patch is
# inside #ifdef _WIN32. Drop this once chpock merges the PR.
MTLS_OVERRIDE := MTLS_REPO=https://github.com/pounceandmiss/tclmtls.git \
                 MTLS_COMMIT=d52b59d

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

.PHONY: all tacky tackyd tackyd-json win win-tacky win-tackyd win-tackyd-json \
        linux flatpak flatpak-bundle flatpak-install \
        test test-gui tools wish tclsh clean win-clean dist-dir

all: tacky tackyd tackyd-json

# The three native binaries share one build tree so the heavy deps
# (libdatachannel etc.) compile once, not once per binary; binaries 2 and 3 just
# reuse the dep stamps in the shared PREFIX. Windows builds into a separate tree
# (below) - sharing stays within an OS, so Linux and Windows never share a dep
# source dir and their in-tree ELF/PE artifacts can't poison each other.
LINUX_BUILD := $(CURDIR)/build/linux
WIN_BUILD   := $(CURDIR)/build/windows

tacky tackyd tackyd-json: %: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    $(MTLS_OVERRIDE) \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$($*_DEPS)" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=$(LINUX_BUILD) \
	    app
	cp $(LINUX_BUILD)/$* dist/$*

# ==== Windows cross-build ====
# Static .exe binaries via MinGW-w64 (zippy/windows.mk). Same per-binary config
# as the native build; TARGET_OS=windows swaps in the win/ recipes and bundles
# with a host tclsh9.0. All three share build/windows (deps compile once), kept
# separate from build/linux so ELF/PE artifacts never cross; ships $*.exe.

win: win-tacky win-tackyd win-tackyd-json

win-tacky win-tackyd win-tackyd-json: win-%: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    $(MTLS_OVERRIDE) \
	    TARGET_OS=windows \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$($*_DEPS)" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    $(if $($*_ICON),WIN_ICON=$(CURDIR)/$($*_ICON)) \
	    BASEDIR=$(WIN_BUILD) \
	    win-app
	cp $(WIN_BUILD)/$*.exe dist/$*.exe

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
	    $(MTLS_OVERRIDE) \
	    SHELL_TYPE=tclsh \
	    DEPS="$(COMMON_DEPS)" \
	    BASEDIR=$(LINUX_BUILD) \
	    tclsh

$(LINUX_BUILD)/wish: Makefile
	$(MAKE) -f zippy/zippy.mk \
	    $(MTLS_OVERRIDE) \
	    SHELL_TYPE=wish \
	    DEPS="$(COMMON_DEPS) tkwuffs" \
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
