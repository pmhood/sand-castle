# Checks for the agent sandbox image. The CI workflow runs these same targets.

IMAGE ?= sandcastle-agent:dev
IMAGE_PUBLISH ?= ghcr.io/pmhood/sandcastle-agent
PUBLISH_TAG ?= latest
PUBLISH_PLATFORMS ?= linux/amd64,linux/arm64
BATS_VERSION ?= v1.12.0
LOCAL_BATS := $(CURDIR)/.bats/bin/bats

# Prefer a bats already on PATH; otherwise install a pinned one into .bats (gitignored).
BATS := $(shell command -v bats 2>/dev/null)
ifeq ($(BATS),)
BATS := $(LOCAL_BATS)
endif

# The two bootstrap executables, which carry no suffix because they are installed as
# commands, plus every *.sh under this directory so a later one cannot go unlinted.
SHELL_SOURCES := bootstrap/sandcastle-run bootstrap/sandcastle-askpass \
	$(shell find . -name '*.sh' -not -path './.bats/*')

.PHONY: check lint test build smoke publish
check: lint test build

lint:
	shellcheck $(SHELL_SOURCES)

test: $(BATS)
	$(BATS) --print-output-on-failure bootstrap/test

build:
	docker build -t $(IMAGE) .

smoke:
	$(CURDIR)/scripts/smoke.sh $(ARGS)

# Human escape hatch: builds and pushes the multi-arch image by hand. CI
# (.github/workflows/agent-image.yml) is the normal path, publishing on every merge to main;
# this exists for exceptional cases only. A hand-published image drifts from the commit that
# supposedly produced it, so prefer merging over running this. Requires `docker login ghcr.io`
# already done (see images/agent/README.md) and a buildx builder that supports both platforms.
publish:
	docker buildx build --platform $(PUBLISH_PLATFORMS) -t $(IMAGE_PUBLISH):$(PUBLISH_TAG) --push .

# bats-core has no dependencies and installs from a git checkout, which works the same on a
# CI runner and a developer machine without a package manager or sudo.
$(LOCAL_BATS):
	@echo "bats not found; installing bats-core $(BATS_VERSION) into $(CURDIR)/.bats"
	rm -rf .bats .bats-src
	git clone --quiet --depth 1 --branch $(BATS_VERSION) \
		https://github.com/bats-core/bats-core.git .bats-src
	./.bats-src/install.sh $(CURDIR)/.bats
	rm -rf .bats-src
