## Interop test harness: Cyclone DDS ↔ zidl-rt cross-validation.
##
## Targets:
##   zig-test — run the Zig interop tests only (no Cyclone required; default)
##   all      — generate expected/*.bin from Cyclone DDS (requires CYCLONE)
##   regen    — alias for all
##   test     — regen + zig-test (full validation; requires CYCLONE)
##   clean    — remove built artefacts and expected/*.bin
##
## The expected/*.bin files are committed to git so the Zig tests can be
## run without Cyclone or a C compiler.  Run `make regen` after changing
## types.idl or the test fixture values in cyclone_dump.c.
##
## Override variables on the command line as needed:
##   make regen CYCLONE=/path/to/cyclonedds
##   make zig-test ZIG=/path/to/zig

CYCLONE     ?=
CYCLONE_LIB := $(CYCLONE)/build/lib
IDLC        := $(CYCLONE)/build/bin/idlc
ZIG         ?= zig

CC      := gcc
CFLAGS  := -std=c99 -Wall -Wextra -g \
           -I$(CYCLONE)/src/core/ddsc/include \
           -I$(CYCLONE)/src/core/ddsi/include \
           -I$(CYCLONE)/src/core/cdr/include \
           -I$(CYCLONE)/src/ddsrt/include \
           -I$(CYCLONE)/src/ddsrt/include/posix \
           -I$(CYCLONE)/build/src/ddsrt/include \
           -I$(CYCLONE)/build/src/core/include \
           -I.
LDFLAGS := -L$(CYCLONE_LIB) -lddsc -Wl,-rpath,$(CYCLONE_LIB)

DUMP_BIN := cyclone_dump

.PHONY: all regen clean test zig-test

## Default: run Zig tests (no Cyclone required)
all: zig-test

## Run only the Zig interop tests (CI-safe; expected bytes are hardcoded in source)
zig-test:
	cd .. && $(ZIG) test \
	    --dep zidl_rt \
	    -Mroot=interop/zig_interop_test.zig \
	    -Mzidl_rt=packages/zidl-rt/src/root.zig

## Generate C type support from IDL (requires CYCLONE)
gen/types.h gen/types.c: types.idl
	$(IDLC) -o gen/ $<

## Build the Cyclone dump binary (requires CYCLONE)
$(DUMP_BIN): cyclone_dump.c gen/types.c gen/types.h
	$(CC) $(CFLAGS) -o $@ cyclone_dump.c gen/types.c $(LDFLAGS)

## Regenerate expected/*.bin from Cyclone DDS (requires CYCLONE)
expected/.stamp: $(DUMP_BIN)
	mkdir -p expected
	./$(DUMP_BIN) expected
	touch $@

regen: clean expected/.stamp

## Full test: regenerate expected/*.bin then run Zig tests (requires CYCLONE)
test: expected/.stamp zig-test

clean:
	rm -f $(DUMP_BIN)
	rm -rf expected/.stamp expected/*.bin
