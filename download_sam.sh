#!/bin/bash

wget -c --tries=10 --timeout=30 --retry-connrefused \
    -O $(pwd)/weights/sam_vit_h_4b8939.pth \
    https://dl.fbaipublicfiles.com/segment_anything/sam_vit_h_4b8939.pth
