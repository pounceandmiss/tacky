# ==== Shared config ====

COMMON_DEPS := tdom mtls tcllib rtc rtcma omemo tclwuffs
COMMON_EXCL := build dist tests doc test_all.tcl test_gui.tcl \
               README.md LICENSE cleanup.resume zippy Makefile .git .gitignore

# ==== Per-binary config ====

tacky_SHELL := wish
tacky_DEPS  := $(COMMON_DEPS) tkwuffs
tacky_SRC   := lib bin gui icons
tacky_ENT   := bin/tacky.tcl

tackyd_SHELL := tclsh
tackyd_DEPS  := $(COMMON_DEPS)
tackyd_SRC   := lib bin
tackyd_ENT   := bin/tackyd.tcl

tackyd-json_SHELL := tclsh
tackyd-json_DEPS  := $(COMMON_DEPS)
tackyd-json_SRC   := lib bin
tackyd-json_ENT   := bin/tackyd-json.tcl

# ==== Targets ====

.PHONY: all tacky tackyd tackyd-json test test-gui clean dist-dir

all: tacky tackyd tackyd-json

tacky tackyd tackyd-json: %: dist-dir
	$(MAKE) -f zippy/zippy.mk \
	    BIN_NAME=$* \
	    SHELL_TYPE=$($*_SHELL) \
	    DEPS="$($*_DEPS)" \
	    SOURCES="$($*_SRC)" \
	    ENTRY_SCRIPT="$($*_ENT)" \
	    APP_EXCLUDE="$(COMMON_EXCL)" \
	    BASEDIR=$(CURDIR)/build/$* \
	    app
	cp build/$*/$* dist/$*

# ==== Test interpreters ====
# Standalone zipfs interpreters with deps baked in (system tclsh9.0 can't find rtc/rtcma).

test: build/tools/tclsh
	build/tools/tclsh test_all.tcl

test-gui: build/tools/wish
	build/tools/wish test_gui.tcl

build/tools/tclsh:
	$(MAKE) -f zippy/zippy.mk \
	    SHELL_TYPE=tclsh \
	    DEPS="$(COMMON_DEPS)" \
	    BASEDIR=$(CURDIR)/build/tools \
	    tclsh

build/tools/wish:
	$(MAKE) -f zippy/zippy.mk \
	    SHELL_TYPE=wish \
	    DEPS="$(COMMON_DEPS) tkwuffs" \
	    BASEDIR=$(CURDIR)/build/tools \
	    wish

dist-dir:
	mkdir -p dist

clean:
	rm -rf build dist
