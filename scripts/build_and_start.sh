#!/bin/bash
set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------

ORG="singularity"
TAG="latest"

BASE_IMAGE="${ORG}/base:${TAG}"
SFM_IMAGE="${ORG}/sfm:${TAG}"
PANO_IMAGE="${ORG}/pano:${TAG}"
GAUSS_IMAGE="${ORG}/gauss:${TAG}"

USERNAME="$(whoami)"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
DOCKER_DIR="./docker"

# Default container to run interactively
RUN_CONTAINER="singularity3d"
RUN_IMAGE="${GAUSS_IMAGE}"

# ------------------------------------------------------------------------------
# DOCKERFILE PATHS
# ------------------------------------------------------------------------------
declare -A DOCKER_BUILDS=(
  ["${BASE_IMAGE}"]="${DOCKER_DIR}/Dockerfile.base"
  ["${SFM_IMAGE}"]="${DOCKER_DIR}/Dockerfile.sfm"
  ["${PANO_IMAGE}"]="${DOCKER_DIR}/Dockerfile.pano"
  ["${GAUSS_IMAGE}"]="${DOCKER_DIR}/Dockerfile.gauss"
)

# ------------------------------------------------------------------------------
# PARENT IMAGE MAPPING
# ------------------------------------------------------------------------------

# Build dependencies must form a DAG:
# base   → CUDA/conda base
# sfm    → base
# pano   → sfm
# gauss  → pano

declare -A PARENTS=(
  ["${BASE_IMAGE}"]="nvcr.io/nvidia/cuda-dl-base:25.10-cuda13.0-devel-ubuntu24.04"
  ["${SFM_IMAGE}"]="${BASE_IMAGE}"
  ["${PANO_IMAGE}"]="${SFM_IMAGE}"
  ["${GAUSS_IMAGE}"]="${PANO_IMAGE}"
)

# Build order: BASE → SFM → PANO → GAUSS
BUILD_SEQUENCE=("${BASE_IMAGE}" "${SFM_IMAGE}" "${PANO_IMAGE}" "${GAUSS_IMAGE}")

# ------------------------------------------------------------------------------
# Helper: build one image
# ------------------------------------------------------------------------------
build_image() {
  local image_tag="$1"
  local dockerfile="$2"
  local base_from="${PARENTS[$image_tag]}"

  echo "Building '${image_tag}' using parent '${base_from}'..."

  DOCKER_BUILDKIT=1 docker build \
    --build-arg BASE_FROM="${base_from}" \
    --build-arg USERNAME="${USERNAME}" \
    --build-arg USER_UID="${HOST_UID}" \
    --build-arg USER_GID="${HOST_GID}" \
    -t "${image_tag}" \
    -f "${dockerfile}" .
}

# ------------------------------------------------------------------------------
# If container already running → attach
# ------------------------------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -q "^${RUN_CONTAINER}$"; then
  echo "Container '${RUN_CONTAINER}' already running. Attaching..."
  exec docker exec -it "${RUN_CONTAINER}" bash
fi

# ------------------------------------------------------------------------------
# Build all images in order
# ------------------------------------------------------------------------------
for image in "${BUILD_SEQUENCE[@]}"; do
  build_image "${image}" "${DOCKER_BUILDS[$image]}"
done

# ------------------------------------------------------------------------------
# Enable GUI (X11)
# ------------------------------------------------------------------------------
echo "Enabling X11 permissions..."
xhost +local:docker >/dev/null 2>&1
xhost +SI:localuser:"${USERNAME}" >/dev/null 2>&1

# ------------------------------------------------------------------------------
# Launch the primary container (GAUSS)
# ------------------------------------------------------------------------------
echo "Launching '${RUN_CONTAINER}' using image '${RUN_IMAGE}'..."

docker run -it --rm \
  --runtime=nvidia \
  --gpus all \
  --privileged \
  --net=host \
  --pid=host \
  --ipc=host \
  --name "${RUN_CONTAINER}" \
  -e DISPLAY="${DISPLAY}" \
  --cap-add=SYS_PTRACE \
  --security-opt seccomp=unconfined \
  -e NVIDIA_DRIVER_CAPABILITIES=all \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -e XDG_RUNTIME_DIR=/tmp/runtime-root \
  -v /tmp/runtime-root:/tmp/runtime-root \
  -v "$HOME/.Xauthority":/root/.Xauthority \
  -v $(pwd)/data:/data \
  -v $(pwd)/src/pano_diff.py:/home/"${USERNAME}"/OpenCubeDiff/pano_diff.py \
  -v $(pwd)/src/singularity.sh:/home/"${USERNAME}"/singularity.sh \
  -v $(pwd)/src/view.sh:/home/"${USERNAME}"/view.sh \
  -v $(pwd)/weights/sam_vit_h_4b8939.pth:/home/"${USERNAME}"/feature-3dgs/encoders/sam_encoder/checkpoints/sam_vit_h_4b8939.pth \
  --user "${HOST_UID}:${HOST_GID}" \
  "${RUN_IMAGE}"