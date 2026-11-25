ODIN       ?= odin
VINLAND    ?= $(abspath ../../vinland-ui)
UNAME_S    := $(shell uname -s)
ODIN_ROOT  ?= $(shell "$(ODIN)" root)
BREW_PREFIX := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)

ifeq ($(UNAME_S),Darwin)
STB_LIB    := $(ODIN_ROOT)/vendor/stb/lib/darwin/stb_truetype.a
LINK_FLAGS := -extra-linker-flags:"-L$(BREW_PREFIX)/lib -Wl,-rpath,$(BREW_PREFIX)/lib"
else
STB_LIB    := $(ODIN_ROOT)/vendor/stb/lib/stb_truetype.a
LINK_FLAGS := -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lcairo -lpango-1.0 -lpangocairo-1.0 -lgobject-2.0 -lglib-2.0"
endif

BIN        := bin/tracker-fx

PREFIX     ?= $(HOME)/.local
export PREFIX
SESSION    ?= $(HOME)/.local/share/tracker-fx/session
SCRIPT     ?= tests/ui/full-tour.json
SHOT       ?= /tmp/tracker-fx-ui.png
UI_OUT     ?= /tmp/tracker-fx-ui-test
VUI_PORT   ?= 7421

E2E_OUT    ?= /tmp/tracker-fx-e2e

.PHONY: e2e all build stb test test-dsp test-core test-ui check clean run devices selftest ui ui-bg ui-shot ui-test bounce install uninstall

all: build

# Runtime text at 1.25x/1.5x/3x uses Odin's stb_truetype bindings. On Linux
# recent Odin releases omit the native archive so build it once; on macOS it
# is shipped under vendor/stb/lib/darwin/.
$(STB_LIB):
	sh "$(ODIN_ROOT)/vendor/stb/src/build_stb.sh" unix

stb: $(STB_LIB)

build: stb
	@mkdir -p bin
	"$(ODIN)" build src -out:$(BIN) -collection:vinland=$(VINLAND) $(LINK_FLAGS)

test-dsp:
	"$(ODIN)" test src/dsp

# Project/WAV tests live in the root `src` package.
test-core: stb
	"$(ODIN)" test src -collection:vinland=$(VINLAND) $(LINK_FLAGS)

test-ui: stb
	"$(ODIN)" test src/ui -collection:vinland=$(VINLAND) $(LINK_FLAGS)

test: test-dsp test-core test-ui

# check.sh runs the three test packages itself, then builds and exercises the
# CLI, the UI harness and the offline bounce.
check: build
	./scripts/check.sh

run: ui

ui: build
	./$(BIN) ui

# Visible window that is not activated on show, so an agent can drive it with
# vui-ctl while the user games or works elsewhere (X11 honors the non-focusable
# hint; Wayland leaves focus policy to the compositor). vui-ctl foreground is
# the escape hatch when a native dialog or IME genuinely needs focus.
ui-bg: build
	VUI_BACKGROUND=1 VUI_PORT=$(VUI_PORT) ./$(BIN) ui

ui-shot: build
	./$(BIN) ui-shot --out "$(SHOT)"

ui-test: build
	./$(BIN) ui-test --script "$(SCRIPT)" --out "$(UI_OUT)"

# Window end-to-end suite (vinland-ui vui-test; headless + sandboxed software rendering)
e2e: build
	$(VINLAND)/build/vui-test --out $(E2E_OUT) tests/ui/window.vt

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
