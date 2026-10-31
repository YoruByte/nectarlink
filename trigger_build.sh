#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Trigger GitHub Cloud Build for NectarLink Linux (AppImage + Arch pacman package)
set -euo pipefail

REPO="YoruByte/nectarlink"
WORKFLOW="build_linux.yml"

echo "=========================================="
echo "  Triggering NectarLink Linux Cloud Build "
echo "  Repository: ${REPO}                     "
echo "  Workflow:   ${WORKFLOW}                 "
echo "=========================================="

gh workflow run "${WORKFLOW}" -R "${REPO}"

echo "Waiting for build to initialize on GitHub..."
sleep 5

gh run watch -R "${REPO}"

echo ""
echo "Build finished! Check releases at: https://github.com/${REPO}/releases"
