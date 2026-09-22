#!/usr/bin/env bash
# Logic unit tests + generated-Lua execution test. Requires node and lua5.4.
set -euo pipefail
cd "$(dirname "$0")/.."
node --test tests/logic.test.js
fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
node tests/gen_lua_fixtures.js "$fx"
lua5.4 tests/lua_check.lua "$PWD/tests" "$fx"
echo "ALL OK"
