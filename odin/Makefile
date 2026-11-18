ODIN       ?= odin
ODIN_BIN   := $(shell command -v $(ODIN))
ODIN_ROOT  ?= $(dir $(shell readlink -f $(ODIN_BIN)))
STB_LIB    := $(ODIN_ROOT)vendor/stb/lib/stb_truetype.a
LINK_FLAGS := -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lSDL2 -lcairo -lpango-1.0 -lpangocairo-1.0 -lgobject-2.0 -lglib-2.0"
BIN        := bin/tracker-odin

PREFIX     ?= $(HOME)/.local
export PREFIX
SESSION    ?= $(HOME)/.local/share/tracker/session
SCRIPT     ?= tests/ui/full-tour.json
SHOT       ?= /tmp/tracker-odin-ui.png
UI_OUT     ?= /tmp/tracker-ui-test

.PHONY: all build stb test test-dsp test-core test-ui check clean run devices selftest ui ui-shot ui-test bounce install uninstall

all: build

# Runtime text at 1.25x/1.5x/3x uses Odin's stb_truetype bindings. Recent
# releases do not ship the native archive; build it once with the vendored
# script (the same pattern as the miniaudio archive).
$(STB_LIB):
	sh "$(ODIN_ROOT)vendor/stb/src/build_stb.sh" unix

stb: $(STB_LIB)

build: stb
	@mkdir -p bin
	"$(ODIN)" build src -out:$(BIN) $(LINK_FLAGS)

test-dsp:
	"$(ODIN)" test src/dsp

# Project/WAV tests live in the root `src` package.
test-core: stb
	"$(ODIN)" test src $(LINK_FLAGS)

test-ui: stb
	"$(ODIN)" test src/ui $(LINK_FLAGS)

test: test-dsp test-core test-ui

# check.sh runs the three test packages itself, then builds and exercises the
# CLI, the UI harness and the offline bounce.
check: build
	./scripts/check.sh

run: ui

ui: build
	./$(BIN) ui

ui-shot: build
	./$(BIN) ui-shot --out "$(SHOT)"

ui-test: build
	./$(BIN) ui-test --script "$(SCRIPT)" --out "$(UI_OUT)"

devices: build
	./$(BIN) devices

selftest: build
	./$(BIN) selftest

bounce: build
	./$(BIN) bounce --session "$(SESSION)"

install: build
	@SKIP_BUILD=1 ./scripts/install-desktop.sh

uninstall:
	@./scripts/install-desktop.sh --uninstall

clean:
	rm -rf bin
