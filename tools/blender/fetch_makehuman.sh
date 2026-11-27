#!/usr/bin/env bash
# Fetch the CC0 MakeHuman asset data used by make_mh_humans.py (not stored in this repo).
# Assets (base mesh, targets, proxies, clothes, hair, skins, rig) are CC0 - see
# https://github.com/makehumancommunity/makehuman/blob/master/LICENSE.ASSETS.md
set -e
DEST="${MH_ROOT:-$HOME/mh}/core"
if [ ! -d "$DEST" ]; then
  git clone --depth 1 --filter=blob:none --sparse https://github.com/vidya-hub/makehuman-core.git "$DEST"
fi
cd "$DEST"
git sparse-checkout set --no-cone '/data/3dobjs/' '/data/rigs/' '/data/proxymeshes/' '/data/skins/' '/data/eyes/' \
  '/data/eyebrows/' '/data/eyelashes/' '/data/hair/' '/data/clothes/' '/data/targets/macrodetails/' '/data/targets/measure/' \
  '/data/targets/torso/' '/data/modifiers/'
echo "MakeHuman data in $DEST/data  (export MH_DATA=$DEST/data if not ~/mh/core/data)"
