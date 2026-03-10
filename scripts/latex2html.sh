#!/bin/bash
# Convert LaTeX papers to styled HTML for GitHub Pages
# Usage: ./latex2html.sh

set -e

LATEX_DIR="/Users/mlong/Documents/Development/agentherowork/agent-os/papers/latex"
HTML_DIR="/Users/mlong/Documents/Development/agentherowork/agent-os/docs/papers"
TEMPLATE="/Users/mlong/Documents/Development/agentherowork/agent-os/scripts/paper-template.html"

papers=(
  "agent-scheduler:Agent Scheduler:Part I"
  "tool-interface:Tool Interface Layer:Part II"
  "memory-layer:Memory Layer:Part III"
  "planner-engine:Planner Engine:Part IV"
  "synthesis:Modular Synthesis:Part V"
)

for entry in "${papers[@]}"; do
  IFS=':' read -r name title part <<< "$entry"
  echo "Converting $name..."

  # Pandoc: LaTeX → HTML body (no standalone, we use our own template)
  pandoc "$LATEX_DIR/$name.tex" \
    --to html5 \
    --katex \
    --toc --toc-depth=3 \
    --number-sections \
    --no-highlight \
    --wrap=none \
    -o "/tmp/${name}-body.html" 2>/dev/null || true

  # Post-process: clean LaTeX artifacts
  sed -i '' \
    -e 's/\\texttt{\([^}]*\)}/<code>\1<\/code>/g' \
    -e 's/\\textbf{\([^}]*\)}/<strong>\1<\/strong>/g' \
    -e 's/\\emph{\([^}]*\)}/<em>\1<\/em>/g' \
    -e 's/\\textit{\([^}]*\)}/<em>\1<\/em>/g' \
    -e 's/\\textsc{\([^}]*\)}/\1/g' \
    -e 's/\\Large//g' \
    -e 's/\\LARGE//g' \
    -e 's/\\large//g' \
    -e 's/\\vspace\*\{[^}]*\}//g' \
    -e 's/\\vspace{[^}]*}//g' \
    -e 's/\\noindent//g' \
    -e 's/\\cdot/·/g' \
    -e 's/\\times/×/g' \
    -e 's/\\leq/≤/g' \
    -e 's/\\geq/≥/g' \
    -e 's/\\rightarrow/→/g' \
    -e 's/\\Rightarrow/⇒/g' \
    -e 's/\\mapsto/↦/g' \
    -e 's/\\infty/∞/g' \
    -e 's/\\alpha/α/g' \
    -e 's/\\beta/β/g' \
    -e 's/\\gamma/γ/g' \
    -e 's/\\lambda/λ/g' \
    -e 's/\\sum/Σ/g' \
    -e 's/\\forall/∀/g' \
    -e 's/\\exists/∃/g' \
    -e 's/\\in/∈/g' \
    -e 's/\\begin{lstlisting}\[[^]]*\]//g' \
    -e 's/\\begin{lstlisting}//g' \
    -e 's/\\end{lstlisting}//g' \
    -e 's/\\label{[^}]*}//g' \
    "/tmp/${name}-body.html"

  # Second pass for nested patterns
  sed -i '' \
    -e 's/\\texttt{\([^}]*\)}/<code>\1<\/code>/g' \
    -e 's/\\textbf{\([^}]*\)}/<strong>\1<\/strong>/g' \
    "/tmp/${name}-body.html"

  # Extract TOC (pandoc generates it as a <nav> block)
  # Build final HTML from template
  FULL_TITLE="$title — The AI Operating System, $part"

  # Read body content
  BODY=$(cat "/tmp/${name}-body.html")

  # Generate final file using template substitution
  sed \
    -e "s|{{TITLE}}|$FULL_TITLE|g" \
    -e "s|{{PDF_LINK}}|../latex/${name}.pdf|g" \
    -e "s|{{PART}}|$part|g" \
    "$TEMPLATE" | \
  awk -v body="$BODY" '{gsub(/{{BODY}}/, ""); print}' > "$HTML_DIR/$name.html" || true

  # If awk substitution failed due to body size, use python
  python3 -c "
import sys
template = open('$TEMPLATE').read()
body = open('/tmp/${name}-body.html').read()
result = template.replace('{{TITLE}}', '$FULL_TITLE')
result = result.replace('{{PDF_LINK}}', '../latex/${name}.pdf')
result = result.replace('{{PART}}', '$part')
result = result.replace('{{BODY}}', body)
open('$HTML_DIR/$name.html', 'w').write(result)
"

  remaining=$(grep -c '\\texttt\|\\textbf\|\\vspace\|\\Large\|\\emph\|\\textsc' "$HTML_DIR/$name.html" 2>/dev/null || echo "0")
  echo "  Done: $(wc -l < "$HTML_DIR/$name.html") lines, $remaining remaining artifacts"
done

echo "All papers converted."
