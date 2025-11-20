#!/bin/bash
set -euo pipefail

INPUT="$1"   # e.g. /data/example_input_6.png

DIR="$(dirname "$INPUT")"

FILENAME="$(basename "$INPUT")"
BASENAME="${FILENAME%.*}"

OUT="$DIR/output"

cd /home/$(whoami)/OpenCubeDiff && python pano_diff.py -i "$INPUT" -o "$OUT"

colmap feature_extractor \
    --database_path $OUT/$BASENAME/database.db \
    --image_path $OUT/$BASENAME/images \
    --ImageReader.camera_model=SIMPLE_PINHOLE \
    --ImageReader.single_camera=1 \
    --SiftExtraction.max_num_features=16384

colmap exhaustive_matcher \
    --database_path $OUT/$BASENAME/database.db \
    --ExhaustiveMatching.block_size=10

cd /home/$(whoami)

/SphereSfM/spherical-sfm/build/examples/run_spherical_sfm_uncalib \
    -output $OUT/$BASENAME \
    -images $OUT/$BASENAME/images \
    -colmap \
    -generalba

mkdir -p $OUT/$BASENAME/sparse/0

colmap model_converter \
    --input_path $OUT/$BASENAME/sparse \
    --output_path $OUT/$BASENAME/sparse/0 \
    --output_type BIN

cd /home/$(whoami)/feature-3dgs/encoders/sam_encoder && \
    python export_image_embeddings.py --checkpoint checkpoints/sam_vit_h_4b8939.pth --model-type vit_h --input $OUT/$BASENAME/images  --output $OUT/$BASENAME/sam_embeddings

cd /home/$(whoami)/feature-3dgs && python train.py -s $OUT/$BASENAME -m $OUT/$BASENAME/3DGS -f sam --speedup --iterations 3000 --resolution 1

cd /home/$(whoami)/feature-3dgs && \
(
    python view.py -s "$OUT/$BASENAME" -m "$OUT/$BASENAME/3DGS" -f sam --iteration 3000 &
    SIBR_REMOTE=/home/$(whoami)/feature-3dgs/Gaussian-Splatting-Monitor/SIBR_viewers/install/bin/SIBR_remoteGaussian_app
    "$SIBR_REMOTE"
)