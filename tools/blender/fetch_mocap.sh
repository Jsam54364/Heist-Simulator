#!/bin/bash
# Fetch the CMU Graphics Lab motion-capture clips the character build retargets
# (tools/blender/human_mocap.py). BVH conversion by Bruce Hahne (cgspeed), mirrored on GitHub
# by meshula/cmu-mocap. CMU: "free for all uses"; not stored in this repo.
#   bash tools/blender/fetch_mocap.sh  [dest, default ~/mocap/cmu]   then  export CMU_BVH=<dest>/data
set -e
DEST=${1:-$HOME/mocap/cmu}
CLIPS="009/09_01 016/16_35 077/77_02 077/77_29 102/102_05 105/105_31 105/105_39 111/111_19 111/111_37 113/113_01 113/113_17"
if [ ! -d "$DEST/.git" ]; then
  git clone --filter=blob:none --no-checkout https://github.com/meshula/cmu-mocap.git "$DEST"
  git -C "$DEST" sparse-checkout init --no-cone
fi
PATHS="/*.txt /*.md"
for c in $CLIPS; do PATHS="$PATHS /data/$c.bvh"; done
git -C "$DEST" sparse-checkout set --no-cone $PATHS
git -C "$DEST" checkout
echo "export CMU_BVH=$DEST/data"
