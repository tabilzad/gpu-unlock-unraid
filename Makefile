# GPU Unlock for Unraid: developer entry points.
#
# Run `./scripts/dev-env --root make check` to execute everything inside the
# pinned Docker image, or plain `make check` on a Linux machine that has
# shellcheck, shfmt, php, xmllint, kmod and Slackware's pkgtools.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PLUGIN     := gpu-unlock
PLUGIN_DIR := src/usr/local/emhttp/plugins/$(PLUGIN)
SH_FILES   := scripts/build-txz scripts/render-plg scripts/lint-plg scripts/plugin-version \
              scripts/dev-env scripts/build-module \
              src/usr/local/sbin/gpu-unlock-ctl $(PLUGIN_DIR)/scripts/lib.sh \
              $(PLUGIN_DIR)/scripts/post-install $(PLUGIN_DIR)/scripts/remove \
              $(PLUGIN_DIR)/hook/pre-nvidia.sh $(PLUGIN_DIR)/docker/firmware-gen.sh \
              tests/run.sh tests/lib.sh tests/test-hook.sh tests/test-ctl.sh tests/test-pkg.sh
PHP_FILES  := $(shell find src -name '*.php' | sort)
PAGE_FILES := $(shell find src -name '*.page' | sort)
KVER       ?= 6.18.58-Unraid

.PHONY: check lint test build module firmware-gen fmt lint-shell lint-php lint-plg lint-workflows

check: lint test
	@echo "check: ok"

lint: lint-shell lint-php lint-plg lint-workflows
	@echo "lint: ok"

lint-shell:
	@echo "shellcheck ($(words $(SH_FILES)) files)"
	shellcheck -x $(SH_FILES)
	@echo "shfmt -i 2 -ci -d (bash scripts)"
	shfmt -i 2 -ci -d $(filter-out %/pre-nvidia.sh %/firmware-gen.sh,$(SH_FILES))

lint-php:
	@echo "php -l ($(words $(PHP_FILES)) .php files, $(words $(PAGE_FILES)) pages)"
	@for f in $(PHP_FILES); do php -l "$$f" > /dev/null || exit 1; done
	@mkdir -p .tmp/pages
	@for f in $(PAGE_FILES); do sed '1,/^---$$/d' "$$f" > ".tmp/pages/$$(basename "$$f").php" && php -l ".tmp/pages/$$(basename "$$f").php" > /dev/null || exit 1; done

# Render the template with dev values, then check it with xmllint (entity
# expansion) and our own rules.
lint-plg:
	@echo "lint-plg"
	@mkdir -p .tmp/lint
	@./scripts/render-plg --version 0000.00.00.0-dev --plugin-version 0.0.0-dev \
	  --txz-name $(PLUGIN)-0000.00.00.0_dev-noarch-1.txz \
	  --txz-sha256 0000000000000000000000000000000000000000000000000000000000000000 \
	  --out .tmp/lint/$(PLUGIN).plg > /dev/null
	./scripts/lint-plg .tmp/lint/$(PLUGIN).plg

lint-workflows:
	@if command -v actionlint > /dev/null 2>&1; then echo "actionlint"; actionlint; else echo "lint-workflows: actionlint not installed, skipped"; fi

test:
	tests/run.sh

# make build                      -> dist/<pkg>.txz + dist/gpu-unlock.plg (dev version)
# make build VERSION=2026.10.26.1 PLUGIN_VERSION=0.1.0 TXZ_URL=https://.../pkg.txz
VERSION        ?= 0000.00.00.0-dev
PLUGIN_VERSION ?= 0.0.0-dev
TXZ_URL        ?=
DIST           ?= dist

build:
	@txz="$$(./scripts/build-txz --version $(VERSION) --out-dir $(DIST))" && \
	  ./scripts/render-plg --version $(VERSION) --plugin-version $(PLUGIN_VERSION) \
	    --txz "$$txz" $(if $(TXZ_URL),--txz-url $(TXZ_URL),) --out $(DIST)/$(PLUGIN).plg && \
	  ./scripts/lint-plg $(DIST)/$(PLUGIN).plg && \
	  ls -la $(DIST)

# The kernel module for one Unraid kernel (needs Docker on the host, not the dev image).
module:
	./scripts/build-module --kver $(KVER)

# The on-box firmware generator, built and run here as a check (needs Docker
# on the host). Keeps the NVIDIA inputs in .inputs/ between runs.
firmware-gen:
	docker build --pull -t $(PLUGIN)/firmware-gen:dev \
	  --build-arg "UPSTREAM_REPO=$$(sed -n 's/^UPSTREAM_REPO=//p' versions.env)" \
	  --build-arg "UPSTREAM_REF=$$(sed -n 's/^UPSTREAM_REF=//p' versions.env)" \
	  $(PLUGIN_DIR)/docker
	mkdir -p .inputs dist/firmware
	MSYS_NO_PATHCONV=1 docker run --rm -v "$$(pwd)/.inputs:/cache" -v "$$(pwd)/dist/firmware:/out" $(PLUGIN)/firmware-gen:dev
	cd dist/firmware && sha256sum -c SHA256SUMS

fmt:
	shfmt -i 2 -ci -w $(filter-out %/pre-nvidia.sh %/firmware-gen.sh,$(SH_FILES))
