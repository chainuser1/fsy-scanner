#!/bin/bash
# FSY Scanner — Release Build Script
# Creates signed release APK
# Usage: ./scripts/release-build.sh

set -e

PROJECT_DIR="fsy_scanner"

if [ ! -d "$PROJECT_DIR" ]; then
    echo "❌ Error: $PROJECT_DIR directory not found"
    exit 1
fi

echo "🚀 FSY Scanner Release Build"
echo ""

# Check for keystore
if [ ! -f "$HOME/.android/fsy-scanner.keystore" ]; then
    echo "❌ Error: Keystore not found at ~/.android/fsy-scanner.keystore"
    echo ""
    echo "To create a keystore, run:"
    echo "  keytool -genkey -v -keystore ~/.android/fsy-scanner.keystore \\"
    echo "    -keyalg RSA -keysize 2048 -validity 10000 -alias fsy-scanner"
    exit 1
fi

echo "✅ Keystore found"
echo ""

# Get version
cd "$PROJECT_DIR"
VERSION=$(grep "version:" pubspec.yaml | head -1 | cut -d':' -f2 | xargs)
BUILD_NUMBER=$(echo $VERSION | cut -d'+' -f2)
VERSION_NAME=$(echo $VERSION | cut -d'+' -f1)

echo "📦 Building version: $VERSION_NAME (build $BUILD_NUMBER)"
echo ""

# Clean before building
echo "🧹 Cleaning build artifacts..."
flutter clean

# Get dependencies
echo "📥 Installing dependencies..."
flutter pub get

# Run analysis
echo "🔎 Running code analysis..."
flutter analyze

# Build release APK
echo "🔨 Building release APK..."
flutter build apk \
    --release \
    --target-platform android-arm64 \
    --build-number="$BUILD_NUMBER" \
    --build-name="$VERSION_NAME"

# Verify output
APK_PATH="build/app/outputs/apk/release/app-release.apk"
if [ -f "$APK_PATH" ]; then
    SIZE=$(du -h "$APK_PATH" | cut -f1)
    CHECKSUM=$(sha256sum "$APK_PATH" | cut -d' ' -f1)
    
    echo ""
    echo "✅ Release build successful!"
    echo ""
    echo "📦 APK Details:"
    echo "   Path:     $APK_PATH"
    echo "   Size:     $SIZE"
    echo "   SHA256:   $CHECKSUM"
    echo "   Version:  $VERSION_NAME"
    echo "   Build:    $BUILD_NUMBER"
    echo ""
    
    # Create checksums file
    echo "$CHECKSUM  app-release.apk" > "$APK_PATH.sha256"
    echo "✅ Checksum saved to: $APK_PATH.sha256"
else
    echo "❌ Release build failed: APK not found"
    exit 1
fi
