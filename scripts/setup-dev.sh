#!/bin/bash
# FSY Scanner — Local Development Setup
# Usage: ./scripts/setup-dev.sh

set -e

echo "🚀 FSY Scanner Flutter Development Setup"
echo ""

# Step 1: Check Flutter
echo "📍 Checking Flutter installation..."
if ! command -v flutter &> /dev/null; then
    echo "❌ Flutter not found. Please install Flutter from https://flutter.dev/docs/get-started/install"
    exit 1
fi

FLUTTER_VERSION=$(flutter --version | grep -oP 'Flutter \K[0-9.]+')
echo "✅ Flutter $FLUTTER_VERSION found"

# Step 2: Check Dart
echo ""
echo "📍 Checking Dart installation..."
if ! command -v dart &> /dev/null; then
    echo "❌ Dart not found"
    exit 1
fi

DART_VERSION=$(dart --version 2>&1 | grep -oP 'Dart SDK version: \K[0-9.]+')
echo "✅ Dart $DART_VERSION found"

# Step 3: Check Java
echo ""
echo "📍 Checking Java installation..."
if ! command -v java &> /dev/null; then
    echo "❌ Java not found. Please install JDK 17 or later"
    exit 1
fi

JAVA_VERSION=$(java -version 2>&1 | grep -oP 'version "\K[0-9.]+')
echo "✅ Java $JAVA_VERSION found"

# Step 4: Get dependencies
echo ""
echo "📥 Installing Flutter dependencies..."
cd fsy_scanner
flutter pub get

# Step 5: Setup Android
echo ""
echo "📋 Checking Android setup..."
flutter doctor -v

# Step 6: Create .env (template)
echo ""
echo "📝 Setting up environment..."
if [ ! -f "assets/.env" ]; then
    cat > assets/.env << 'EOF'
# Add your environment variables here
# GOOGLE_SERVICE_ACCOUNT_EMAIL=your-service-account@project.iam.gserviceaccount.com
# GOOGLE_SERVICE_ACCOUNT_PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----
# SHEETS_ID=your-sheets-id
# SHEETS_TAB=Scanner Copy
# EVENT_NAME=FSY 2026 Tacloban and Tolosa
EOF
    echo "⚠️  Created template assets/.env — please fill in your values"
else
    echo "✅ assets/.env already exists"
fi

# Step 7: Run analysis
echo ""
echo "🔎 Running initial analysis..."
flutter analyze --no-fatal-infos || true

echo ""
echo "✅ Setup complete!"
echo ""
echo "📚 Next steps:"
echo "1. Edit fsy_scanner/assets/.env with your configuration"
echo "2. Connect an Android device or start an emulator"
echo "3. Run: flutter run"
echo ""
echo "📖 For more info, see BUILD.md"
