#!/bin/bash
set -e
cd /Users/huangwenqin/Desktop/AI_Chatting_app

SWIFT_FILES=$(find Sources -name '*.swift' | sort)

echo "=== Attempt 1: x86_64-apple-macos10.15 ==="
swiftc -O -swift-version 5 \
    -target "x86_64-apple-macos10.15" \
    -framework SwiftUI -framework AppKit -framework Combine \
    -o /tmp/aichat1 \
    $SWIFT_FILES 2>&1 | head -30

echo ""
echo "=== Attempt 2: x86_64-apple-macosx10.15 ==="
swiftc -O -swift-version 5 \
    -target "x86_64-apple-macosx10.15" \
    -framework SwiftUI -framework AppKit -framework Combine \
    -o /tmp/aichat2 \
    $SWIFT_FILES 2>&1 | head -30

echo "EXIT_OK=$?"