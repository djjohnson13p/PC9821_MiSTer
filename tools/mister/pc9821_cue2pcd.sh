#!/bin/bash
# MiSTer Scripts-menu entry: convert CUE/BIN CD images for the PC9821 core's CD-ROM drive.
#
# Installed by tools/mister_load.sh (and staged by tools/deploy_mister.sh) as
#   /media/fat/Scripts/pc9821_cue2pcd.sh
#   /media/fat/Scripts/.pc9821/cue2pcd.py      (tools/cue2pcd.py; the dot hides it from the menu)
# and run from the MiSTer main menu's Scripts entry, on the card itself (its Python 3).
#
# Every .cue under the core's games folder that has no up-to-date .pcd beside it is converted
# into a .pcd (same name) that the OSD's "Mount CD-ROM" takes. The .cue and .bin files are only
# read, never changed or removed; re-running it converts only what is new or changed. Free
# space is checked before each image is written. The work is cue2pcd.py's --batch mode; this
# file only finds Python and the games folder.
#
#   env: PC9821_GAMES  the folder to scan (default /media/fat/games/PC9821)

GAMES=${PC9821_GAMES:-/media/fat/games/PC9821}
HERE=$(dirname "$(readlink -f "$0")")
TOOL=$HERE/.pc9821/cue2pcd.py

echo "PC9821 core: CUE/BIN -> PCD for the CD-ROM drive"
echo "folder: $GAMES"
echo
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is not available on this system."
    exit 1
fi
if [ ! -f "$TOOL" ]; then
    echo "ERROR: $TOOL is missing; copy tools/cue2pcd.py there."
    exit 1
fi
if [ ! -d "$GAMES" ]; then
    echo "ERROR: $GAMES does not exist; put your .cue/.bin files there."
    exit 1
fi

python3 -u "$TOOL" --batch "$GAMES"
rc=$?
echo
if [ $rc -eq 0 ]; then
    echo "Done. Mount the .pcd files with the core's OSD 'Mount CD-ROM'."
else
    echo "Finished with problems (see SKIP/FAILED lines above)."
fi
exit $rc
