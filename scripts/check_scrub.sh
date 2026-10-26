#!/usr/bin/env bash
# Fail if anything that looks like a real identifier, host, token or personal
# detail is present anywhere in the repo. Runs in CI alongside gitleaks; this
# is the project-specific sweep gitleaks' generic rules would not know about.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
check() {  # check <label> <extended-regex> [exclude-regex]
  local hits
  hits=$(grep -rniE --exclude-dir=.git --exclude-dir=node_modules --exclude='check_scrub.sh' -- "$2" . | grep -viE "${3:-__none__}" || true)
  if [ -n "$hits" ]; then echo "FAIL [$1]"; echo "$hits" | head -20; fail=1; fi
}

check "supabase project host"     '[a-z]{20}\.supabase\.co'
check "n8n cloud / webhook host"  '[a-z0-9-]+\.app\.n8n\.cloud|https://(n8n|hooks)\.[a-z0-9.-]+\.[a-z]{2,}'   'example\.com'
check "telegram chat id"          '"chatId": *"[0-9]{6,}"'
check "n8n credential id"         '"id": *"[A-Za-z0-9]{16}"'
check "raw webhook uuid"          '"webhookId": *"[0-9a-f-]{36}"'
check "email address"             '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}'
check "telegram bot token"        '[0-9]{8,10}:[A-Za-z0-9_-]{35}'
check "anthropic/openai key"      'sk-(ant-)?[A-Za-z0-9_-]{20,}'
check "jwt"                       'eyJ[A-Za-z0-9_-]{20,}\.eyJ'
check "github token"              'gh[pousr]_[A-Za-z0-9]{30,}'
check "withings user id"          '"?userid"?: *"?[0-9]{6,}'

if [ "$fail" -ne 0 ]; then echo; echo "scrub check failed"; exit 1; fi
echo "scrub check passed: no real identifiers or hosts found"
