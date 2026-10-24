# sudamp — build, test and bundle on the Command Line Tools (DESIGN §9). No Xcode, no Homebrew packages.
SHELL := /bin/bash
# macOS ships GNU make 3.81, which ignores .SHELLFLAGS: every piped recipe sets pipefail itself.
CONFIG ?= debug
VERSION ?= 0.1.0
APP ?= build/sudamp.app
# One Swift on every machine and in CI, the version in .swift-version (DESIGN §9): its swift.org toolchain when
# installed, with an SDK it can read; otherwise the system Swift, which `toolchain` checks is the same minor version.
# Recipes call $(SWIFT): make 3.81 runs a simple command itself, looking it up on its own PATH rather than the one
# exported here, which only reaches commands run through the shell (the scripts).
TOOLCHAIN_BIN := $(shell scripts/toolchain.sh bin)
TOOLCHAIN_SDK := $(shell scripts/toolchain.sh sdk)
SWIFT := $(if $(TOOLCHAIN_BIN),$(TOOLCHAIN_BIN)/swift,swift)
ifneq ($(TOOLCHAIN_BIN),)
export PATH := $(TOOLCHAIN_BIN):$(PATH)
endif
ifneq ($(TOOLCHAIN_SDK),)
export SDKROOT := $(TOOLCHAIN_SDK)
endif
# Swift Testing macros plugin, from the Swift that builds; works for swift.org, CLT and Xcode toolchains.
PLUGINS := $(if $(TOOLCHAIN_BIN),$(TOOLCHAIN_BIN),$(shell dirname $$(xcrun -f swift)))/../lib/swift/host/plugins/testing
export PLUGINS
TEST_FLAGS := $(if $(wildcard $(PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(PLUGINS),)

.PHONY: toolchain build test app app-hardened verify-binary run skin-check skin-preview catalog-check golden notices \
	vendor-mpv clean

toolchain:
	@scripts/toolchain.sh

build: toolchain
	@mkdir -p .build
	set -o pipefail; SUDAMP_LINK_MAP=1 $(SWIFT) build -c $(CONFIG) 2>&1 | tee .build/build-$(CONFIG).log
	scripts/check-warnings.sh .build/build-$(CONFIG).log

# Tests that assert real elapsed time run in a second, quiet pass: on a small machine (the 3-core CI runner) the
# parallel suite saturates the CPU and their sub-second budgets fail.
TIMING_TESTS := FeedsTests\.|CoreTests\.SubprocessTests|ResolverTests\.
# CI passes TEST_MODE=--no-parallel: the 3-core runner is too slow for parallel runs (a JSON decode test took 20 s).
TEST_MODE ?= --parallel

test: toolchain
	$(SWIFT) test $(TEST_MODE) $(TEST_FLAGS) --skip '$(TIMING_TESTS)'
	$(SWIFT) test $(TEST_MODE) $(TEST_FLAGS) --filter '$(TIMING_TESTS)'
	scripts/count-escapes.sh

app: build
	APP_PATH=$(abspath $(APP)) VERSION=$(VERSION) scripts/bundle.sh $(CONFIG)

app-hardened: build
	APP_PATH=$(abspath $(APP)) HARDENED=1 VERSION=$(VERSION) scripts/bundle.sh $(CONFIG)

verify-binary: app
	scripts/verify-binary.sh $(APP)

run: app
	$(APP)/Contents/MacOS/sudamp

# sudamp Dark must regenerate byte-identically (DESIGN §8.3).
skin-check: toolchain
	$(SWIFT) run skingen --check Fixtures/skins/sudamp-dark.wsz

# The curated catalog: catalog/feed.json must be what catalog/ builds, and lint must pass (docs/catalog.md).
catalog-check: toolchain
	$(SWIFT) run catalog-tool build --check
	$(SWIFT) run catalog-tool lint catalog/

# Opens the skinned windows with a fake player state; pass options with ARGS="--skin <wsz> --scale 2".
skin-preview: toolchain
	$(SWIFT) run sudamp --skin-preview $(ARGS)

# Skin fidelity against ~100 complete museum skins (tracked, not a gate; docs/spikes/golden.md).
golden:
	scripts/golden-fetch.sh
	scripts/golden-compare.sh

# THIRD_PARTY_NOTICES.md covers every library linked from MPVKit (DESIGN §10, PLAN M8); --generate rewrites it.
# make test also runs it through ShellTests' ThirdPartyNoticesTests.
notices:
	scripts/check-notices.sh

vendor-mpv:
	scripts/vendor-mpv-headers.sh

clean:
	rm -rf .build build
