#!/bin/sh
# Agent: Researcher
# Reads /context/brief.md, calls LLM proxy for research, writes findings to /shared/output/
set -e

# Install tools (Alpine, ~3 seconds)
apk add --no-cache -q curl jq 2>/dev/null

echo "=== Researcher Agent Starting ==="

# Read the task brief
TOPIC=$(grep "^**Topic:**" /context/brief.md | sed 's/\*\*Topic:\*\* //')
echo "Topic: $TOPIC"

# Read any known facts from context
KNOWN_FACTS=""
if [ -f /context/known-facts.md ]; then
  KNOWN_FACTS=$(cat /context/known-facts.md)
fi

PRIOR_WORK=""
if [ -f /context/prior-work.md ]; then
  PRIOR_WORK=$(cat /context/prior-work.md)
fi

# Call LLM proxy on host for research
echo "Calling LLM for research..."

SYSTEM_PROMPT="You are a senior research analyst. Write a comprehensive research document on the given topic. Include: an executive summary, key findings organized by theme, technical details with specific examples, and a list of references. Write in markdown format. Be substantive — each section should be at least 2 paragraphs."

USER_PROMPT="Research topic: $TOPIC

Known context:
$KNOWN_FACTS

Prior work:
$PRIOR_WORK

Write a detailed research document. Output ONLY the markdown content."

RESPONSE=$(curl -s -X POST http://localhost:4000/api/v1/vm/llm/chat \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $JOB_TOKEN" \
  -d "$(jq -n \
    --arg sys "$SYSTEM_PROMPT" \
    --arg usr "$USER_PROMPT" \
    '{messages: [{role: "system", content: $sys}, {role: "user", content: $usr}], model: "gpt-4o", max_tokens: 4096}')" 2>&1)

# Check if we got a valid response
if echo "$RESPONSE" | jq -e '.content' > /dev/null 2>&1; then
  CONTENT=$(echo "$RESPONSE" | jq -r '.content')
  echo "$CONTENT" > /shared/output/findings.md
  echo "=== Research findings written ($(wc -c < /shared/output/findings.md) bytes) ==="
else
  # If LLM proxy isn't available, write a placeholder with context
  echo "# Research Findings: $TOPIC" > /shared/output/findings.md
  echo "" >> /shared/output/findings.md
  echo "## Executive Summary" >> /shared/output/findings.md
  echo "Research on: $TOPIC" >> /shared/output/findings.md
  echo "" >> /shared/output/findings.md
  echo "## Known Context" >> /shared/output/findings.md
  echo "$KNOWN_FACTS" >> /shared/output/findings.md
  echo "=== LLM proxy not available, wrote context-only findings ==="
fi

echo "=== Researcher Agent Complete ==="
