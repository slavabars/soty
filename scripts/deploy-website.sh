#!/usr/bin/env bash
#
# Convenience wrapper for the Soty website deployer.
# The real script lives with the site so its nginx template stays versioned:
#   website/deploy/deploy.sh
#
# Usage: ./scripts/deploy-website.sh --host ... --user ... --path ... --domain ...

set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

exec "$WORKSPACE_DIR/website/deploy/deploy.sh" "$@"
