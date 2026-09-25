# SwiftDrupal Makefile
# Build, test, and package the drupal CLI, signed with the virtualization
# entitlement Containerization's VM machinery needs
# (scripts/drupal.entitlements; `swift build` strips signatures, so every
# build that will run containers must be re-signed).

BINARY = drupal
BIN_DIR = ./bin
ENTITLEMENTS = scripts/drupal.entitlements

.PHONY: all build test release install clean help

all: build

build:
	swift build

test:
	swift test

# Signed release binary + entitlements in ./bin (what release.yml packages).
release:
	swift build -c release --product $(BINARY)
	@mkdir -p $(BIN_DIR)
	cp "$$(swift build -c release --show-bin-path)/$(BINARY)" $(BIN_DIR)/
	cp $(ENTITLEMENTS) $(BIN_DIR)/drupal.entitlements
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN_DIR)/$(BINARY)
	@echo "Signed $(BINARY) (+ entitlements) in $(BIN_DIR)/"

# Signed release build installed to ~/.local/bin/drupal (restarts the resolver agent).
install:
	scripts/install.sh

clean:
	swift package clean
	rm -rf $(BIN_DIR)

help:
	@echo "make build    - debug build"
	@echo "make test     - run tests"
	@echo "make release  - signed release binary + entitlements in ./bin"
	@echo "make install  - signed release build to ~/.local/bin/drupal"
	@echo "make clean    - remove build artifacts"
