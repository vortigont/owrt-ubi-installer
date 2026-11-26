#!/bin/sh
# BREST is a 'BackupRESTore' script for OpenWrt routers than can do raw nand and UBI image backup / restore
#
# Usage:
#   ubi-backup.sh create /dev/mtdX
#   ubi-backup.sh restore /tmp/NAME.ubi.img /tmp/NAME.ubi.ini /dev/mtdX
#
# Output (create):
#   /tmp/NAME.ubi.ini
#   /tmp/NAME.ubi.img
#   /tmp/NAME-vol-ID.bin
#
# WARNING:
#   Restore erases and reformats the specified MTD partition.
#   Never restore a UBI partition currently used by the running rootfs.

set -u

# default back-up location dir
DEST="/tmp"
ACTION=""
BOARD_NAME=""

## global vars - assigned at run-time
# unverified --mtd cmd arg
MTD_DEV=
# verified mtd device path, i.e. '/dev/mtd5'
MTD_PATH=
# mtd base name, i.e. 'mtd5'
MTD_BASE=
# mtd num, i.e. '5'
MTD_NUM=
# mtd part size via sysfs
MTD_SIZE=

# ubi device path, i.e. /dev/ubi0
UBI_DEV=
# ubi dev num, i.e. '0'
UBI_NUM=
# ubi sysfs path, i.e. '/sys/class/ubi/ubi0'
UBI_SYS=

# if ubi dev was not already attached before running this script,
# it attach it for the duration of operation then mark it to detach on exit
UBI_DETACH=0


die() {
	echo "ERROR: $*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 ||
		die "Required command not found: $1"
}

# checks for simple substring metch
# args:
# $1 - checked string
# $2 - substring to metch
contains() {
    case "$1" in
        *"$2"*) return 0 ;;
        *)      return 1 ;;
    esac
}

# checks if mtd dev is writable, arg - mtd dev, e.g, "mtd0"
mtd_is_writable() {
    local mtd="$1"

    [ -n "$mtd" ] || return 2
    [ -r "/sys/class/mtd/$mtd/flags" ] || return 2

    local flags=$(cat "/sys/class/mtd/$mtd/flags") || return 2

    # MTD_WRITEABLE = 0x400
    [ $((flags & 0x400)) -ne 0 ] && return 0

    return 1
}

# check supplied arg is a real mtd part
# Accept only /dev/mtdN character devices
check_mtd() {
    local dev=$1
	case "$dev" in
		/dev/mtd[0-9]*) ;;
		mtd[0-9]*)      dev="/dev/$dev" ;;
		[0-9]*)         dev="/dev/mtd$dev" ;;
		*)
			echo "$1 is wrong, expected MTD device path, e.g., '/dev/mtd5' or 'mtd5' or '5'"
			return 1
			;;
	esac

	MTD_PATH="$dev"
	MTD_BASE="${MTD_PATH##*/}"
	MTD_NUM="${MTD_BASE#mtd}"

    if [ ! -c "$MTD_PATH" ]; then
        echo "not a char MTD device: $MTD_PATH" >&2
		return 1
    fi

	MTD_SYS="/sys/class/mtd/$MTD_BASE"
	[ -d "$MTD_SYS" ] || { echo "No sysfs entry for $MTD_PATH"; return 1; }
	[ -r "$MTD_SYS/size" ] || { echo "Cannot read MTD information"; return 1; }
    MTD_SIZE=$(cat "$MTD_SYS/size")
	return 0
}

# Find the attached UBI device backed by this MTD.
# arg - mtd part num
find_ubi() {
	local mtd_devnum=$1
	for d in /sys/class/ubi/ubi[0-9]*; do
		[ -r "$d/mtd_num" ] || continue

		local n="$(cat "$d/mtd_num" 2>/dev/null)" || continue

		if [ "$n" = "$mtd_devnum" ]; then
			UBI_NUM="${d##*/}"
			UBI_DEV="/dev/${d##*/}"
			UBI_SYS="$d"
			return 0
		fi
	done
	return 1
}

# attaches UBI mtd dev 
attach_ubi() {
	local mtd_devnum=$1
	if ! find_ubi $mtd_devnum; then
		# target ubi was not found, try to attach
		echo "trying to attach UBI: $1"
		UBI_DETACH=1
		# attempt to attach UBI and call find_ubi to assign vars
		ubiattach -p "/dev/mtd$mtd_devnum" && find_ubi $mtd_devnum
	fi
	return 0
}


# tries to make a thin ubifs volume with tar'ed content
# args:
# $1 - ubi vol device as '/dev/ubi0_1'
# $2 - tar file to dump vol's content to
tardump_ubifs_vol() {
	local VOL_DEV=$1
	local VOL_BASE="${VOL_DEV##*/}"
	local VOL_MNT

	# check if volume is already mounted?
	if cat /proc/mounts | grep -q $VOL_DEV; then
		VOL_MNT=$(cat /proc/mounts | grep $VOL_DEV | awk '{print $2}')
		# tar vol's content
		tar -C $VOL_MNT -czf $2 . && return 0
		return 1
	fi

	# mount vol temporary and dump the files
	VOL_MNT="${DEST}/ro_${VOL_BASE}"
	mkdir -p $VOL_MNT

	# try to mount ubifs
	mount -t ubifs -o ro $VOL_DEV $VOL_MNT || {
		# failed to mount
		echo "warn: vol $VOL_DEV is not an UBIFS"
		return 1
	}

	# tar vol's content
	tar -C $VOL_MNT -czf $2 . && { umount $VOL_MNT && rm -rf $VOL_MNT; return 0; }
	# some err
	umount $VOL_MNT && rm -rf $VOL_MNT
	echo "unable to tar vol's content at $VOL_MNT"
	return 1
}


# unpacks tar'ed files to a ubi vol
# args:
# $1 - path to tar file with templated name, i.e. 'mtd10-vol-2.tgz'
# $2 - UBI device to operate on, i.e. '/dev/ubi0'
# function will derive target vol from an archive name
untar_to_ubifs_vol(){
    local infile="$1"
	local ubi_device="$2"
	[ -r "$infile" ] || { echo "vol archive is not readable: $infile"; return 1; }
    local filename="${infile##*/}"
    local volume="${filename%-ubifs.tgz}"
    volume="${volume##*-}"

	local VOL_DEV="${ubi_device}_$volume"
	local VOL_BASE="${VOL_DEV##*/}"
	local VOL_MNT

	echo
	echo "Unpacking tar to ubifs vol"
	echo "Tar: 				$infile"
	echo "target vol: 		$volume"
	echo "UBI vol device: 	$VOL_DEV"
	echo

	# check if volume is already mounted?
	if cat /proc/mounts | grep -q $VOL_DEV; then
		VOL_MNT=$(cat /proc/mounts | grep $VOL_DEV | awk '{print $2}')
		# untar archive's content
		echo "Unpacking $filename to ${VOL_MNT} for UBI:${VOL_DEV}..."
		tar -C $VOL_MNT -xzf $infile && return 0
		return 1
	fi

	# mount vol temporary and dump the files
	VOL_MNT="${DEST}/rw_${VOL_BASE}"
	mkdir -p $VOL_MNT

	# try to mount ubifs
	mount -t ubifs $VOL_DEV $VOL_MNT || {
		# failed to mount
		echo "warn: vol $VOL_DEV is not an UBIFS, won't restore $filename to it"
		return 1
	}

	# untar archive's content
	echo "Unpacking $filename to ${VOL_MNT} for UBI:${VOL_DEV}..."
	tar -C $VOL_MNT -xzf $infile && { sync ; sleep 1 ; umount $VOL_MNT ; rm -rf $VOL_MNT; return 0; }

	# some err unpacking
	umount $VOL_MNT && rm -rf $VOL_MNT
	echo "unable to untar to vol:$VOL_DEV at $VOL_MNT"
	return 1
}


# dd's raw data to a destination file
# if destination ends up with '.gz' output will be gzipped
# args:
# 1 - dd's if input
# 2 - destination file to write image to
# 3 - read block size, if ommited then 128k is used
# 4 - num of blocks to read, if '0' or ommited then read till end of dev
# 5 - num of blocks to skip from partition start, default is '0'
dd_dump() {
    local in="$1"
    local dest="$2"
    local blksize="${3:-131072}"
    local count="${4:+count=$4}"
    local skip="${5:+skip=$5}"

    if [ ! -r "$in" ]; then
        die "$in is not readable" >&2
    fi

    echo "Dumping $in: block_size=$blksize $count $skip -> $dest"

	# Dump, optionally compress
    case "$dest" in
        *.gz)
            dd if="$if" bs="$blksize" $skip $count |
                gzip -9c > "$dest"
            ;;
        *)
            dd if="$in" bs="$blksize" $skip $count > "$dest"
            ;;
    esac

    local rc=$?

    if [ "$rc" -ne 0 ]; then
        rm -f "$dest"
        echo "dd failed" >&2
        return 1
    fi
	
    return 0
}


# dd's raw blocks from mtd part to a destination file
# if destination ends up with '.gz' output will be gzipped
# args:
# 1 - mtd device '/dev/mtdX'
# 2 - destination file to write image to
# 3 - read count size (in blocks), if 0 then use mtd 'erasesize'
# 4 - num of blocks to read, if '0' or ommited then read till end of dev
# 5 - num of blocks to skip from partition start, default is '0'
mtd_ddump() {
    local dest="${2:-}"
    local blksize="${3:-0}"
    local count="${4:-0}"
    local skip="${5:-0}"

	check_mtd $1 || return 1

    # Validate numeric arguments
    case "$blksize:$count:$skip" in
        *[!0-9:]*)
            echo "Invalid numeric argument for mtd_ddump()" >&2
            return 1
            ;;
    esac

	[ -n "$dest" ] || {
		# Derive output name from the MTD partition label
		local LABEL="$(awk -F '[" :]' -v base="$MTD_BASE" '$1 == base {print $6}' /proc/mtd)"
		# if no label found use 'raw' as label
		[ -n "$LABEL" ] || LABEL="raw"
		LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9_.-' '_')"
		dest="${DEST}/${MTD_BASE}_${LABEL}.bin"
	}

    # Read MTD geometry (sysfs values are in bytes)
    local erasesize=$(cat "/sys/class/mtd/${MTD_BASE}/erasesize") || return 1
    local mtd_size=$(cat "/sys/class/mtd/${MTD_BASE}/size") || return 1

    # Default read block size = erase block size
    [ "$blksize" -eq 0 ] 2>/dev/null && blksize="$erasesize"

    # Calculate byte offset and length
    local offset=$((skip * blksize))
    local remaining=$((mtd_size - offset))

    [ "$remaining" -gt 0 ] || {
        echo "Skip offset exceeds MTD size"
        return 1
    }

    if [ "$count" -gt 0 ]; then
        local length=$((count * blksize))

        [ "$length" -le "$remaining" ] || {
            echo "Requested dump exceeds MTD size"
            return 1
        }
    else
        count=$(((remaining + blksize - 1) / blksize))
    fi
	dd_dump $MTD_PATH $dest $blksize $count $skip
}


# parses a list of mtd devs list from a cvs arg and runs  mtd_ddump()
mtd_dump_parse(){
    local csv="$1"
    local dev

    [ -n "$csv" ] || {
        echo "missing mtd dev list, like '/dev/mtd0,mtd1,2'" >&2
        return 1
    }

    while [ -n "$csv" ]; do
        # Extract next CSV value
        dev="${csv%%,*}"

        # Remove processed value
        if [ "$csv" = "$dev" ]; then
            csv=""
        else
            csv="${csv#*,}"
        fi

		#Check and process with dump
		mtd_ddump "$dev" || echo "was unable to dump $dev"
    done
}

# returns size of a ubi vol obtained via ubinfo
# args:
# $1 - ubi device path /dev/ubiX_Y
get_ubi_volsize() {
	local ubi_dev=$1
	[ -e $ubi_dev ] || return 0
	local SIZE=$(ubinfo $ubi_dev 2>/dev/null | awk '/^Size:/ {print $4}')
	SIZE="${SIZE##*(}"
	echo "$SIZE"
}

# creates a ubinize image and cfg file for defined partition
# args:
# $1 - mtd device to dump
create_ubinize_image() {
	need_cmd ubinfo
	need_cmd dd
	need_cmd ubinize
	need_cmd awk
	need_cmd tr
	need_cmd wc

	check_mtd $1 || die "Unable to ubinize $1"

	attach_ubi $MTD_NUM || die "can't attach $MTD_PATH to UBI"

	local LABEL="$MTD_BASE"

	local OUT_INI="${DEST}/$LABEL.ubi.ini"
	local OUT_IMG="${DEST}/$LABEL.ubi.img"

	echo "MTD:     $MTD_PATH"
	echo "UBI:     $UBI_DEV"
	echo "INI:     $OUT_INI"
	echo "Image:   $OUT_IMG"
	echo

	# Read the underlying NAND geometry.
	local MIN_IO="$(cat "$MTD_SYS/writesize")"
	local PEB_SIZE="$(cat "$MTD_SYS/erasesize")"
	local SUBPAGE_SIZE="$(cat "$MTD_SYS/subpagesize" 2>/dev/null)"

	[ -n "$MIN_IO" ] || die "Cannot determine NAND page size"
	[ -n "$PEB_SIZE" ] || die "Cannot determine NAND eraseblock size"

	[ -n "$SUBPAGE_SIZE" ] || SUBPAGE_SIZE="$MIN_IO"

	# Read the VID header offset from the attached UBI device.
	local ubi_dev_base="$(basename $UBI_DEV)"
	local VID_OFFSET="$(dmesg | grep $ubi_dev_base | sed -n 's/.*VID header offset: \([0-9][0-9]*\).*/\1/p' | tail -n 1)"

	[ -n "$VID_OFFSET" ] || die "Cannot determine UBI VID header offset"

	# Keep the full ubinfo report as a backup of volume metadata.
	ubinfo $UBI_DEV -a > "${DEST}/$LABEL.ubinfo.txt" || die "Cannot save UBI metadata"

	: > "$OUT_INI" || die "Cannot create $OUT_INI"

	# Enumerate volumes by their sysfs names.
	local FOUND=0
	# we acn have ONE autoresize vol within our UBI img, usually it is 'root_data' vol
	local AUTORESIZE_VOL=0

	for v in /sys/class/ubi/"${UBI_DEV##*/}"_[0-9]*; do
		[ -r "$v/name" ] || continue

		local VBASE="${v##*/}"
		local VID="${VBASE##*_}"
		local VOL_DEV="/dev/$VBASE"

		local VOL_NAME="$(cat "$v/name")"
		local VOL_TYPE="$(cat "$v/type")"
		local VOL_ALIGN="$(cat "$v/alignment")"
		local RESERVED_EBS="$(cat "$v/reserved_ebs")"
		local LEB_SIZE="$(cat "$v/usable_eb_size")"

		case "$VID:$VOL_ALIGN:$RESERVED_EBS:$LEB_SIZE" in
			*[!0-9:]*)
				die "Invalid metadata for $VBASE"
				;;
		esac

		[ -c "$VOL_DEV" ] || die "Volume device missing: $VOL_DEV"

		local VOL_FILE="${DEST}/$LABEL-vol-$VID.bin"
		local TAR_FILE="${DEST}/$LABEL-vol-$VID-ubifs.tgz"
		local FILE_SIZE=
		# file with vol image (empty in case of tar for ubifs)
		local FILE_IMG=""
		local VOL_SIZE=0
		local VOL_FLAGS=""

		case "$VOL_NAME" in
		kernel|rootfs)
			# these vols are known to be binary, dump it as raw img
			dd_dump $VOL_DEV $VOL_FILE || continue
			FILE_SIZE="$(du -b "$VOL_FILE" | awk '{print $1}')"
			FILE_IMG=$VOL_FILE
			VOL_SIZE=$FILE_SIZE
			;;
		*)
			# other vols we can try to do thin file archive dump and fallback to binary instead
			if tardump_ubifs_vol "$VOL_DEV" "$TAR_FILE"; then
				FILE_SIZE="$(du -b "$TAR_FILE" | awk '{print $1}')"
				FILE_IMG=""
				# for tar backups we write vol size from UBI vol property
				VOL_SIZE=$(get_ubi_volsize $VOL_DEV)
			else
				dd_dump $VOL_DEV $VOL_FILE || continue
				FILE_SIZE="$(du -b "$VOL_FILE" | awk '{print $1}')"
				FILE_IMG=$VOL_FILE
				VOL_SIZE=$FILE_SIZE
			fi

			# check if it's a 'root_data' vol, for this we'd use 'autoresize' flag and smaller initial size
			if [ "$VOL_NAME" = "rootfs_data" ]; then
				AUTORESIZE_VOL=1
				VOL_FLAGS="autoresize"
				VOL_SIZE=$FILE_SIZE
			fi

			;;
		esac

		# skip writing section to cfg file if nothing was dumped - not sure if it's OK, vol might be empty FS
		#[ "$FILE_SIZE" -gt 0 ] || continue

		# Preserve autoresize if the kernel reports it.
		if ! contains "$VOL_FLAGS" "autoresize"; then
			VOL_FLAGS="$(
				ubinfo -d $UBI_NUM -a 2>/dev/null |
				awk -v id="$VID" '
					/Volume ID:/ {
						cur = $3
						sub(/\(.*/, "", cur)
					}
					cur == id && /Flags:/ && /autoresize/ {
						found = 1
					}
					END {
						if (found) print "autoresize"
					}
				'
			)"
		fi


		{
			echo "[volume-$VID]"
			echo "mode=ubi"
			if [ -n "$FILE_IMG" ]; then
				# write image file source only for bin images, for tar we skip
				echo "image=$(basename $FILE_IMG)"
			fi
			echo "vol_id=$VID"
			echo "vol_type=$VOL_TYPE"
			echo "vol_name=$VOL_NAME"
			echo "vol_alignment=$VOL_ALIGN"
			if [ -n "$VOL_SIZE" ] && [ "$VOL_SIZE" -gt 0 ] ; then
				echo "vol_size=$VOL_SIZE"
			fi
			if [ -n "$VOL_FLAGS" ]; then
				echo "vol_flags=$VOL_FLAGS"
			fi

			echo
		} >> "$OUT_INI" || die "Failed writing INI"

		FOUND=$((FOUND + 1))
	done

	[ "$FOUND" -gt 0 ] || die "No volumes found"

	echo
	echo "Creating portable UBI image ..."
	ubinize \
		-o "$OUT_IMG" \
		-m "$MIN_IO" \
		-p "$PEB_SIZE" \
		-s "$SUBPAGE_SIZE" \
		-O "$VID_OFFSET" \
		"$OUT_INI" ||
		die "ubinize failed"

	echo
	echo "Image created: $OUT_IMG"
	echo "Configuration: $OUT_INI"
	echo "Metadata:      ${DEST}/$LABEL.ubinfo.txt"
	echo "Volumes:       $FOUND"
	echo "Image size:    $(du -b $OUT_IMG | awk '{print $1}') bytes"

	if [ "$UBI_DETACH" = "1" ]; then
		ubidetach -p $MTD_PATH
	fi


	# clean up temp vol images, we need only ubi img and tars
	rm -f ${DEST}/${MTD_BASE}-vol*.bin

	return 0
}

# reformats $MTD_ device and writes it's content from a ubinize image files created by `create_ubinize_image` function
# args:
# $1 - mtd device, any of '/dev/mtdX', 'mtdX', 'X'
# $2 - dir to pick image files from
restore_ubinize_image() {
	need_cmd ubiformat
	need_cmd ubidetach

	local m="${1:-$MTD_DEV}"
	local SRC_DIR="${2:-$DEST}"
	local IMAGE="${SRC_DIR}/${1:-$MTD_BASE}.ubi.img"

	# check and normalize mtd device name
	check_mtd ${m} || return 1

	mtd_is_writable $MTD_BASE || { echo "$MTD_BASE dev is read-only"; return 1; }

	[ -r "$IMAGE" ] || { echo "image file $IMAGE is not readable"; return 1; }


	echo
	echo "Image:      $IMAGE"
	echo "Target MTD: $MTD_PATH"
	echo

	if find_ubi $MTD_NUM; then
		echo "Detaching $UBI_DEV ..."
		ubidetach -p "$MTD_PATH" || { echo "Cannot detach UBI from $MTD_PATH"; return 1; }
	fi

	echo "Restoring UBI image ..."

	ubiformat "$MTD_PATH" -y -f "$IMAGE" || { echo "ubiformat failed"; return 1; }

	# check if there are tar archives present to unpack to newly created FS
	if [ $(find ${SRC_DIR}/${MTD_BASE}-vol-*-ubifs.tgz 2>/dev/null | wc -l) -gt 0 ]; then
		echo
		echo "Prepare to restore tar archives for UBI at $MTD_PATH"
		ubiattach -p "$MTD_PATH" ||  { echo "Unable to attach newly formatted UBI at:$MTD_PATH"; return 1; }
		sleep 1
		find_ubi $MTD_NUM || { echo "Can't find UBI node for $MTD_PATH"; return 1; }

		# restore archived files
		for file in "${SRC_DIR}/${MTD_BASE}-vol-*-ubifs.tgz"; do
			untar_to_ubifs_vol $file $UBI_DEV
		done
		ubidetach -p "$MTD_PATH"
		sleep 1
	fi

	echo "Restore completed."
	echo "Reboot or attach $MTD_PATH UBI partition when appropriate."
}

# write raw mtd image to device
# args:
# 1 - mtd partition name to write to
# 2 - full path to image file
mtd_write_img() {
	local part=$1
	local file=$2
	local mtd_dev=$(grep $part /proc/mtd | awk -F ':' '{print $1}')

    [ -n "$mtd_dev" ] || { echo "can't find mtd dev with part name $part"; return 2; }

	check_mtd $mtd_dev || { echo "can't write to mtd dev: $1"; return 1; }
	mtd_is_writable $MTD_BASE || { echo "$MTD_BASE dev is read-only"; return 1; }

	local FILE_SIZE="$(du -b "$file" | awk '{print $1}')"

    [ "$FILE_SIZE" -gt $MTD_SIZE ] && {
        echo "image size:${FILE_SIZE} is larger then mtd dev size:${MTD_SIZE}"
        return 1
    }
	echo "writing mtd image $file to $part"
	mtd -q -e $part write $file $part
}

# scans $DEST for an 'mtdXX_*.bin' files and attempts to restore it to respective mtd parts
mtd_restore_all() {
	echo "Restoring mtd images from $DEST"
	for file in ${DEST}/mtd*_*.bin; do
		[ -f "$file" ] || continue
		#local mtd_dev=$( basename $file | awk -F '_' '{ print $1 }' )
		local filename=$(basename $file)
		local part="${filename#mtd[0-9]*_}"
		part="${part%.bin}"
		mtd_write_img $part $file
	done
}

# scans $DEST for an 'mtd*.ubi.img' ubinize files and attempts to restore it to respective mtd parts
ubinize_restore_all() {
	echo "Restoring UBI images from $DEST"
	#local bkp_dir="${1:-$DEST}"
	#[ -d "$bkp_dir" ] || die "$bkp_dir is not a dir"

	for file in ${DEST}/mtd*.ubi.img; do
		[ -f "$file" ] || continue
		local mtd_dev=$( basename $file | awk -F '.' '{ print $1 }' )
		# use defaults, pick image files from $DEST dir
		echo "restore_ubinize_image $mtd_dev"
		restore_ubinize_image $mtd_dev
	done
}


# ---------------------------------------------------------------------------
# router templates
backup_elecom_wrc-x6000qs() {
	# backup raw mtd's
	mtd_dump_parse "mtd0"					# BL2
	mtd_ddump "/dev/mtd1" "" 131072 1		# U-Boot env, first 128k
	mtd_ddump "/dev/mtd2" "" 131072 4		# Factory, 	first 512k
	mtd_ddump "/dev/mtd3" "" 131072 8		# FIP (BL31 + U-Boot), in fact only 1024k of real data there
	mtd_ddump "/dev/mtd4" "" 131072 1		# OEM firmware header 1, less then 1k of real data there
	mtd_ddump "/dev/mtd8" "" 131072 1		# OEM firmware header 2, less then 1k of real data there
	mtd_ddump "/dev/mtd12" "" 131072 1		# "persist" firmware image selector data
	# mtd13 Mrd is empty
	# mtd14 Backup is empty

	create_ubinize_image "mtd6"				# Firmware1 UBI
	create_ubinize_image "mtd7"				# Config1 UBI
	create_ubinize_image "mtd10"			# Firmware2 UBI
	create_ubinize_image "mtd11"			# Config_2 UBI

	echo
	echo "backup complete, copy all ${DEST}/mtd* files to safe place" 
}

restore_elecom_wrc-x6000qs() {
	#mtd_restore_all
	ubinize_restore_all
}

backup_router() {
    case "$BOARD_NAME" in
	elecom_wrc-x6000qs)
		backup_elecom_wrc-x6000qs
        ;;
    "")
		BOARD_NAME=$(cat /proc/device-tree/compatible | tr '\0' '\n' | head -1 | tr ',' '_')
        echo "No router profile set, autodetect: $BOARD_NAME"
		backup_router $BOARD_NAME
		exit 0
        ;;
    *)
        echo "Unsupported router"
		show_help
		exit 1
        ;;
    esac
}

restore_router() {
    case "$BOARD_NAME" in
	elecom_wrc-x6000qs)
		restore_elecom_wrc-x6000qs
        ;;
    "")
		BOARD_NAME=$(cat /proc/device-tree/compatible | tr '\0' '\n' | head -1 | tr ',' '_')
        echo "No router profile set, autodetect: $BOARD_NAME"
		restore_router $BOARD_NAME
		exit 0
        ;;
    *)
        echo "Unsupported router"
		show_help
		exit 1
        ;;
    esac
}


# ---------------------------------------------------------------------------
#	
# display help message for the script
#
show_help () {
	echo "Usage: $0 -r|--router <router_profile> [options]"
	echo
	echo "Options:"
	echo "  -r|--router <router_profile>   router profile to build for"
	echo "                              Supported router profiles:"
	echo "                              - creatlentem_clt-r30b1"
	echo "                              - elecom_wrc-x6000qs"
	echo
	echo
	echo "  --img-url <download_url>    Specify URL where to download ImageBuilder and sysupgrade images from"
	echo "                              this will override offical OpenWrt downloads so you can use a local mirror or"
	echo "                              a custom build that is not yet released"
	echo "                              You may use local 'file://' URLs to point to a local directory containing the OpenWrt"
	echo "                              artifacts, e.g. 'file:///home/user/openwrt/builds/mt7981/filogic'"
	echo "                              WARNING: GPG verification would fail if the URL is not an official OpenWrt release,"
	echo "                              be sure you trust the source of the files you are downloading"
	echo
	echo "  --pkg-url <download_url>    Specify URL for the system/app packages repository"
	echo "                              this will override offical OpenWrt downloads so you can use a local mirror or"
	echo "                              a custom build that is not yet released"
	echo "                              WARNING: GPG verification would fail if the URL is not an official OpenWrt release,"
	echo "                              be sure you trust the source of the files you are downloading"
	echo "  --no-backup                 generates image with disabled backup of original mtd partitions,"
	echo "								saves space on flash if you already have a backup of the original partitions"
	echo
	echo "  -h, --help                  Show this help message"
}


# parse command line args

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--backup-dir)
			[ -d "$2" ] || die "$2 is not a dir"
			DEST="$2"
			# add trailing slash to dir if missing
			#[ "${DEST%/}" = "DEST" ] && DEST="$DEST/"
			# removes all trailing slashes
			DEST="${DEST%/}"
            shift 2
            ;;
		-a|--action)
			ACTION="$2"
            shift 2
            ;;
        -r|--router)
			BOARD_NAME="$2"
            shift 2
            ;;
        -m|--mtd)
			MTD_DEV="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            # Positional argument
            break
            ;;
    esac
done


# run requested actions
case "$ACTION" in
	ubinize-dump)
		create_ubinize_image $MTD_DEV
		;;
	ubinize-restore)
		if [ -n "$MTD_DEV" ]; then
			restore_ubinize_image $MTD_DEV
		else
			# if no mtd specified, try to restore all that could be found in backup dir
			ubinize_restore_all
		fi

		;;
	mtddump)
		mtd_dump_parse $MTD_DEV
		;;
	backup)
		backup_router $BOARD_NAME
		;;
	restore)
		restore_router $BOARD_NAME
		;;
	*)
		show_help
		;;
esac

