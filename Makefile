# SwiftDrupal Makefile
# Build and install the drupal CLI, signed with the virtualization
# entitlement Containerization's VM machinery needs (see drupal.entitlements
# and AGENTS.md's "Building the drupal binary").

SCHEME = SwiftDrupal
BINARY = drupal
BIN_DIR = ./bin
DESTINATION = platform=macOS,arch=arm64
DERIVED_DATA = $(HOME)/Library/Developer/Xcode/DerivedData
ENTITLEMENTS = drupal.entitlements

.PHONY: all build release install clean test resolve help

all: install

# Resolve all SPM package dependencies via xcodebuild
resolve:
	xcodebuild -resolvePackageDependencies -scheme $(SCHEME) -destination '$(DESTINATION)'
	@echo "Package dependencies resolved."

# Development build with xcodebuild
build:
	xcodebuild build -scheme $(SCHEME) -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO

# Release build with xcodebuild + copy to bin, signed with the
# virtualization entitlement and packaged alongside it so a downstream
# tarball can carry both.
release: resolve
	xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' -configuration Release build
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/SwiftDrupal-*/Build/Products/Release -name $(BINARY) -type f 2>/dev/null | head -1 | xargs dirname); \
	if [ -n "$$PRODUCT_DIR" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		cp "$(ENTITLEMENTS)" $(BIN_DIR)/; \
		codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN_DIR)/$(BINARY); \
		echo "Installed and signed $(BINARY) (+ entitlements) to $(BIN_DIR)/ (Release)"; \
	else \
		echo "Error: Could not find $(BINARY) in DerivedData"; \
		exit 1; \
	fi

# Debug build with xcodebuild + copy to bin (default)
install: resolve
	xcodebuild -scheme $(SCHEME) -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO build
	@mkdir -p $(BIN_DIR)
	@PRODUCT_DIR=$$(find $(DERIVED_DATA)/SwiftDrupal-*/Build/Products/Debug -name $(BINARY) -type f 2>/dev/null | head -1 | xargs dirname); \
	if [ -n "$$PRODUCT_DIR" ]; then \
		cp "$$PRODUCT_DIR/$(BINARY)" $(BIN_DIR)/; \
		codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BIN_DIR)/$(BINARY); \
		echo "Installed $(BINARY) to $(BIN_DIR)/ (Debug, signed)"; \
	else \
		echo "Error: Could not find $(BINARY) in DerivedData"; \
		exit 1; \
	fi

# Run tests
test:
	xcodebuild test -scheme $(SCHEME) -destination '$(DESTINATION)' CODE_SIGNING_ALLOWED=NO

# Clean build artifacts
clean:
	swift package clean
	rm -rf $(BIN_DIR)
	rm -rf $(DERIVED_DATA)/SwiftDrupal-*

help:
	@echo "SwiftDrupal Makefile"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  resolve  - Resolve all SPM package dependencies"
	@echo "  build    - Development build with xcodebuild"
	@echo "  install  - Debug build with xcodebuild + copy to ./bin (signed)"
	@echo "  release  - Release build with xcodebuild + copy to ./bin (signed)"
	@echo "  test     - Run tests"
	@echo "  clean    - Clean build artifacts"
	@echo "  help     - Show this help"
	@echo ""
	@echo "All builds use: -destination '$(DESTINATION)'"
