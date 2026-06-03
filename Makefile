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
        test test-gui tools wish tclsh clean win-clean dist-dir

all: tacky tackyd tackyd-json

tacky tackyd tackyd-json: %: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    $(MTLS_OVERRIDE) \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$($*_DEPS)" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=$(CURDIR)/build/$* \
	    app
	cp build/$*/$* dist/$*

# ==== Windows cross-build ====
# Static .exe binaries via MinGW-w64 (zippy/windows.mk). Same per-binary config
# as the native build; TARGET_OS=windows swaps in the win/ recipes and bundles
# with a host tclsh9.0. Reuses build/$*'s fetched dep sources from the native
# build (zippy isolates the Windows outputs under _build-win); ships $*.exe.

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
	    BASEDIR=$(CURDIR)/build/$* \
	    win-app
	cp build/$*/$*.exe dist/$*.exe

# ==== Dev interpreters ====
# Standalone zipfs interpreters with all deps baked in (system tclsh9.0 can't
# find rtc/rtcma). Use these to run the app or tests from source without
# building a full bundle: e.g. `make wish && build/tools/wish bin/tacky.tcl`.
#
# The build/tools/* rules depend on this Makefile so that editing COMMON_DEPS
# rebuilds the interpreter instead of silently reusing a stale one.

tools: tclsh wish
tclsh: build/tools/tclsh
wish: build/tools/wish

test: build/tools/tclsh
	build/tools/tclsh test_all.tcl

test-gui: build/tools/wish
	build/tools/wish test_gui.tcl

build/tools/tclsh: Makefile
	$(MAKE) -f zippy/zippy.mk \
	    $(MTLS_OVERRIDE) \
	    SHELL_TYPE=tclsh \
	    DEPS="$(COMMON_DEPS)" \
	    BASEDIR=$(CURDIR)/build/tools \
	    tclsh

build/tools/wish: Makefile
	$(MAKE) -f zippy/zippy.mk \
	    $(MTLS_OVERRIDE) \
	    SHELL_TYPE=wish \
	    DEPS="$(COMMON_DEPS) tkwuffs" \
	    BASEDIR=$(CURDIR)/build/tools \
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
