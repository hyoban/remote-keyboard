#!/bin/sh
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O -swift-version 5 Sources/main.swift -o build/remote-keyboard
echo "构建完成: build/remote-keyboard"
