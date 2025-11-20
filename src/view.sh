#!/bin/bash
set -euo pipefail

OUT="$1"   # e.g. /data/output/example_input_6

# Extract basename only (example_input_6)
BASENAME="$(basename "$OUT")"

cd /home/$(whoami)/feature-3dgs

(
    python view.py \
        -s "$OUT" \
        -m "$OUT/3DGS" \
        -f sam \
        --iteration 3000 &

    SIBR_REMOTE="/home/$(whoami)/feature-3dgs/Gaussian-Splatting-Monitor/SIBR_viewers/install/bin/SIBR_remoteGaussian_app"
    "$SIBR_REMOTE"
)
