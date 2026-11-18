ODIN       ?= odin
LINK_FLAGS := -extra-linker-flags:"-lm -ldl -lpthread -ljack -lz -lSDL2"
BIN        := bin/tracker-odin

.PHONY: all build test test-dsp test-wav test-ui test-cli check clean run devices selftest ui ui-test bounce install

all: build

build:
	@mkdir -p bin
	$(ODIN) build src -out:$(BIN) $(LINK_FLAGS)

test-dsp:
	$(ODIN) test src/dsp

test-wav:
	$(ODIN) test src $(LINK_FLAGS)

test-ui:
	$(ODIN) test src/ui $(LINK_FLAGS)

test: test-dsp test-wav test-ui

check: test build
	./scripts/check.sh

run: build
	./$(BIN)

ui: build
	./$(BIN) ui

devices: build
	./$(BIN) devices

selftest: build
	./$(BIN) selftest

bounce: build
	./$(BIN) bounce --session session

install: build
	./scripts/install-desktop.sh

clean:
	rm -rf bin
