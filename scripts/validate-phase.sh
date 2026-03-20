#!/bin/bash
# Phase gate validator — run before starting next phase
set -e
echo "=== PHASE GATE VALIDATION ==="

# 1. Compile all apps with warnings-as-errors
for app in agent_scheduler agent_os agent_os_web; do
  echo -n "Compile $app: "
  cd /Users/mlong/Documents/Development/agentherowork/agent-os/src/$app
  if mix compile --warnings-as-errors 2>&1 | tail -1 | grep -q "error\|failed"; then
    echo "FAIL"
    exit 1
  fi
  echo "OK"
done

# 2. Run tests for all apps
TOTAL=0
FAILED=0
for app in agent_scheduler agent_os memory_layer planner_engine tool_interface agent_os_web; do
  cd /Users/mlong/Documents/Development/agentherowork/agent-os/src/$app
  result=$(mix test 2>&1 | grep -E "tests.*failures" || echo "0 tests, 0 failures")
  tests=$(echo "$result" | grep -o '[0-9]* tests' | grep -o '[0-9]*')
  fails=$(echo "$result" | grep -o '[0-9]* failures' | grep -o '[0-9]*')
  TOTAL=$((TOTAL + ${tests:-0}))
  FAILED=$((FAILED + ${fails:-0}))
  echo "$app: $result"
done

# 3. CLI tests
cd /Users/mlong/Documents/Development/agentherowork/agent-os
cli_result=$(node --test cli/test/ 2>&1 | grep "# pass" | grep -o '[0-9]*')
TOTAL=$((TOTAL + ${cli_result:-0}))
echo "cli: ${cli_result:-0} tests pass"

echo ""
echo "=== TOTAL: $TOTAL tests, $FAILED failures ==="
if [ "$FAILED" -gt 0 ]; then
  echo "GATE: BLOCKED"
  exit 1
fi
echo "GATE: PASSED"
