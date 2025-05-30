RAM_ROOT=/tmp/root

export BACKUP_FILE=sysupgrade.tgz	# file extracted by preinit

[ -x /usr/bin/ldd ] || ldd() { LD_TRACE_LOADED_OBJECTS=1 $*; }
libs() { ldd $* 2>/dev/null | sed -E 's/(.* => )?(.*) .*/\2/'; }

install_file() { # <file> [ <file> ... ]
	local target dest dir
	for file in "$@"; do
		if [ -L "$file" ]; then
			target="$(readlink -f "$file")"
			dest="$RAM_ROOT/$file"
			[ ! -f "$dest" ] && {
				dir="$(dirname "$dest")"
				mkdir -p "$dir"
				ln -s "$target" "$dest"
			}
			file="$target"
		fi
		dest="$RAM_ROOT/$file"
		[ -f "$file" -a ! -f "$dest" ] && {
			dir="$(dirname "$dest")"
			mkdir -p "$dir"
			cp "$file" "$dest"
		}
	done
}

install_bin() {
	local src files
	src=$1
	files=$1
	[ -x "$src" ] && files="$src $(libs $src)"
	install_file $files
}

run_hooks() {
	local arg="$1"; shift
	for func in "$@"; do
		eval "$func $arg"
	done
}

ask_bool() {
	local default="$1"; shift;
	local answer="$default"

	[ "$INTERACTIVE" -eq 1 ] && {
		case "$default" in
			0) echo -n "$* (y/N): ";;
			*) echo -n "$* (Y/n): ";;
		esac
		read answer
		case "$answer" in
			y*) answer=1;;
			n*) answer=0;;
			*) answer="$default";;
		esac
	}
	[ "$answer" -gt 0 ]
}

_v() {
	[ -n "$VERBOSE" ] && [ "$VERBOSE" -ge 1 ] && echo "$*" >&2
}

v() {
	_v "$(date) upgrade: $@"
	logger -p info -t upgrade "$@"
}

json_string() {
	local v="$1"
	v="${v//\\/\\\\}"
	v="${v//\"/\\\"}"
	echo "\"$v\""
}

rootfs_type() {
	/bin/mount | awk '($3 ~ /^\/$/) && ($5 !~ /rootfs/) { print $5 }'
}

get_image() { # <source> [ <command> ]
	local from="$1"
	local cmd="$2"

	if [ -z "$cmd" ]; then
		local magic="$(dd if="$from" bs=2 count=1 2>/dev/null | hexdump -n 2 -e '1/1 "%02x"')"
		case "$magic" in
			1f8b) cmd="busybox zcat";;
			*) cmd="cat";;
		esac
	fi

	$cmd <"$from"
}

get_image_dd() {
	local from="$1"; shift

	(
		exec 3>&2
		( exec 3>&2; get_image "$from" 2>&1 1>&3 | grep -v -F ' Broken pipe'     ) 2>&1 1>&3 \
			| ( exec 3>&2; dd "$@" 2>&1 1>&3 | grep -v -E ' records (in|out)') 2>&1 1>&3
		exec 3>&-
	)
}

get_magic_word() {
	(get_image "$@" | dd bs=2 count=1 | hexdump -v -n 2 -e '1/1 "%02x"') 2>/dev/null
}

get_magic_long() {
	(get_image "$@" | dd bs=4 count=1 | hexdump -v -n 4 -e '1/1 "%02x"') 2>/dev/null
}

get_magic_gpt() {
	(get_image "$@" | dd bs=8 count=1 skip=64) 2>/dev/null
}

get_magic_vfat() {
	(get_image "$@" | dd bs=3 count=1 skip=18) 2>/dev/null
}

get_magic_fat32() {
	(get_image "$@" | dd bs=1 count=5 skip=82) 2>/dev/null
}

identify_magic_long() {
	local magic=$1
	case "$magic" in
		"55424923")
			echo "ubi"
			;;
		"31181006")
			echo "ubifs"
			;;
		"68737173")
			echo "squashfs"
			;;
		"d00dfeed")
			echo "fit"
			;;
		"4349"*)
			echo "combined"
			;;
		"1f8b"*)
			echo "gzip"
			;;
		*)
			echo "unknown $magic"
			;;
	esac
}

part_magic_efi() {
	local magic=$(get_magic_gpt "$@")
	[ "$magic" = "EFI PART" ]
}

part_magic_fat() {
	local magic=$(get_magic_vfat "$@")
	local magic_fat32=$(get_magic_fat32 "$@")
	[ "$magic" = "FAT" ] || [ "$magic_fat32" = "FAT32" ]
}

export_bootdevice() {
	local cmdline uuid blockdev line class
	local DEVNAME PARTN

	local uevent="/sys/dev/block/$(grep -F -m 1 -e ' / /rom ' -e ' / / ' /proc/1/mountinfo | awk '{print $3}')/uevent"

	if [ -r "$uevent" ]; then
		export -n $(grep -e 'DEVNAME=' -e 'PARTN=' "$uevent")
		# remove partition number, but leave trailing p on mmcblk0p1
		export "BOOTDEV=${DEVNAME%$PARTN}"
		# save to /tmp for later calls without /dev/root mounted
		echo "$BOOTDEV" > /tmp/bootdev
		return 0
	elif [ -r "/tmp/bootdev" ]; then
		export "BOOTDEV=$(cat /tmp/bootdev)"
		return 0
	fi

	return 1
}

export_partdevice() {
	local var="$1" offset="$2" devname="$BOOTDEV"

	# remove trailing p from mmcblk0p, but not from sdp
	if [ "$offset" -eq 0 ] && [ -z "${devname##*[0-9]p}" ]; then
		devname="${devname%p}"
	elif [ "$offset" -gt 0 ]; then
		devname="$devname$offset"
	fi

	v "with offset=$offset devname=$devname"

	if [ -b "/dev/$devname" ]; then
		export "$var=$devname"
		return 0
	fi

	return 1
}

hex_le32_to_cpu() {
	[ "$(echo 01 | hexdump -v -n 2 -e '/2 "%x"')" = "3031" ] && {
		echo "${1:0:2}${1:8:2}${1:6:2}${1:4:2}${1:2:2}"
		return
	}
	echo "$@"
}

get_partitions() { # <device> <filename>
	local disk="$1"
	local filename="$2"

	if [ -b "$disk" -o -f "$disk" ]; then
		v "Reading partition table from $filename..."

		local magic=$(dd if="$disk" bs=2 count=1 skip=255 2>/dev/null)
		if [ "$magic" != $'\x55\xAA' ]; then
			v "Invalid partition table on $disk"
			exit
		fi

		rm -f "/tmp/partmap.$filename"

		local part
		part_magic_efi "$disk" && {
			#export_partdevice will fail when partition number is greater than 15, as
			#the partition major device number is not equal to the disk major device number
			for part in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
				set -- $(hexdump -v -n 48 -s "$((0x380 + $part * 0x80))" -e '4/4 "%08x"" "4/4 "%08x"" "4/4 "0x%08X "' "$disk")

				local type="$1"
				local lba="$(( $(hex_le32_to_cpu $4) * 0x100000000 + $(hex_le32_to_cpu $3) ))"
				local end="$(( $(hex_le32_to_cpu $6) * 0x100000000 + $(hex_le32_to_cpu $5) ))"
				local num="$(( $end - $lba + 1 ))"

				[ "$type" = "00000000000000000000000000000000" ] && continue

				printf "%2d %5d %7d\n" $part $lba $num >> "/tmp/partmap.$filename"
			done
		} || {
			for part in 1 2 3 4; do
				set -- $(hexdump -v -n 12 -s "$((0x1B2 + $part * 16))" -e '3/4 "0x%08X "' "$disk")

				local type="$(( $(hex_le32_to_cpu $1) % 256))"
				local lba="$(( $(hex_le32_to_cpu $2) ))"
				local num="$(( $(hex_le32_to_cpu $3) ))"

				[ $type -gt 0 ] || continue

				printf "%2d %5d %7d\n" $part $lba $num >> "/tmp/partmap.$filename"
			done
		}
	fi
}

indicate_upgrade() {
	. /etc/diag.sh
	set_state upgrade
}

# Flash firmware to MTD partition
#
# $(1): path to image
# $(2): (optional) pipe command to extract firmware, e.g. dd bs=n skip=m
default_do_upgrade() {
	sync
	echo 3 > /proc/sys/vm/drop_caches
	if [ -n "$UPGRADE_BACKUP" ]; then
		get_image "$1" "$2" | mtd $MTD_ARGS $MTD_CONFIG_ARGS -j "$UPGRADE_BACKUP" write - "${PART_NAME:-image}"
	else
		get_image "$1" "$2" | mtd $MTD_ARGS write - "${PART_NAME:-image}"
	fi
	[ $? -ne 0 ] && exit 1
}
