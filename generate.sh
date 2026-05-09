#!/bin/bash
# Regenerate TimeSync.xcodeproj from project.yml
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate
echo "Generated TimeSync.xcodeproj. Open with: open TimeSync.xcodeproj"
