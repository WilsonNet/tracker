ODIN       ?= odin
LINK_FLAGS := -extra-linker-flags:"-lm -ldl -lpthread"
BIN        := bin/tracker-odin

.PHONY: all build test test-dsp test-wav check clean run devices selftest

all: build

build:
	@mkdir -p bin
	$(ODIN) build src -out:$(BIN) $(LINK_FLAGS)

test-dsp:
	$(ODIN) test src/dsp

test-wav:
	$(ODIN) test src $(LINK_FLAGS)

test: test-dsp test-wav

check: test build
	./scripts/check.sh

run: build
	./$(BIN)

devices: build
	./$(BIN) devices

selftest: build
	./$(BIN) selftest

clean:
	rm -rf bin
