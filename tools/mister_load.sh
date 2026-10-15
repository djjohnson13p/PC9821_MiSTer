#!/usr/bin/env bash
# Upload the PC-9821 z486 core to the MiSTer and load it, using MiSTer's command
# FIFO (load_core) -- no OSD interaction.
#
# ONE JOB: this is the tool that PROVISIONS the card. It writes the RBF, the firmware
# packs (each verified against your dumps first), the MGLs and the disk image, then
# starts the core. Its three neighbours each do something else and none of them
# provision:
#   tools/deploy_mister.sh  stages the same set into mister_deploy/ for a manual copy
#                           to the card; it never opens a connection
#   tools/mister_packs.sh   manages the pack files already ON the card (list, stash,
#                           switch); it never builds or verifies one
#   tools/run_on_mister.sh  starts the core and reads its telemetry; it writes no file
#
# One core, one MGL per firmware set. The RBF is shared; each MGL points at its own
# pack, so the menu offers each machine's firmware as its own entry:
#
#   _Computer/PC9821Z486.rbf          the core (one file)
#   PC9821Z486.mgl                    the default set (xe10)
#   PC9821Z486-xe.mgl                 the other set
#   games/PC9821/pc98pack-xe10.bin    the packs, from your own dumps
#   games/PC9821/pc98pack-xe.bin
#
#   tools/mister_load.sh                 # default set: RBF + pack + MGL + image, load
#   tools/mister_load.sh --both          # both sets' packs and MGLs
#   tools/mister_load.sh --machine xe    # select the other set
#   tools/mister_load.sh --packs-only    # packs and MGLs only, without the RBF
#   tools/mister_load.sh --no-copy       # reload the installed core
#   tools/mister_load.sh --no-image      # deploy without a disk entry
#   tools/mister_load.sh --fdd0 A.d88 --fdd1 B.d88
#                                        # also list a floppy per DRIVE in the MGL
#                                        # (hps_io slots 1 and 2); the OSD's own S1/S2
#                                        # entries mount either drive at any time
#   tools/mister_load.sh --pack          # replace the pack already on the card
#   tools/mister_load.sh --dumps DIR     # where the machine dumps live (see below)
#   tools/mister_load.sh --skip-pack-check   # do NOT verify the local pack against
#                                            # the dumps (for hosts without them)
#   tools/mister_load.sh --allow-stale-pack  # accept a card pack that differs from
#                                            # the local build instead of failing
#
# The local pack (build/pc98pack-<machine>.bin) is verified against the dumps with
# tools/check_pack.py BEFORE it is deployed, and a pack already on the card that
# differs from that verified build is a hard failure: the transfer check can only
# prove the card got the local file's bytes, never that the local file is the
# dumps. That gap is what let a stale pc98pack-xe10.bin (0xF8000 window missing
# BANK7.BIN) sit on the card while every deploy printed "verified", and the guest
# showed ROM SUM ERROR. The dumps are found at $PC98_DUMPS (or $BIOS_DIR), the
# machine's own subdirectory first: <base>/<machine>/BANK4.BIN, else <base>/BANK4.BIN.
#
#   env: MISTER_HOST (ssh destination, default root@MiSTer; a bare host name gets root@),
#        MISTER_PASS (default 1, the stock root password, through sshpass -e; empty = ssh keys),
#        MISTER_CORE (default PC9821Z486),
#        PC98_DUMPS / BIOS_DIR (default ./bios),
#        MISTER_IMG  (path to a PC-98 .img to upload+mount; default: mount
#                     hdd.img if it is already on the card),
#        MISTER_FDD0 / MISTER_FDD1 (floppy images to upload and list for drive 0
#                     and drive 1; the same as --fdd0/--fdd1)
set -eu
cd "$(dirname "$0")/.."

HOST=${MISTER_HOST:-root@MiSTer}
case $HOST in *@*) ;; *) HOST=root@$HOST ;; esac
RBF=output_files/z486_mister.rbf
CORE=${MISTER_CORE:-PC9821Z486}
DEST=/media/fat/_Computer/$CORE.rbf
# The MGL's <setname> is what MiSTer names the core's per-core CONFIG file after, so this
# one value decides BOTH the MGL written below and the config path inspected below it. It
# is NOT the RBF name: the card's config directory is keyed by setname (it holds
# Genesis.CFG, SNES.CFG and MegaCD.CFG for those cores), so this core's is PC9821.CFG and
# PC9821Z486.CFG has never existed. A config test built on the RBF name silently inspects
# nothing and reports 'none needed' whatever the card holds, which defeats the warning this
# script exists to give; tools/check_mister_layout.py fails if the two ever disagree.
SETNAME=PC9821
GAMES=/media/fat/games/PC9821
IMG=${MISTER_IMG:-}
IMGNAME=${IMG:+$(basename "$IMG")}
IMGNAME=${IMGNAME:-hdd.img}
# The two floppy drives' images, one hps_io slot each. They are OPTIONAL: the OSD's
# S1/S2 entries can mount either drive at any time, and these only list one in the MGL
# so the guest finds it on its first access instead of needing a menu visit.
FDD0=${MISTER_FDD0:-}
FDD1=${MISTER_FDD1:-}

# Authentication: password "1" (the stock MiSTer root password) by default, through sshpass -e (it reads
# SSHPASS from the environment, so the password never appears on a command line).
SSHP=""
MISTER_PASS="${MISTER_PASS-1}"   # the stock MiSTer root password; MISTER_PASS= (empty) uses ssh keys
if [ -n "$MISTER_PASS" ]; then export SSHPASS="$MISTER_PASS"; SSHP="sshpass -e"; fi
SSHO="-o StrictHostKeyChecking=no -o LogLevel=ERROR -o ConnectTimeout=10"

machine=xe10
both=0
copy=1
packs_only=0
mount_image=1
force_pack=0
skip_pack_check=0
allow_stale_pack=0
dumps_base=${PC98_DUMPS:-${BIOS_DIR:-bios}}
for arg in "$@"; do
  case "$arg" in
    --machine)  machine=${2:?--machine needs a name}; shift ;;
    --machine=*) machine=${arg#*=} ;;
    --both)     both=1 ;;
    --packs-only) packs_only=1 ;;
    --no-copy)  copy=0 ;;
    --no-image) mount_image=0 ;;
    --fdd0)     FDD0=${2:?--fdd0 needs a path}; shift ;;
    --fdd0=*)   FDD0=${arg#*=} ;;
    --fdd1)     FDD1=${2:?--fdd1 needs a path}; shift ;;
    --fdd1=*)   FDD1=${arg#*=} ;;
    --pack)     force_pack=1 ;;
    --dumps)    dumps_base=${2:?--dumps needs a directory}; shift ;;
    --dumps=*)  dumps_base=${arg#*=} ;;
    --skip-pack-check)  skip_pack_check=1 ;;
    --allow-stale-pack) allow_stale_pack=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# The dumps for one machine: its own subdirectory of the base if that is how the
# base is laid out (bios/xe10, bios/xe), else the base itself (a flat bios/).
dumps_dir() {
    local m=$1
    if [ -f "$dumps_base/$m/BANK4.BIN" ]; then echo "$dumps_base/$m"
    elif [ -f "$dumps_base/BANK4.BIN" ]; then echo "$dumps_base"
    else echo ""
    fi
}

# Verify the LOCAL pack against the machine's dumps. The transfer check below can
# only prove the card has the local file's bytes; this is the check that proves the
# local file is the firmware the ITF will accept. tools/check_pack.py is run without
# --mem on purpose: the card consumes only the .bin, and there is no mirror beside a
# deployable pack.
verify_pack_against_dumps() {
    local m=$1 pack=$2 dir
    dir=$(dumps_dir "$m")
    if [ -z "$dir" ]; then
        echo "  no dumps for $m under $dumps_base (BANK4.BIN/BIOS.ROM/FONT.ROM/BANK3.BIN/" >&2
        echo "  BANK0..7.BIN): the pack cannot be verified against the dumps" >&2
        echo "  set PC98_DUMPS (or --dumps DIR), or pass --skip-pack-check to bypass" >&2
        return 1
    fi
    echo "  verifying $pack against the $m dumps ($dir)"
    python3 tools/check_pack.py --pack "$pack" \
        --itf "$dir/BANK4.BIN" --bios "$dir/BIOS.ROM" \
        --ide "$dir/BANK3.BIN" --font "$dir/FONT.ROM" --banks "$dir"
}

pack_name() { echo "pc98pack-$1.bin"; }
mgl_for()   { if [ "$1" = "xe10" ]; then echo "/media/fat/$CORE.mgl"; else echo "/media/fat/$CORE-$1.mgl"; fi; }

MACHINES=$machine
[ "$both" = "1" ] && MACHINES="xe10 xe"
[ "$packs_only" = "1" ] && copy=0

if [ "$copy" = "1" ]; then
    [ -f "$RBF" ] || { echo "$RBF not found; run the Quartus build first" >&2; exit 1; }

    # output_files/ IS A COPY DESTINATION, NOT A SOURCE OF TRUTH. A build that ran in a lane
    # leaves its artefact in that lane and never touches this tree's output_files/, so the file
    # here can be arbitrarily old -- it once held a core from before every fix of a session.
    # fit-source.sha256 describes the RTL a fit was built FROM and cannot identify a bitstream,
    # so this reports what is known rather than pretending to verify it.
    echo "RBF to deploy:"
    echo "  $RBF  $(stat -c%s "$RBF") bytes"
    echo "  sha256 $(sha256sum "$RBF" | awk '{print $1}')"
    if [ -f output_files/fit-source.sha256 ]; then
        echo "  built in  $(sed -n 's/^tree: //p' output_files/fit-source.sha256)"
        echo "  rtl-hash  $(sed -n 's/^rtl-hash: //p' output_files/fit-source.sha256)"
        # The clock is not in the RTL hash and never was: a profile switch rewrites both the
        # localparam and the generated PLL. A bitstream that cannot name its clock is one you
        # cannot compare with another.
        echo "  profile   $(sed -n 's/^profile: //p' output_files/fit-source.sha256), clock $(sed -n 's/^clock: //p' output_files/fit-source.sha256) Hz"
        echo "  (that evidence describes the RTL, not this bitstream: if the RBF was copied here"
        echo "   by hand, confirm it came from the tree named above)"
    else
        echo "  no fit-source.sha256 beside it -- this RBF has no recorded provenance"
    fi
    echo "copying RBF -> $DEST"
    $SSHP scp $SSHO "$RBF" $HOST:$DEST
    LOCAL_SUM=$(sha256sum "$RBF" | awk '{print $1}')
    REMOTE_SUM=$($SSHP ssh $SSHO $HOST "sha256sum '$DEST'" | awk '{print $1}')
    [ "$LOCAL_SUM" = "$REMOTE_SUM" ] || { echo "RBF checksum mismatch" >&2; exit 1; }
    echo "  RBF sha256 $LOCAL_SUM verified"
fi

# The packs are runtime inputs holding the user's own dumped firmware. Whatever goes
# on the card is verified against the dumps first, and a card pack that differs from
# the verified local build is a failure rather than a silent keep (see the header).
# WHICH LOCAL PACK, AND WHY THIS ORDER. 'make pack' writes build/pc98pack.bin; the older
# convention was one file per machine, build/pc98pack-<machine>.bin. This looked for ONLY the
# second, so the documented flow - make pack, then deploy - always printed "no local pack for
# xe10" and continued without deploying any firmware, after a 25-minute build. The card keeps a
# per-machine name because one card holds several machines' packs; the LOCAL file need not be
# per-machine, because verify_pack_against_dumps below proves which machine's dumps it is.
# PC98_PACK names a pack explicitly and wins, which is also what tools/run_on_mister.sh uses.
for m in $MACHINES; do
    PACK=$(pack_name "$m")
    LOCAL_PACK=""
    for candidate in "${PC98_PACK:-}" "build/$(pack_name "$m")" build/pc98pack.bin; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then LOCAL_PACK="$candidate"; break; fi
    done
    if [ -z "$LOCAL_PACK" ]; then
        echo "no local pack for $m: looked for \${PC98_PACK:-<unset>}, build/$(pack_name "$m")" >&2
        echo "  and build/pc98pack.bin. Build one from a dump directory with:" >&2
        echo "    make pack PC98_DUMPS=/path/to/your/dumps" >&2
        continue
    fi
    echo "  pack for $m: $LOCAL_PACK"

    if [ "$skip_pack_check" = "1" ]; then
        echo "  WARNING: --skip-pack-check: $LOCAL_PACK is NOT being verified against the dumps" >&2
    elif ! verify_pack_against_dumps "$m" "$LOCAL_PACK"; then
        echo "  ERROR: the local pack for $m is not the dumps; refusing to deploy it." >&2
        echo "         rebuild it (tools/build_pack.py ... --out $LOCAL_PACK), or pass" >&2
        echo "         --skip-pack-check to bypass the check at your own risk." >&2
        exit 1
    fi

    if [ "$force_pack" = "1" ] ||
       ! $SSHP ssh $SSHO $HOST "test -f '$GAMES/$PACK'"; then
        echo "copying pack ($m) -> $GAMES/$PACK"
        $SSHP scp $SSHO "$LOCAL_PACK" $HOST:$GAMES/$PACK
        LOCAL_SUM=$(sha256sum "$LOCAL_PACK" | awk '{print $1}')
        REMOTE_SUM=$($SSHP ssh $SSHO $HOST "sha256sum '$GAMES/$PACK'" | awk '{print $1}')
        # The loader cannot tell a truncated pack from a complete one, so the check
        # that a pack arrived intact has to happen here.
        [ "$LOCAL_SUM" = "$REMOTE_SUM" ] || {
            echo "pack ($m) checksum mismatch on the card" >&2; exit 1; }
        echo "  sha256 $LOCAL_SUM verified"
    else
        LOCAL_SUM=$(sha256sum "$LOCAL_PACK" | awk '{print $1}')
        REMOTE_SUM=$($SSHP ssh $SSHO $HOST "sha256sum '$GAMES/$PACK'" | awk '{print $1}')
        if [ "$LOCAL_SUM" = "$REMOTE_SUM" ]; then
            echo "keeping the pack already on the card -> $GAMES/$PACK"
            echo "  sha256 $REMOTE_SUM matches the local build"
        elif [ "$allow_stale_pack" = "1" ]; then
            echo "keeping the pack already on the card -> $GAMES/$PACK"
            echo "  WARNING: --allow-stale-pack: the card's pack ($REMOTE_SUM) differs from" >&2
            echo "  the verified local build ($LOCAL_SUM); the card runs the former" >&2
        else
            echo "ERROR: the card's pack ($REMOTE_SUM) differs from the verified local build" >&2
            echo "       ($LOCAL_SUM). The card would run firmware that was not the one just" >&2
            echo "       verified against the dumps -- how a stale pack caused the guest's" >&2
            echo "       ROM SUM ERROR. Refusing to continue." >&2
            echo "       Re-run with --pack to replace it, or --allow-stale-pack to accept it." >&2
            exit 1
        fi
    fi
done

if [ -n "$IMG" ] && [ "$copy" = "1" ]; then
    [ -f "$IMG" ] || { echo "image not found: $IMG" >&2; exit 1; }
    echo "copying image -> $GAMES/$IMGNAME"
    $SSHP scp $SSHO "$IMG" $HOST:$GAMES/$IMGNAME
fi

# The floppies go up the same way, into the same games folder, and a missing file is a
# hard failure BEFORE anything is written - exactly as the disk image's is. An MGL
# listing a path the card does not have mounts nothing, and the guest then sees an
# empty drive.
FDDNAME0=""; FDDNAME1=""
for pair in "0:$FDD0" "1:$FDD1"; do
    drv=${pair%%:*}; path=${pair#*:}
    if [ -z "$path" ]; then continue; fi
    [ -f "$path" ] || { echo "floppy image for drive $drv not found: $path" >&2; exit 1; }
    name=$(basename "$path")
    if [ "$copy" = "1" ]; then
        echo "copying FDD$drv image -> $GAMES/$name"
        $SSHP scp $SSHO "$path" $HOST:$GAMES/$name
    fi
    if [ "$drv" = "0" ]; then FDDNAME0=$name; else FDDNAME1=$name; fi
done

# One core on the card, but one MGL per firmware set: that is what makes the menu
# unambiguous. Remove other cores and any MGL this tool does not manage.
echo "removing stale PC9821 cores/MGLs"
$SSHP ssh $SSHO $HOST "
  for f in /media/fat/_Computer/PC9821*.rbf; do
    [ -e \"\$f\" ] || continue
    case \"\$f\" in '$DEST') continue ;; esac
    rm -f \"\$f\" && echo \"  removed \$f\"
  done
  for f in /media/fat/PC9821*.mgl; do
    [ -e \"\$f\" ] || continue
    case \"\$f\" in /media/fat/$CORE.mgl|/media/fat/$CORE-*.mgl) continue ;; esac
    rm -f \"\$f\" && echo \"  removed \$f\"
  done"

# The image entry comes BEFORE the pack entry: MGL file entries are processed in
# order and cpu_run is released by the pack download finishing, so an image listed
# second is mounted after the guest has already probed the drive and latched \"no disk\".
# THE FLOPPY ENTRIES FOLLOW THE SAME RULE, and an S entry's `index` IS the hps_io
# SLOT: 0 is the disk (CONF_STR S0), 1 is FDD0 (S1) and 2 is FDD1 (S2). Main_MiSTer
# passes it straight through to user_io_file_mount (menu.cpp's mount action) and
# hps_io answers with that slot's bit in img_mounted (sys/hps_io.sv:461 (img_mounted  <= io_din[VD:0] ? io_din[VD:0] : 1'b1;)).
if [ "$mount_image" = "1" ]; then
    IMG_LINE="	<file delay=\"1\" type=\"s\" index=\"0\" path=\"$IMGNAME\"/>"
else
    IMG_LINE=""
fi
FDD_LINE0=""
FDD_LINE1=""
if [ -n "$FDDNAME0" ]; then FDD_LINE0="	<file delay=\"1\" type=\"s\" index=\"1\" path=\"$FDDNAME0\"/>"; fi
if [ -n "$FDDNAME1" ]; then FDD_LINE1="	<file delay=\"1\" type=\"s\" index=\"2\" path=\"$FDDNAME1\"/>"; fi

# WHY THERE IS NOTHING TO INSTALL. MiSTer gives a CONF_STR option no default entry
# (MkDocs_MiSTer developer/conf_str.md: the `O` field names a range, a label and the
# choices, nothing else), so a card with no stored selection passes 0 for EVERY field.
# MiSTer loads /media/fat/config/<setname>.CFG at core start for CORE_TYPE_8BIT cores
# (Main_MiSTer user_io.cpp, "try to load config" -- this core's sys/sys_top.v declares
# core_type 'hA4), and the file is the 16-byte status blob. <setname> is the MGL's, so
# the file is PC9821.CFG -- not the RBF's name.
#
# WITH THE ROTATED OSD LISTS, A MISSING FILE IS CORRECT AND THE DEFAULT BLOB IS ALL
# ZEROS. Both fields are list POSITIONS, and the lists were rotated so entry 0 is the
# wanted default: byte 7 bits 5..7 are status[63:61] and entry 0 is 16 MB; byte 0 bit
# 4 is status[4] and entry 0 is the core's native VSync rate. MiSTer uses index 0 for
# every field when no file exists, so a card with no .CFG boots 16 MB at the native
# rate - exactly as a card with a zeroed file does. There is nothing to install.
#
# THAT IS THE POINT OF THE ROTATION. Before it, entry 0 was the ascending list's 1 MB
# and 60 Hz, and a 1 MB guest cannot run the Xe10 BIOS at all: it froze with nothing
# on screen, which looks exactly like a broken core. This script used to install a
# .CFG to cover for that, which only helps when someone remembers - so the trap stayed
# for every card nobody ran this on, which is how it was found.
#
# A .CFG WRITTEN BEFORE THE ROTATION NOW MEANS SOMETHING ELSE, because the value that
# selected 16 MB then selects 1 MB now (entry 4 is where 16 MB moved from). So this
# script does not silently keep one: it prints the file and says what to do.
CFG=/media/fat/config/$SETNAME.CFG
if $SSHP ssh $SSHO $HOST "test -f '$CFG'"; then
    echo "$CFG exists - printing it, because a pre-rotation one is now WRONG:"
    BYTES=$($SSHP ssh $SSHO $HOST "od -An -tx1 '$CFG'")
    echo "$BYTES"
    case "$(echo "$BYTES" | tr -d ' \n')" in
        *[!0]*) echo
            echo "  ^ THIS FILE IS NOT ZERO, so it was written for the PRE-ROTATION lists"
            echo "    and selects a different size than it did. The RAM field is byte 7 bits"
            echo "    5..7: the old 16 MB value 0x80 is now entry 4, which is 1 MB."
            echo "    Fix it on the card - either is enough, they are equivalent:"
            echo "      ssh root@<mister> 'rm /media/fat/config/$SETNAME.CFG'"
            echo "      ssh root@<mister> 'dd if=/dev/zero of=/media/fat/config/$SETNAME.CFG bs=16 count=1'"
            echo "    or re-select the size in the OSD, which rewrites the file." ;;
        *)  echo "  all zero: that IS the default now (16 MB, native VSync). Nothing to do."
            echo "    One thing to know: before the rotation an all-zero file selected 1 MB, so"
            echo "    if this card was deliberately set to 1 MB it is now 16 MB. Re-select it in"
            echo "    the OSD if that was not what you wanted." ;;
    esac
else
    echo "no $CFG, and none needed: with the rotated OSD lists a missing file IS the"
    echo "  default - entry 0 is 16 MB of RAM and the core's native VSync rate."
fi

# The pack is listed last: the core holds the CPU in reset until it has downloaded, so the disks
# must already be mounted when the BIOS starts. delay="1" for the pack (was 4) boots fine on the
# MiSTer (2026-10-09) and reaches the BIOS ~3 s sooner.
for m in $MACHINES; do
    MGL=$(mgl_for "$m")
    PACK=$(pack_name "$m")
    echo "writing MGL ($m) -> $MGL"
    $SSHP ssh $SSHO $HOST "cat > $MGL <<'XML'
<mistergamedescription>
	<rbf>_Computer/$CORE</rbf>
	<setname>$SETNAME</setname>
$IMG_LINE
$FDD_LINE0
$FDD_LINE1
	<file delay=\"1\" type=\"f\" index=\"0\" path=\"$PACK\"/>
</mistergamedescription>
XML
cat $MGL"
done

LOAD_MGL=$(mgl_for "$machine")
echo "load_core via /dev/MiSTer_cmd ($LOAD_MGL)"
$SSHP ssh $SSHO $HOST "echo 'load_core $LOAD_MGL' > /dev/MiSTer_cmd && echo command_sent"