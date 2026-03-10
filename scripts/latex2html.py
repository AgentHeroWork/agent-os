#!/usr/bin/env python3
"""Convert LaTeX papers to styled HTML for GitHub Pages using pandoc + post-processing."""

import subprocess
import re
import sys
from pathlib import Path

LATEX_DIR = Path("/Users/mlong/Documents/Development/agentherowork/agent-os/papers/latex")
HTML_DIR = Path("/Users/mlong/Documents/Development/agentherowork/agent-os/docs/papers")
TEMPLATE = Path("/Users/mlong/Documents/Development/agentherowork/agent-os/scripts/paper-template.html")

PAPERS = [
    ("agent-scheduler", "Agent Scheduler", "Part I"),
    ("tool-interface", "Tool Interface Layer", "Part II"),
    ("memory-layer", "Memory Layer", "Part III"),
    ("planner-engine", "Planner Engine", "Part IV"),
    ("synthesis", "Modular Synthesis", "Part V"),
]

def clean_latex_artifacts(html: str) -> str:
    """Remove remaining LaTeX commands from pandoc HTML output."""
    # Inline commands
    html = re.sub(r'\\texttt\{([^}]*)\}', r'<code>\1</code>', html)
    html = re.sub(r'\\textbf\{([^}]*)\}', r'<strong>\1</strong>', html)
    html = re.sub(r'\\emph\{([^}]*)\}', r'<em>\1</em>', html)
    html = re.sub(r'\\textit\{([^}]*)\}', r'<em>\1</em>', html)
    html = re.sub(r'\\textsc\{([^}]*)\}', r'\1', html)
    html = re.sub(r'\\textsf\{([^}]*)\}', r'\1', html)

    # Sizing and spacing
    html = re.sub(r'\\(Large|LARGE|large|huge|Huge|small|footnotesize|tiny|normalsize)\b', '', html)
    html = re.sub(r'\\vspace\*?\{[^}]*\}', '', html)
    html = re.sub(r'\\hspace\*?\{[^}]*\}', '', html)
    html = re.sub(r'\\noindent\b', '', html)
    html = re.sub(r'\\centering\b', '', html)
    html = re.sub(r'\\raggedright\b', '', html)

    # References and labels
    html = re.sub(r'\\label\{[^}]*\}', '', html)

    # lstlisting remnants
    html = re.sub(r'\\begin\{lstlisting\}\[[^\]]*\]', '', html)
    html = re.sub(r'\\begin\{lstlisting\}', '', html)
    html = re.sub(r'\\end\{lstlisting\}', '', html)

    # Math symbols that might not render
    html = html.replace('\\cdot', '&middot;')
    html = html.replace('\\times', '&times;')
    html = html.replace('\\leq', '&le;')
    html = html.replace('\\geq', '&ge;')
    html = html.replace('\\rightarrow', '&rarr;')
    html = html.replace('\\Rightarrow', '&rArr;')
    html = html.replace('\\mapsto', '&#8614;')
    html = html.replace('\\infty', '&infin;')
    html = html.replace('\\ldots', '&hellip;')

    # Clean leftover backslash commands (catch-all for stragglers)
    html = re.sub(r'\\(par|medskip|bigskip|smallskip|newline|linebreak)\b', '', html)
    html = re.sub(r'\\(clearpage|newpage|pagebreak)\b', '', html)

    # Second pass for nested patterns
    html = re.sub(r'\\texttt\{([^}]*)\}', r'<code>\1</code>', html)
    html = re.sub(r'\\textbf\{([^}]*)\}', r'<strong>\1</strong>', html)
    html = re.sub(r'\\emph\{([^}]*)\}', r'<em>\1</em>', html)

    return html


def convert_paper(name: str, title: str, part: str) -> None:
    """Convert a single paper from LaTeX to styled HTML."""
    tex_file = LATEX_DIR / f"{name}.tex"
    html_file = HTML_DIR / f"{name}.html"
    full_title = f"{title} — The AI Operating System, {part}"

    print(f"Converting {name}...")

    # Run pandoc to get HTML body
    result = subprocess.run(
        [
            "pandoc", str(tex_file),
            "--to", "html5",
            "--katex",
            "--toc", "--toc-depth=3",
            "--number-sections",
            "--no-highlight",
            "--wrap=none",
        ],
        capture_output=True, text=True
    )

    if result.returncode != 0:
        print(f"  pandoc warning: {result.stderr[:200]}")

    body = result.stdout
    if not body.strip():
        print(f"  ERROR: pandoc produced empty output for {name}")
        return

    # Clean LaTeX artifacts
    body = clean_latex_artifacts(body)

    # Load template
    template = TEMPLATE.read_text()

    # Substitute
    html = template.replace("{{TITLE}}", full_title)
    html = html.replace("{{PDF_LINK}}", f"../latex/{name}.pdf")
    html = html.replace("{{PART}}", part)
    html = html.replace("{{BODY}}", body)

    # Write output
    html_file.write_text(html)

    # Count remaining artifacts
    remaining = len(re.findall(r'\\(texttt|textbf|vspace|Large|emph|textsc)\b', html))
    lines = html.count('\n') + 1
    print(f"  Done: {lines} lines, {remaining} remaining artifacts")


def main():
    if not TEMPLATE.exists():
        print(f"ERROR: Template not found at {TEMPLATE}")
        sys.exit(1)

    for name, title, part in PAPERS:
        convert_paper(name, title, part)

    print("\nAll papers converted.")

    # Final artifact check
    total = 0
    for name, _, _ in PAPERS:
        html = (HTML_DIR / f"{name}.html").read_text()
        count = len(re.findall(r'\\(texttt|textbf|vspace|Large|emph|textsc)\b', html))
        total += count
        if count > 0:
            print(f"  WARNING: {name}.html has {count} remaining LaTeX artifacts")

    if total == 0:
        print("  All clean — no LaTeX artifacts detected.")


if __name__ == "__main__":
    main()
