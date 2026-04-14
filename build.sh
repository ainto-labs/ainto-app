#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Building Rust core library ==="
cd "$SCRIPT_DIR/ainto-core"
cargo build --release
echo "  -> libainto_core.a built"

echo ""
echo "=== Building Swift app ==="
cd "$SCRIPT_DIR/AintoApp"
swift build -c release
echo "  -> AintoApp built"

echo ""
echo "=== Done ==="
echo "Binary: $SCRIPT_DIR/AintoApp/.build/release/AintoApp"
