#!/bin/bash
set -e
cd /Users/huangwenqin/Desktop/AI_Chatting_app

SWIFT_FILES=$(find Sources -name '*.swift' | sort)

echo "=== 编译所有文件 (x86_64-apple-macosx10.15) ==="
swiftc -O -swift-version 5 \
    -target "x86_64-apple-macosx10.15" \
    -framework SwiftUI -framework AppKit -framework Combine \
    -o /tmp/aichat3 \
    $SWIFT_FILES 2>&1 | head -60

echo ""
echo "=== EXIT_CHECK ==="
echo "done"