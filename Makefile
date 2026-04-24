.PHONY: help clean deps analyze format test build-debug build-release build-apk build-all run doctor lint

PROJECT_DIR := fsy_scanner

help:
	@echo "FSY Scanner — Flutter Build Commands"
	@echo ""
	@echo "Setup:"
	@echo "  make deps              - Install Flutter dependencies"
	@echo "  make doctor            - Check Flutter environment"
	@echo ""
	@echo "Development:"
	@echo "  make analyze           - Run Dart analyzer"
	@echo "  make format            - Format Dart code"
	@echo "  make lint              - Run linter (analyzer)"
	@echo "  make test              - Run unit tests"
	@echo "  make run               - Run on connected device"
	@echo ""
	@echo "Building:"
	@echo "  make build-debug       - Build debug APK"
	@echo "  make build-release     - Build release APK"
	@echo "  make build-all         - Build debug + release APKs"
	@echo ""
	@echo "Cleaning:"
	@echo "  make clean             - Clean build artifacts"
	@echo "  make clean-all         - Clean everything (including pubspec.lock)"
	@echo ""

deps:
	cd $(PROJECT_DIR) && flutter pub get

doctor:
	flutter doctor -v

lint:
	cd $(PROJECT_DIR) && flutter analyze

analyze: lint

format:
	cd $(PROJECT_DIR) && dart format lib/

format-check:
	cd $(PROJECT_DIR) && dart format --set-exit-if-changed lib/

test:
	cd $(PROJECT_DIR) && flutter test

run:
	cd $(PROJECT_DIR) && flutter run -v

run-release:
	cd $(PROJECT_DIR) && flutter run --release

run-profile:
	cd $(PROJECT_DIR) && flutter run --profile

build-debug:
	cd $(PROJECT_DIR) && flutter build apk --debug

build-release:
	cd $(PROJECT_DIR) && flutter build apk --release

build-all: build-debug build-release

build-apk-arm64:
	cd $(PROJECT_DIR) && flutter build apk --target-platform android-arm64

build-apk-armv7:
	cd $(PROJECT_DIR) && flutter build apk --target-platform android-arm

build-aab:
	cd $(PROJECT_DIR) && flutter build appbundle

clean:
	cd $(PROJECT_DIR) && flutter clean

clean-all: clean
	cd $(PROJECT_DIR) && rm -rf pubspec.lock .packages

verify: format-check analyze
	@echo "✓ Code verification passed"

ci: verify test build-apk-arm64
	@echo "✓ CI checks passed"
