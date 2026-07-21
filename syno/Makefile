# ===========================================================================
# Immich Synology SPK — Package Variables & Build Reference
# Target: x86_64, DSM 7.2+ (tested on 7.3.2)
# ===========================================================================

PACKAGE        := immich
VERSION        := 1.134.0
PKG_REVISION   := 1
FULL_VERSION   := $(VERSION)-$(PKG_REVISION)
ARCH           := x86_64

# DSM compatibility
DSM_MIN_VER    := 7.2-64561
DSM_UI_DIR     := ui

# Node.js bundled runtime
NODE_VERSION   := 24.15.0
NODE_TARBALL   := node-v$(NODE_VERSION)-linux-x64.tar.xz
NODE_URL       := https://nodejs.org/dist/v$(NODE_VERSION)/$(NODE_TARBALL)

# PostgreSQL + pgvector
PG_VERSION     := 14.12
PGVECTOR_VERSION := 0.7.4
PG_PREFIX      := /var/packages/immich/target/postgres

# Python ML (optional)
PYTHON_VERSION := 3.11
INCLUDE_ML     ?= 0

# Installation paths (on DSM)
INSTALL_ROOT   := /var/packages/immich/target
INSTALL_BIN    := $(INSTALL_ROOT)/bin
INSTALL_NODE   := $(INSTALL_ROOT)/node
INSTALL_PG     := $(INSTALL_ROOT)/postgres
INSTALL_PYTHON := $(INSTALL_ROOT)/python
INSTALL_SERVER := $(INSTALL_ROOT)/server
INSTALL_WEB    := $(INSTALL_ROOT)/web
INSTALL_ML     := $(INSTALL_ROOT)/machine-learning
INSTALL_DATA   := /volume1/docker/immich

# Build dirs (macOS host)
SYNO_DIR       := $(CURDIR)/syno
BUILD_DIR      := $(CURDIR)/syno/build
STAGE_DIR      := $(BUILD_DIR)/stage
VENDOR_DIR     := $(SYNO_DIR)/vendor
SPK_BUILD_DIR  := $(BUILD_DIR)/spk-root

# SPK output
SPK_NAME       := $(PACKAGE)-$(ARCH)-$(FULL_VERSION).spk

# Docker image tags
PG_BUILDER_TAG := immich-pg-builder
ML_BUILDER_TAG := immich-ml-builder

# Required tools
REQUIRED_TOOLS := node pnpm docker git tar shasum

# ===========================================================================
# Targets
# ===========================================================================

.PHONY: help validate build clean info

help:
	@echo ""
	@echo "Immich Synology SPK Build — $(PACKAGE) v$(FULL_VERSION) ($(ARCH))"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "Primary entrypoint:"
	@echo "  bash syno/build.sh             Build full SPK (ML disabled)"
	@echo "  INCLUDE_ML=1 bash syno/build.sh  Include ML service"
	@echo ""
	@echo "Build flow (executed by build.sh):"
	@echo "  1. Check prerequisites"
	@echo "  2. pnpm install (frozen lockfile)"
	@echo "  3. Build @immich/server (NestJS)"
	@echo "  4. Build immich-web (SvelteKit)"
	@echo "  5. Download Node.js $(NODE_VERSION) Linux x86_64 + verify SHA256"
	@echo "  6. Docker: build PG14 + pgvector → syno/vendor/postgres/"
	@echo "  7. Docker: build Python 3.11 ML venv → syno/vendor/python/ (if INCLUDE_ML=1)"
	@echo "  8. Assemble stage/ layout"
	@echo "  9. Create package.tgz"
	@echo " 10. Assemble .spk archive + print SHA256"
	@echo ""
	@echo "Variables:"
	@echo "  NODE_VERSION    $(NODE_VERSION)"
	@echo "  PG_VERSION      $(PG_VERSION)"
	@echo "  PGVECTOR_VERSION $(PGVECTOR_VERSION)"
	@echo "  INCLUDE_ML      $(INCLUDE_ML)"
	@echo "  SPK_NAME        $(SPK_NAME)"
	@echo ""
	@echo "Make targets:"
	@echo "  help      This message"
	@echo "  validate  Check all required tools are installed"
	@echo "  info      Print resolved variable values"
	@echo "  clean     Remove build/ and vendor/ directories"
	@echo ""

validate:
	@echo "Checking required tools..."
	@MISSING=""; \
	for tool in $(REQUIRED_TOOLS); do \
		if ! command -v $$tool >/dev/null 2>&1; then \
			echo "  ✗ $$tool — NOT FOUND"; \
			MISSING="$$MISSING $$tool"; \
		else \
			echo "  ✓ $$tool — $$(command -v $$tool)"; \
		fi; \
	done; \
	if [ -n "$$MISSING" ]; then \
		echo ""; \
		echo "ERROR: Missing tools:$$MISSING"; \
		exit 1; \
	fi
	@echo ""
	@echo "All required tools present."

info:
	@echo "PACKAGE        = $(PACKAGE)"
	@echo "VERSION        = $(VERSION)"
	@echo "FULL_VERSION   = $(FULL_VERSION)"
	@echo "ARCH           = $(ARCH)"
	@echo "NODE_VERSION   = $(NODE_VERSION)"
	@echo "PG_VERSION     = $(PG_VERSION)"
	@echo "PGVECTOR_VER   = $(PGVECTOR_VERSION)"
	@echo "INCLUDE_ML     = $(INCLUDE_ML)"
	@echo "INSTALL_ROOT   = $(INSTALL_ROOT)"
	@echo "SPK_NAME       = $(SPK_NAME)"
	@echo "BUILD_DIR      = $(BUILD_DIR)"
	@echo "STAGE_DIR      = $(STAGE_DIR)"

clean:
	@echo "Removing build artifacts..."
	rm -rf $(BUILD_DIR)
	@echo "Removing vendor binaries..."
	rm -rf $(VENDOR_DIR)
	@echo "Done."
