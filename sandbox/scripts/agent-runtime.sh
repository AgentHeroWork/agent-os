#!/bin/sh
# Universal Agent Runtime — LLM-driven plan+execute+fix loop
#
# This is the ONLY script that runs inside microVMs. It reads the contract
# instructions from /context/brief.md, asks the LLM to plan which tools
# to use, executes the plan step by step, and self-repairs on failure.
#
# The contract defines WHAT. The LLM decides HOW.
#
# Features:
#   - Self-installing tools (base + brief-declared + LLM-requested)
#   - Full audit logging to /shared/output/_audit.json
#   - Proof-of-work validation with auto-repair to /shared/output/_proof.json
set -e

MAX_ITERATIONS=10
LLM_PROXY="http://localhost:4000/api/v1/vm/llm/chat"
AUDIT_FILE="/shared/output/_audit.json"
PROOF_FILE="/shared/output/_proof.json"

# Timestamps and duration helpers
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
START_EPOCH=$(date +%s)

echo "=== Agent Runtime Starting ==="

# ---------------------------------------------------------------------------
# 1. Self-installing tools — base packages + brief-declared extras
# ---------------------------------------------------------------------------
echo "=== Installing Base Tools ==="
BASE_TOOLS="curl jq bash git nodejs npm python3"
apk add --no-cache -q $BASE_TOOLS 2>/dev/null || true
INSTALLED_TOOLS="$BASE_TOOLS"

# 2. Read the brief (contract instructions for this stage)
BRIEF=""
if [ -f /context/brief.md ]; then
  BRIEF=$(cat /context/brief.md)
else
  echo "ERROR: No /context/brief.md found"
  exit 1
fi

# Extract stage name from brief (first heading or first line)
STAGE=$(echo "$BRIEF" | head -20 | sed -n 's/^#\+ *//p' | head -1)
if [ -z "$STAGE" ]; then
  STAGE=$(echo "$BRIEF" | head -1 | tr -d '#' | xargs)
fi
STAGE=$(echo "$STAGE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

# Install brief-declared tools (look for "Tools:" line)
BRIEF_TOOLS=$(echo "$BRIEF" | sed -n 's/^[Tt]ools: *//p' | tr ',' ' ' | tr -s ' ')
if [ -n "$BRIEF_TOOLS" ]; then
  echo "Installing brief-declared tools: $BRIEF_TOOLS"
  for pkg in $BRIEF_TOOLS; do
    pkg=$(echo "$pkg" | tr -d ' ')
    if [ -n "$pkg" ]; then
      apk add --no-cache -q "$pkg" 2>/dev/null || echo "WARN: could not install $pkg"
      INSTALLED_TOOLS="$INSTALLED_TOOLS $pkg"
    fi
  done
fi

# 3. Discover available context files
CONTEXT_FILES=$(ls -1 /context/ 2>/dev/null | grep -v brief.md | head -20)
CONTEXT_CONTENTS=""
for f in $CONTEXT_FILES; do
  if [ -f "/context/$f" ]; then
    SIZE=$(wc -c < "/context/$f" | tr -d ' ')
    if [ "$SIZE" -lt 8000 ]; then
      CONTEXT_CONTENTS="$CONTEXT_CONTENTS
--- /context/$f ---
$(cat /context/$f)"
    else
      CONTEXT_CONTENTS="$CONTEXT_CONTENTS
--- /context/$f (${SIZE} bytes, showing first 2000) ---
$(head -c 2000 /context/$f)"
    fi
  fi
done

# 4. Discover available tools
TOOLS="curl, jq, git, bash, node, npm, python3"
if command -v vercel > /dev/null 2>&1; then TOOLS="$TOOLS, vercel"; fi
if command -v pdflatex > /dev/null 2>&1; then TOOLS="$TOOLS, pdflatex"; fi
if command -v gh > /dev/null 2>&1; then TOOLS="$TOOLS, gh"; fi

# Check for injected credentials
CREDS=""
if [ -n "$GH_TOKEN" ]; then
  CREDS="$CREDS GitHub (GH_TOKEN set),"
  git config --global user.email "agent-os@agenthero.work"
  git config --global user.name "Agent-OS Pipeline"
  git config --global init.defaultBranch main
  git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"
fi
if [ -n "$VERCEL_TOKEN" ]; then
  CREDS="$CREDS Vercel (VERCEL_TOKEN set),"
  npm install -g vercel 2>/dev/null || true
fi

echo "Tools: $TOOLS"
echo "Credentials: ${CREDS:-none}"
echo "Context files: $(echo $CONTEXT_FILES | tr '\n' ', ')"

# ---------------------------------------------------------------------------
# Audit log — initialize arrays as temp files
# ---------------------------------------------------------------------------
mkdir -p /shared/output
AUDIT_CMDS_FILE=$(mktemp)
AUDIT_LLM_FILE=$(mktemp)
echo "[]" > "$AUDIT_CMDS_FILE"
echo "[]" > "$AUDIT_LLM_FILE"
TOTAL_CMDS=0
FAILED_CMDS=0
FIXED_CMDS=0
TOTAL_LLM=0

# Helper: append a command record to audit
audit_cmd() {
  _step="$1"; _desc="$2"; _cmd="$3"; _exit="$4"; _dur="$5"; _bytes="$6"; _fixed="$7"
  if [ "$_fixed" = "true" ]; then
    _entry=$(jq -n --argjson s "$_step" --arg d "$_desc" --arg c "$_cmd" \
      --argjson e "$_exit" --argjson dur "$_dur" --argjson b "$_bytes" \
      '{step: $s, description: $d, command: $c, exit_code: $e, duration_ms: $dur, output_bytes: $b, fixed: true}')
  else
    _entry=$(jq -n --argjson s "$_step" --arg d "$_desc" --arg c "$_cmd" \
      --argjson e "$_exit" --argjson dur "$_dur" --argjson b "$_bytes" \
      '{step: $s, description: $d, command: $c, exit_code: $e, duration_ms: $dur, output_bytes: $b}')
  fi
  _cur=$(cat "$AUDIT_CMDS_FILE")
  echo "$_cur" | jq --argjson e "$_entry" '. + [$e]' > "$AUDIT_CMDS_FILE"
}

# Helper: append an LLM call record to audit
audit_llm() {
  _type="$1"; _model="$2"; _dur="$3"; _step="$4"
  if [ -n "$_step" ]; then
    _entry=$(jq -n --arg t "$_type" --arg m "$_model" --argjson d "$_dur" --argjson s "$_step" \
      '{type: $t, model: $m, duration_ms: $d, step: $s}')
  else
    _entry=$(jq -n --arg t "$_type" --arg m "$_model" --argjson d "$_dur" \
      '{type: $t, model: $m, duration_ms: $d}')
  fi
  _cur=$(cat "$AUDIT_LLM_FILE")
  echo "$_cur" | jq --argjson e "$_entry" '. + [$e]' > "$AUDIT_LLM_FILE"
}

# ---------------------------------------------------------------------------
# 5. Ask LLM to plan the approach
# ---------------------------------------------------------------------------
echo ""
echo "=== Planning ==="

PLAN_PROMPT="You are an autonomous agent running inside an isolated Alpine Linux container.

YOUR TASK:
$BRIEF

AVAILABLE TOOLS: $TOOLS
AVAILABLE CREDENTIALS: ${CREDS:-none}
OUTPUT DIRECTORY: /shared/output/ (write ALL output files here)

CONTEXT FILES AVAILABLE:
$CONTEXT_CONTENTS

CRITICAL RULES:
- You are running in Alpine Linux. Install any additional tool you need with: apk add <package-name>
- Common Alpine packages: curl, jq, git, bash, nodejs, npm, python3, github-cli, openssh
- ALWAYS install github-cli before using gh commands: apk add github-cli
- ALWAYS install tools in the FIRST step of your plan
- Install any tool you need FIRST using: apk add <package-name>
- You have NO access to external APIs or websites. Do NOT use curl to fetch data from APIs.
- Generate all content from YOUR OWN KNOWLEDGE. You are an expert — write the data yourself.
- For JSON data files, write them directly using cat/heredoc or a python/node script.
- For markdown files, write them directly using cat/heredoc.
- For HTML/CSS/JS dashboards, write a python script that generates the complete file.
- Use real, specific, accurate data from your training knowledge.
- If credentials are available (GH_TOKEN, VERCEL_TOKEN), use git/vercel CLI tools for deployment.

INSTRUCTIONS:
1. Plan your approach step by step
2. For each step, provide the EXACT shell command to run
3. Use the context files to inform your work
4. Write all output to /shared/output/
5. If you need to create directories, use mkdir -p
6. For large file generation, write a python3 script to /tmp/gen.py then run it

OUTPUT FORMAT — respond with ONLY a JSON array of steps:
[
  {\"description\": \"what this step does\", \"command\": \"the exact shell command\"},
  {\"description\": \"next step\", \"command\": \"next command\"},
  ...
]

IMPORTANT:
- Output ONLY the JSON array, no markdown fences, no explanation
- Each command must be a single shell command (use && to chain if needed)
- For multi-line file writes, use heredoc: cat > /shared/output/file.md << 'HEREDOC' ... HEREDOC
- For complex file generation, write a python3 or node script to /tmp/ first, then execute it
- NEVER try to curl/fetch external URLs for data — generate everything from your knowledge"

LLM_START=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

PLAN_RESPONSE=$(curl -s -X POST "$LLM_PROXY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $JOB_TOKEN" \
  -d "$(jq -n \
    --arg prompt "$PLAN_PROMPT" \
    '{messages: [{role: "user", content: $prompt}], model: "gpt-4o", max_tokens: 8192, temperature: 0.2}')" 2>&1)

LLM_END=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
LLM_DUR=$((LLM_END - LLM_START))
TOTAL_LLM=$((TOTAL_LLM + 1))
audit_llm "plan" "gpt-4o" "$LLM_DUR"

# Extract content from LLM response
PLAN=""
if echo "$PLAN_RESPONSE" | jq -e '.content' > /dev/null 2>&1; then
  PLAN=$(echo "$PLAN_RESPONSE" | jq -r '.content')
else
  echo "ERROR: LLM proxy not available or returned invalid response"
  echo "Response: $(echo "$PLAN_RESPONSE" | head -c 500)"
  exit 1
fi

# Strip markdown code fences if present
PLAN=$(echo "$PLAN" | sed 's/^```json//' | sed 's/^```//' | sed 's/```$//')

# Validate JSON
if ! echo "$PLAN" | jq -e '.' > /dev/null 2>&1; then
  echo "ERROR: LLM returned invalid JSON plan"
  echo "Plan: $(echo "$PLAN" | head -c 500)"
  exit 1
fi

STEP_COUNT=$(echo "$PLAN" | jq 'length')
echo "Plan: $STEP_COUNT steps"

# ---------------------------------------------------------------------------
# 6. Execute plan step by step
# ---------------------------------------------------------------------------
echo ""
echo "=== Executing ==="

ITERATION=0
STEP_INDEX=0

while [ "$STEP_INDEX" -lt "$STEP_COUNT" ] && [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  DESC=$(echo "$PLAN" | jq -r ".[$STEP_INDEX].description")
  CMD=$(echo "$PLAN" | jq -r ".[$STEP_INDEX].command")

  echo ""
  echo "--- Step $((STEP_INDEX + 1))/$STEP_COUNT: $DESC ---"
  echo "\$ $CMD"

  # Execute the command with timing
  CMD_START=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
  CMD_EXIT=0
  OUTPUT=$(eval "$CMD" 2>&1) || CMD_EXIT=$?
  CMD_END=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
  CMD_DUR=$((CMD_END - CMD_START))
  OUTPUT_BYTES=$(printf '%s' "$OUTPUT" | wc -c | tr -d ' ')
  TOTAL_CMDS=$((TOTAL_CMDS + 1))

  if [ "$CMD_EXIT" -ne 0 ]; then
    FAILED_CMDS=$((FAILED_CMDS + 1))
    echo "FAILED (exit $CMD_EXIT): $OUTPUT"

    # Record the failed command
    audit_cmd "$((STEP_INDEX + 1))" "$DESC" "$CMD" "$CMD_EXIT" "$CMD_DUR" "$OUTPUT_BYTES" "false"

    # Self-repair: ask LLM to fix
    echo "Asking LLM to fix..."

    FIX_PROMPT="A command failed during autonomous execution.

Step description: $DESC
Command: $CMD
Error output: $OUTPUT
Exit code: $CMD_EXIT

Available tools: $TOOLS
Working directory: $(pwd)

You are running in Alpine Linux. Install any additional tool you need with: apk add <package>.

Provide a FIXED command that accomplishes the same goal. Output ONLY the shell command, nothing else."

    FIX_LLM_START=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

    FIX_RESPONSE=$(curl -s -X POST "$LLM_PROXY" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $JOB_TOKEN" \
      -d "$(jq -n \
        --arg prompt "$FIX_PROMPT" \
        '{messages: [{role: "user", content: $prompt}], model: "gpt-4o", max_tokens: 2048, temperature: 0.1}')" 2>&1)

    FIX_LLM_END=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
    FIX_LLM_DUR=$((FIX_LLM_END - FIX_LLM_START))
    TOTAL_LLM=$((TOTAL_LLM + 1))
    audit_llm "fix" "gpt-4o" "$FIX_LLM_DUR" "$((STEP_INDEX + 1))"

    if echo "$FIX_RESPONSE" | jq -e '.content' > /dev/null 2>&1; then
      FIXED_CMD=$(echo "$FIX_RESPONSE" | jq -r '.content' | sed 's/^```sh//' | sed 's/^```bash//' | sed 's/^```//' | sed 's/```$//' | tr -d '\n')
      echo "Fix: $FIXED_CMD"

      FIX_CMD_START=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
      FIX_EXIT=0
      FIX_OUTPUT=$(eval "$FIXED_CMD" 2>&1) || FIX_EXIT=$?
      FIX_CMD_END=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
      FIX_CMD_DUR=$((FIX_CMD_END - FIX_CMD_START))
      FIX_OUTPUT_BYTES=$(printf '%s' "$FIX_OUTPUT" | wc -c | tr -d ' ')
      TOTAL_CMDS=$((TOTAL_CMDS + 1))

      if [ "$FIX_EXIT" -eq 0 ]; then
        FIXED_CMDS=$((FIXED_CMDS + 1))
        audit_cmd "$((STEP_INDEX + 1))" "$DESC (fix)" "$FIXED_CMD" "$FIX_EXIT" "$FIX_CMD_DUR" "$FIX_OUTPUT_BYTES" "true"
        # Track any tools installed by fix command
        FIX_PKGS=$(echo "$FIXED_CMD" | sed -n 's/.*apk add[^;|&]* //p' | tr -s ' ')
        if [ -n "$FIX_PKGS" ]; then
          INSTALLED_TOOLS="$INSTALLED_TOOLS $FIX_PKGS"
        fi
      else
        echo "Fix also failed (exit $FIX_EXIT) — continuing"
        audit_cmd "$((STEP_INDEX + 1))" "$DESC (fix-failed)" "$FIXED_CMD" "$FIX_EXIT" "$FIX_CMD_DUR" "$FIX_OUTPUT_BYTES" "false"
      fi
    else
      echo "Could not get fix from LLM — continuing"
    fi
  else
    # Success
    audit_cmd "$((STEP_INDEX + 1))" "$DESC" "$CMD" "0" "$CMD_DUR" "$OUTPUT_BYTES" "false"

    # Track any tools installed by this command
    CMD_PKGS=$(echo "$CMD" | sed -n 's/.*apk add[^;|&]* //p' | tr -s ' ')
    if [ -n "$CMD_PKGS" ]; then
      INSTALLED_TOOLS="$INSTALLED_TOOLS $CMD_PKGS"
    fi
  fi

  # Show truncated output
  if [ -n "$OUTPUT" ]; then
    echo "$(echo "$OUTPUT" | head -5)"
    LINES=$(echo "$OUTPUT" | wc -l | tr -d ' ')
    if [ "$LINES" -gt 5 ]; then echo "... ($LINES lines total)"; fi
  fi

  STEP_INDEX=$((STEP_INDEX + 1))
done

# ---------------------------------------------------------------------------
# 7. Proof-of-work validation
# ---------------------------------------------------------------------------
echo ""
echo "=== Proof-of-Work Validation ==="

PROOF_CHECKS_FILE=$(mktemp)
echo "[]" > "$PROOF_CHECKS_FILE"
ALL_PASSED=true
REPAIR_ATTEMPTS=0

# Helper: add a proof check
add_check() {
  _chk="$1"; _file="$2"; _passed="$3"; _extra="$4"
  if [ -n "$_extra" ]; then
    _entry=$(jq -n --arg c "$_chk" --arg f "$_file" --argjson p "$_passed" \
      "{check: \$c, file: \$f, passed: \$p, $_extra}")
  else
    _entry=$(jq -n --arg c "$_chk" --arg f "$_file" --argjson p "$_passed" \
      '{check: $c, file: $f, passed: $p}')
  fi
  _cur=$(cat "$PROOF_CHECKS_FILE")
  echo "$_cur" | jq --argjson e "$_entry" '. + [$e]' > "$PROOF_CHECKS_FILE"
}

# Run proof checks (returns failures as text, empty = all pass)
run_proof_checks() {
  _failures=""
  # Reset checks file for re-run
  echo "[]" > "$PROOF_CHECKS_FILE"
  _all_ok=true

  for _file in /shared/output/*; do
    [ -f "$_file" ] || continue
    _basename=$(basename "$_file")
    # Skip audit and proof files
    case "$_basename" in _audit.json|_proof.json) continue;; esac

    _ext="${_basename##*.}"
    case "$_ext" in
      json)
        if jq . "$_file" > /dev/null 2>&1; then
          add_check "valid_json" "$_basename" "true"
          echo "  PASS: $_basename (valid JSON)"
        else
          add_check "valid_json" "$_basename" "false"
          _failures="$_failures\nFAIL: $_basename is not valid JSON"
          _all_ok=false
          echo "  FAIL: $_basename (invalid JSON)"
        fi
        ;;
      html)
        _has_open=$(grep -c '<html' "$_file" 2>/dev/null || echo 0)
        _has_close=$(grep -c '</html>' "$_file" 2>/dev/null || echo 0)
        if [ "$_has_open" -gt 0 ] && [ "$_has_close" -gt 0 ]; then
          add_check "valid_html" "$_basename" "true"
          echo "  PASS: $_basename (valid HTML structure)"
        else
          add_check "valid_html" "$_basename" "false"
          _failures="$_failures\nFAIL: $_basename missing <html> or </html> tags"
          _all_ok=false
          echo "  FAIL: $_basename (missing HTML tags)"
        fi
        ;;
      md)
        _sz=$(wc -c < "$_file" | tr -d ' ')
        if [ "$_sz" -gt 100 ]; then
          add_check "min_bytes" "$_basename" "true" "\"expected\": 100, \"actual\": $_sz"
          echo "  PASS: $_basename ($_sz bytes)"
        else
          add_check "min_bytes" "$_basename" "false" "\"expected\": 100, \"actual\": $_sz"
          _failures="$_failures\nFAIL: $_basename is only $_sz bytes (need >100)"
          _all_ok=false
          echo "  FAIL: $_basename (only $_sz bytes, need >100)"
        fi
        ;;
      txt)
        # Check if file contains URLs, and if so validate them
        _urls=$(grep -oE 'https?://[^ ]+' "$_file" 2>/dev/null || true)
        if [ -n "$_urls" ]; then
          for _url in $_urls; do
            _code=$(curl -s -o /dev/null -w "%{http_code}" -L --connect-timeout 5 "$_url" 2>/dev/null || echo "000")
            if [ "$_code" -ge 200 ] && [ "$_code" -lt 400 ]; then
              add_check "url_reachable" "$_basename" "true" "\"url\": \"$_url\", \"http_code\": $_code"
              echo "  PASS: $_basename URL $_url ($_code)"
            else
              add_check "url_reachable" "$_basename" "false" "\"url\": \"$_url\", \"http_code\": $_code"
              _failures="$_failures\nFAIL: $_basename URL $_url returned $_code"
              _all_ok=false
              echo "  FAIL: $_basename URL $_url ($_code)"
            fi
          done
        else
          # No URLs in txt — just check non-empty
          _sz=$(wc -c < "$_file" | tr -d ' ')
          if [ "$_sz" -gt 0 ]; then
            add_check "non_empty" "$_basename" "true"
            echo "  PASS: $_basename (non-empty, $_sz bytes)"
          else
            add_check "non_empty" "$_basename" "false"
            _failures="$_failures\nFAIL: $_basename is empty"
            _all_ok=false
            echo "  FAIL: $_basename (empty)"
          fi
        fi
        ;;
    esac
  done

  if [ "$_all_ok" = "true" ]; then
    ALL_PASSED=true
  else
    ALL_PASSED=false
  fi
  printf '%s' "$_failures"
}

# First proof run
FAILURES=$(run_proof_checks)

# Repair loop (max 2 attempts)
while [ -n "$FAILURES" ] && [ "$REPAIR_ATTEMPTS" -lt 2 ]; do
  REPAIR_ATTEMPTS=$((REPAIR_ATTEMPTS + 1))
  echo ""
  echo "--- Proof-of-work repair attempt $REPAIR_ATTEMPTS ---"

  REPAIR_PROMPT="Some output files failed proof-of-work validation. Fix them.

FAILURES:
$(printf '%s' "$FAILURES")

OUTPUT DIRECTORY: /shared/output/
Available tools: $TOOLS

You are running in Alpine Linux. Install any tool you need with: apk add <package>.

Provide a JSON array of fix commands:
[{\"description\": \"what to fix\", \"command\": \"fix command\"}]

Output ONLY the JSON array."

  REPAIR_LLM_START=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))

  REPAIR_RESPONSE=$(curl -s -X POST "$LLM_PROXY" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $JOB_TOKEN" \
    -d "$(jq -n \
      --arg prompt "$REPAIR_PROMPT" \
      '{messages: [{role: "user", content: $prompt}], model: "gpt-4o", max_tokens: 4096, temperature: 0.1}')" 2>&1)

  REPAIR_LLM_END=$(date +%s%3N 2>/dev/null || echo $(($(date +%s) * 1000)))
  REPAIR_LLM_DUR=$((REPAIR_LLM_END - REPAIR_LLM_START))
  TOTAL_LLM=$((TOTAL_LLM + 1))
  audit_llm "proof-repair" "gpt-4o" "$REPAIR_LLM_DUR"

  REPAIR_PLAN=""
  if echo "$REPAIR_RESPONSE" | jq -e '.content' > /dev/null 2>&1; then
    REPAIR_PLAN=$(echo "$REPAIR_RESPONSE" | jq -r '.content' | sed 's/^```json//' | sed 's/^```//' | sed 's/```$//')
  fi

  if echo "$REPAIR_PLAN" | jq -e '.' > /dev/null 2>&1; then
    REPAIR_COUNT=$(echo "$REPAIR_PLAN" | jq 'length')
    _ri=0
    while [ "$_ri" -lt "$REPAIR_COUNT" ]; do
      _rdesc=$(echo "$REPAIR_PLAN" | jq -r ".[$_ri].description")
      _rcmd=$(echo "$REPAIR_PLAN" | jq -r ".[$_ri].command")
      echo "  Repair: $_rdesc"
      eval "$_rcmd" 2>&1 || echo "  Repair command failed — continuing"
      _ri=$((_ri + 1))
    done
  else
    echo "  Could not parse repair plan from LLM"
  fi

  # Re-run checks
  FAILURES=$(run_proof_checks)
done

if [ "$ALL_PASSED" = "true" ]; then
  echo "All proof-of-work checks passed."
else
  echo "WARNING: Some proof-of-work checks still failing after $REPAIR_ATTEMPTS repair attempts."
fi

# Write _proof.json
jq -n \
  --arg stage "$STAGE" \
  --argjson passed "$ALL_PASSED" \
  --argjson checks "$(cat "$PROOF_CHECKS_FILE")" \
  --argjson repairs "$REPAIR_ATTEMPTS" \
  '{stage: $stage, all_passed: $passed, checks: $checks, repair_attempts: $repairs}' \
  > "$PROOF_FILE"

echo "Wrote $PROOF_FILE"

# ---------------------------------------------------------------------------
# 8. Write audit log
# ---------------------------------------------------------------------------
echo ""
echo "=== Writing Audit Log ==="

COMPLETED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
END_EPOCH=$(date +%s)
DURATION_SECONDS=$((END_EPOCH - START_EPOCH))

# Deduplicate installed tools list
TOOLS_JSON=$(echo "$INSTALLED_TOOLS" | tr ' ' '\n' | sort -u | grep -v '^$' | jq -R . | jq -s .)

jq -n \
  --arg stage "$STAGE" \
  --arg started "$STARTED_AT" \
  --arg completed "$COMPLETED_AT" \
  --argjson duration "$DURATION_SECONDS" \
  --argjson tools "$TOOLS_JSON" \
  --argjson cmds "$(cat "$AUDIT_CMDS_FILE")" \
  --argjson llm "$(cat "$AUDIT_LLM_FILE")" \
  --argjson total_cmds "$TOTAL_CMDS" \
  --argjson failed_cmds "$FAILED_CMDS" \
  --argjson fixed_cmds "$FIXED_CMDS" \
  --argjson total_llm "$TOTAL_LLM" \
  '{
    stage: $stage,
    started_at: $started,
    completed_at: $completed,
    duration_seconds: $duration,
    tools_installed: $tools,
    commands: $cmds,
    llm_calls: $llm,
    total_commands: $total_cmds,
    failed_commands: $failed_cmds,
    fixed_commands: $fixed_cmds,
    total_llm_calls: $total_llm
  }' > "$AUDIT_FILE"

echo "Wrote $AUDIT_FILE"

# Clean up temp files
rm -f "$AUDIT_CMDS_FILE" "$AUDIT_LLM_FILE" "$PROOF_CHECKS_FILE"

# ---------------------------------------------------------------------------
# 9. Final output summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Output Verification ==="
if [ -d /shared/output ]; then
  echo "Files in /shared/output/:"
  find /shared/output -type f | while read f; do
    SIZE=$(wc -c < "$f" | tr -d ' ')
    echo "  $f ($SIZE bytes)"
  done
else
  echo "WARNING: /shared/output/ is empty"
fi

echo ""
echo "=== Agent Runtime Complete ($ITERATION iterations, ${DURATION_SECONDS}s) ==="
