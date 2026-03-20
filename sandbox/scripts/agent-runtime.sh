#!/bin/sh
# Universal Agent Runtime — LLM-driven plan+execute+fix loop
#
# This is the ONLY script that runs inside microVMs. It reads the contract
# instructions from /context/brief.md, asks the LLM to plan which tools
# to use, executes the plan step by step, and self-repairs on failure.
#
# The contract defines WHAT. The LLM decides HOW.
set -e

# Install base tools (Alpine, ~3 seconds)
apk add --no-cache -q curl jq git bash nodejs npm python3 2>/dev/null || true

MAX_ITERATIONS=10
LLM_PROXY="http://localhost:4000/api/v1/vm/llm/chat"

echo "=== Agent Runtime Starting ==="

# 1. Read the brief (contract instructions for this stage)
BRIEF=""
if [ -f /context/brief.md ]; then
  BRIEF=$(cat /context/brief.md)
else
  echo "ERROR: No /context/brief.md found"
  exit 1
fi

# 2. Discover available context files
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

# 3. Discover available tools
TOOLS="curl, jq, git, bash, node, npm, python3"
if command -v vercel > /dev/null 2>&1; then TOOLS="$TOOLS, vercel"; fi
if command -v pdflatex > /dev/null 2>&1; then TOOLS="$TOOLS, pdflatex"; fi

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

# 4. Ask LLM to plan the approach
echo ""
echo "=== Planning ==="

PLAN_PROMPT="You are an autonomous agent running inside an isolated Linux container.

YOUR TASK:
$BRIEF

AVAILABLE TOOLS: $TOOLS
AVAILABLE CREDENTIALS: ${CREDS:-none}
OUTPUT DIRECTORY: /shared/output/ (write ALL output files here)

CONTEXT FILES AVAILABLE:
$CONTEXT_CONTENTS

CRITICAL RULES:
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

PLAN_RESPONSE=$(curl -s -X POST "$LLM_PROXY" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $JOB_TOKEN" \
  -d "$(jq -n \
    --arg prompt "$PLAN_PROMPT" \
    '{messages: [{role: "user", content: $prompt}], model: "gpt-4o", max_tokens: 8192, temperature: 0.2}')" 2>&1)

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

# 5. Execute plan step by step
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

  # Execute the command
  OUTPUT=$(eval "$CMD" 2>&1) || {
    EXIT_CODE=$?
    echo "FAILED (exit $EXIT_CODE): $OUTPUT"

    # Self-repair: ask LLM to fix
    echo "Asking LLM to fix..."

    FIX_PROMPT="A command failed during autonomous execution.

Step description: $DESC
Command: $CMD
Error output: $OUTPUT
Exit code: $EXIT_CODE

Available tools: $TOOLS
Working directory: $(pwd)

Provide a FIXED command that accomplishes the same goal. Output ONLY the shell command, nothing else."

    FIX_RESPONSE=$(curl -s -X POST "$LLM_PROXY" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $JOB_TOKEN" \
      -d "$(jq -n \
        --arg prompt "$FIX_PROMPT" \
        '{messages: [{role: "user", content: $prompt}], model: "gpt-4o", max_tokens: 2048, temperature: 0.1}')" 2>&1)

    if echo "$FIX_RESPONSE" | jq -e '.content' > /dev/null 2>&1; then
      FIXED_CMD=$(echo "$FIX_RESPONSE" | jq -r '.content' | sed 's/^```sh//' | sed 's/^```bash//' | sed 's/^```//' | sed 's/```$//' | tr -d '\n')
      echo "Fix: $FIXED_CMD"
      eval "$FIXED_CMD" 2>&1 || echo "Fix also failed — continuing"
    else
      echo "Could not get fix from LLM — continuing"
    fi
  }

  # Show truncated output
  if [ -n "$OUTPUT" ]; then
    echo "$(echo "$OUTPUT" | head -5)"
    LINES=$(echo "$OUTPUT" | wc -l | tr -d ' ')
    if [ "$LINES" -gt 5 ]; then echo "... ($LINES lines total)"; fi
  fi

  STEP_INDEX=$((STEP_INDEX + 1))
done

# 6. Verify output
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
echo "=== Agent Runtime Complete ($ITERATION iterations) ==="
