#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KOUBOU=${KOUBOU:-kou}

cd "$ROOT"
"$KOUBOU" generate marketing/screenshots/koubou-iphone.yaml
"$KOUBOU" generate marketing/screenshots/koubou-ipad.yaml

for family in iphone ipad; do
  find "marketing/screenshots/asc_out/$family" -mindepth 2 -type f -name '*.png' -exec mv {} "marketing/screenshots/asc_out/$family/" \;
  find "marketing/screenshots/asc_out/$family" -mindepth 1 -type d -empty -delete
done
