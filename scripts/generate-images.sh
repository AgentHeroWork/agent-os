#!/bin/bash
# Generate cover images from PDF first pages
# Requires: poppler (pdftoppm)

set -euo pipefail

PAPERS_DIR="papers/pdf"
IMAGES_DIR="images"

mkdir -p "$IMAGES_DIR"

for pdf in "$PAPERS_DIR"/*.pdf; do
  [ -f "$pdf" ] || continue
  name=$(basename "$pdf" .pdf)
  echo "Generating image for: $name"
  pdftoppm -png -f 1 -l 1 -r 300 "$pdf" "$IMAGES_DIR/$name"
  mv "$IMAGES_DIR/${name}-1.png" "$IMAGES_DIR/${name}.png"
  echo "  → $IMAGES_DIR/${name}.png"
done

echo "Done. Generated $(ls -1 "$IMAGES_DIR"/*.png 2>/dev/null | wc -l) images."
