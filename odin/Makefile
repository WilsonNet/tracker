ODIN       ?= odin
LINK_FLAGS := -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lSDL2"
BIN        := bin/tracker-odin

PREFIX     ?= $(HOME)/.local
export PREFIX
SESSION    ?= $(HOME)/.local/share/tracker/session
SCRIPT     ?= tests/ui/full-tour.json
SHOT       ?= /tmp/tracker-odin-ui.png
UI_OUT     ?= /tmp/tracker-ui-test

.PHONY: all build test test-dsp test-core test-ui check clean run devices selftest ui ui-shot ui-test bounce install uninstall

all: build

build:
	@mkdir -p bin
	"$(ODIN)" build src -out:$(BIN) $(LINK_FLAGS)

test-dsp:
	"$(ODIN)" test src/dsp

# Project/WAV tests live in the root `src` package.
test-core:
	"$(ODIN)" test src $(LINK_FLAGS)

test-ui:
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
