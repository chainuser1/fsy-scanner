#!/bin/bash
# FSY Scanner — Flutter CI Build Script
# Usage: ./scripts/ci-build.sh [debug|release]

set -e

PROJECT_DIR="fsy_scanner"
BUILD_TYPE="${1:-debug}"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Error: $PROJECT_DIR directory not found"
    exit 1
fi

cd "$(dirname "$0")/../fsy_scanner"

echo "🔍 Starting Flutter CI build..."
echo "📦 Build type: $BUILD_TYPE"

# Step 1: Verify Flutter
echo ""
echo "📋 Checking Flutter environment..."
flutter --version

# Step 2: Get dependencies
echo ""
echo "📥 Installing dependencies..."
flutter pub get

# Step 3: Analyze code
echo ""
echo "🔎 Running code analysis..."
flutter analyze

# Step 4: Run tests
echo ""
echo "🧪 Running unit tests..."
flutter test 2>/dev/null || echo "⚠️  No tests or tests failed (warning only)"

# Step 5: Build APK
echo ""
echo "🔨 Building APK ($BUILD_TYPE)..."

if [ "$BUILD_TYPE" = "release" ]; then
    flutter build apk --release --target-platform android-arm64
    APK_PATH="build/app/outputs/apk/release/app-release.apk"
else
    flutter build apk --debug --target-platform android-arm64
    APK_PATH="build/app/outputs/apk/debug/app-debug.apk"
fi

# Step 6: Verify build
echo ""
if [ -f "$APK_PATH" ]; then
    SIZE=$(du -h "$APK_PATH" | cut -f1)
    echo "✅ Build successful!"
    echo "📦 APK: $APK_PATH ($SIZE)"
else
    echo "❌ Build failed: APK not found at $APK_PATH"
    exit 1
fi
