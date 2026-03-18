#!/bin/sh
# Agent: Publisher
# Reads /context/paper.tex, /context/paper.pdf, /context/README.md
# Creates GitHub repo, pushes artifacts
set -e

# Install tools
apk add --no-cache -q git curl jq 2>/dev/null

echo "=== Publisher Agent Starting ==="

# Read topic from brief
TOPIC=$(grep "^**Topic:**" /context/brief.md | sed 's/\*\*Topic:\*\* //' || echo "research")
SLUG=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-' | head -c 50)
REPO_NAME="pipeline-${SLUG}-research"
REPO="AgentHeroWork/$REPO_NAME"
REPO_URL="https://github.com/$REPO"

echo "Topic: $TOPIC"
echo "Repo: $REPO"

# Configure git
git config --global user.email "agent-os@agenthero.work"
git config --global user.name "Agent-OS Pipeline"
git config --global init.defaultBranch main

# Check if GH_TOKEN is available
if [ -z "$GH_TOKEN" ]; then
  echo "ERROR: GH_TOKEN not set — cannot create repo"
  echo "$REPO_URL" > /shared/output/repo_url.txt
  echo "=== Publisher Agent Failed (no GH_TOKEN) ==="
  exit 1
fi

# Set up git auth via token
export GIT_ASKPASS=/bin/echo
git config --global url."https://x-access-token:${GH_TOKEN}@github.com/".insteadOf "https://github.com/"

# Create repo if it doesn't exist
echo "Creating repo..."
REPO_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO" 2>&1)

if [ "$REPO_CHECK" = "200" ]; then
  echo "Repo already exists"
else
  curl -s -X POST \
    -H "Authorization: token $GH_TOKEN" \
    -H "Content-Type: application/json" \
    "https://api.github.com/orgs/AgentHeroWork/repos" \
    -d "{\"name\": \"$REPO_NAME\", \"description\": \"Research by Agent-OS Pipeline\", \"auto_init\": true}" \
    > /dev/null 2>&1
  echo "Repo created"
  sleep 2
fi

# Clone, add files, push
WORK_DIR=/tmp/repo-push
rm -rf "$WORK_DIR"
git clone "$REPO_URL" "$WORK_DIR" 2>&1 || {
  echo "Clone failed — initializing fresh"
  mkdir -p "$WORK_DIR"
  cd "$WORK_DIR"
  git init
  git remote add origin "$REPO_URL"
}

# Copy artifacts from context (previous stages' output)
for file in paper.tex paper.pdf README.md findings.md; do
  if [ -f "/context/$file" ]; then
    cp "/context/$file" "$WORK_DIR/"
    echo "Copied $file"
  fi
done

# Commit and push
cd "$WORK_DIR"
git add -A
git commit -m "Add research artifacts — Agent-OS Pipeline" 2>/dev/null || echo "Nothing to commit"
git push origin main 2>&1 || git push -u origin main 2>&1 || echo "Push failed"

echo "$REPO_URL" > /shared/output/repo_url.txt
echo "=== Publisher Agent Complete ==="
echo "Repo: $REPO_URL"
