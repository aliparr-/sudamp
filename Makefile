# sudamp — build, test and bundle on the Command Line Tools (DESIGN §9). No Xcode, no Homebrew packages.
SHELL := /bin/bash
# macOS ships GNU make 3.81, which ignores .SHELLFLAGS: every piped recipe sets pipefail itself.
CONFIG ?= debug
VERSION ?= 0.1.0
APP ?= build/sudamp.app
# Swift Testing macros plugin; works for CLT and Xcode toolchains.
PLUGINS := $(shell dirname $$(xcrun -f swift))/../lib/swift/host/plugins/testing
TEST_FLAGS := $(if $(wildcard $(PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(PLUGINS),)

.PHONY: build test app app-hardened verify-binary run skin-check skin-preview catalog-check golden notices vendor-mpv clean

build:
	@mkdir -p .build
	set -o pipefail; SUDAMP_LINK_MAP=1 swift build -c $(CONFIG) 2>&1 | tee .build/build-$(CONFIG).log
	scripts/check-warnings.sh .build/build-$(CONFIG).log

# Tests that assert real elapsed time run in a second, quiet pass: on a small machine (the 3-core CI runner) the
# parallel suite saturates the CPU and their sub-second budgets fail.
TIMING_TESTS := FeedsTests\.|CoreTests\.SubprocessTests|ResolverTests\.

test:
	swift test --parallel $(TEST_FLAGS) --skip '$(TIMING_TESTS)'
	swift test --parallel $(TEST_FLAGS) --filter '$(TIMING_TESTS)'
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
skin-check:
	swift run skingen --check Fixtures/skins/sudamp-dark.wsz

# The curated catalog: catalog/feed.json must be what catalog/ builds, and lint must pass (docs/catalog.md).
catalog-check:
	swift run catalog-tool build --check
	swift run catalog-tool lint catalog/

# Opens the skinned windows with a fake player state; pass options with ARGS="--skin <wsz> --scale 2".
skin-preview:
	swift run sudamp --skin-preview $(ARGS)

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
