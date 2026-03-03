#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────
# ThraeAI Web Dashboard — Deploy Pipeline
#
# Usage:
#   ./scripts/deploy.sh             # Test + deploy
#   ./scripts/deploy.sh --skip-tests
#   ./scripts/deploy.sh --dry-run
# ─────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_PIPELINE="/Users/raviambikapathi/Documents/GitHub/Thraeai-Test-Pipeline"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes"
VPS="vps"
DATE=$(date +%Y%m%d-%H%M%S)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

SKIP_TESTS=false
DRY_RUN=false

for arg in "$@"; do
  case $arg in
    --skip-tests) SKIP_TESTS=true ;;
    --dry-run) DRY_RUN=true ;;
    --help) echo "Usage: deploy.sh [--skip-tests] [--dry-run]"; exit 0 ;;
  esac
done

step() { echo -e "\n${GREEN}${BOLD}▸ $1${NC}"; }
info() { echo -e "  $1"; }
die()  { echo -e "${RED}✗ $1${NC}"; exit 1; }

# ── Pre-flight ──
step "Pre-flight validation"
[ -f "$REPO_DIR/index.html" ] || die "index.html not found"
info "✓ index.html found ($(wc -c < "$REPO_DIR/index.html" | tr -d ' ') bytes)"

# Verify escHTML exists (security gate)
grep -q 'function escHTML' "$REPO_DIR/index.html" || die "escHTML() not found — XSS protection missing"
info "✓ escHTML() present"

# Verify CSP exists
grep -q 'Content-Security-Policy' "$REPO_DIR/index.html" || die "CSP meta tag missing"
info "✓ CSP meta tag present"

# ── Test gate ──
if ! $SKIP_TESTS; then
  step "Running dashboard test gate"

  if [ -d "$TEST_PIPELINE/tests/web-dashboard" ]; then
    cd "$TEST_PIPELINE"
    if npx vitest run tests/web-dashboard/ --reporter=verbose 2>&1; then
      info "✓ Dashboard tests passed"
    else
      die "Dashboard test gate FAILED — deploy blocked"
    fi
    cd "$REPO_DIR"
  else
    echo -e "  ${YELLOW}⚠ Dashboard tests not found — skipping${NC}"
  fi
else
  echo -e "  ${YELLOW}⚠ Skipping tests (--skip-tests)${NC}"
fi

# ── Dry run ──
if $DRY_RUN; then
  step "DRY RUN — would deploy:"
  info "• index.html → /var/www/html/index.html"
  exit 0
fi

# ── Backup ──
step "Backing up current VPS dashboard"
mkdir -p "$REPO_DIR/.rollback"
scp $SSH_OPTS "$VPS:/var/www/html/index.html" "$REPO_DIR/.rollback/index.html.$DATE" 2>/dev/null || true
info "✓ Backup saved"

# ── Deploy ──
step "Deploying to VPS"
scp $SSH_OPTS "$REPO_DIR/index.html" "$VPS:/var/www/html/index.html"
info "✓ index.html deployed"

# ── Health check ──
step "Post-deploy health check"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' https://me.thrae.ai)
if [ "$HTTP_CODE" = "200" ]; then
  info "✓ https://me.thrae.ai → $HTTP_CODE OK"
else
  echo -e "  ${RED}✗ https://me.thrae.ai → $HTTP_CODE${NC}"
  echo -e "  ${YELLOW}Rolling back...${NC}"
  scp $SSH_OPTS "$REPO_DIR/.rollback/index.html.$DATE" "$VPS:/var/www/html/index.html"
  die "Deploy failed — rolled back"
fi

echo -e "\n${GREEN}${BOLD}✅ DASHBOARD DEPLOY SUCCESSFUL${NC} ($DATE)"
