#!/bin/sh
# ParTUI - Interactive partitioning wizard
# Usage: sh partui.sh [--disk /dev/sda] [--fs ext4] [--dry-run] [--yes]
# Supports: curl -fsSL <URL> | sudo sh -s -- --disk /dev/sda --yes

set -euo pipefail

DEFAULT_ESP_SIZE="512M"
DEFAULT_SWAP_SIZE="2G"
DEFAULT_FS="ext4"
DEFAULT_MOUNT_POINT="/mnt"
DEFAULT_LABEL="root"
BTRFS_OPTS="compress=zstd,noatime,discard=async"

die() {
	echo "$*" >&2
	exit 1
}

warn() { echo "$*" >&2; }

usage() {
	cat <<EOF
ParTUI - Interactive partitioning wizard

Usage: $(basename "$0") [OPTIONS]

Options:
  --disk DEVICE         Target device (e.g., /dev/sda)
  --esp-size SIZE       EFI partition size (default: 512M)
  --swap-size SIZE      Swap size (default: 2G)
  --root-size SIZE      Root partition size (default: rest)
  --home-size SIZE      Home partition size (optional)
  --fs FS               Filesystem: ext4, btrfs, xfs (default: ext4)
  --btrfs-subvols SUBS  Comma-separated BTRFS subvolumes (default: @,@home,@nix,@var)
  --mount-point PATH    Base mount point (default: /mnt)
  --label LABEL         Root partition label (default: root)
  --dry-run             Show commands without executing
  -y, --yes             Skip confirmation
  -h, --help            Show this help

Examples:
  $(basename "$0") --disk /dev/sda --fs btrfs --yes
  $(basename "$0") --disk /dev/nvme0n1 --esp-size 1G --swap-size 4G --dry-run
  curl -fsSL <URL> | sudo sh -s -- --disk /dev/sda --fs btrfs --yes

EOF
	exit 0
}

TARGET_DISK=""
ESP_SIZE=""
SWAP_SIZE=""
ROOT_SIZE=""
HOME_SIZE=""
FS=""
BTRFS_SUBVOLS=""
MOUNT_POINT=""
LABEL=""
DRY_RUN="false"
AUTO_CONFIRM="false"
INTERACTIVE="true"

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		--disk)
			TARGET_DISK="$2"
			shift 2
			;;
		--esp-size)
			ESP_SIZE="$2"
			shift 2
			;;
		--swap-size)
			SWAP_SIZE="$2"
			shift 2
			;;
		--root-size)
			ROOT_SIZE="$2"
			shift 2
			;;
		--home-size)
			HOME_SIZE="$2"
			shift 2
			;;
		--fs)
			FS="$2"
			shift 2
			;;
		--btrfs-subvols)
			BTRFS_SUBVOLS="$2"
			shift 2
			;;
		--mount-point)
			MOUNT_POINT="$2"
			shift 2
			;;
		--label)
			LABEL="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		-y | --yes)
			AUTO_CONFIRM="true"
			shift
			;;
		-h | --help)
			usage
			;;
		*)
			die "Unknown option: $1. Use --help for usage information."
			;;
		esac
	done

	if [ -n "$TARGET_DISK" ]; then
		INTERACTIVE="false"
	fi
}

check_root() {
	if [ "$(id -u)" -ne 0 ]; then
		die "This script must be run as root"
	fi
}

check_dependencies() {
	command -v lsblk >/dev/null 2>&1 || die "lsblk is required"
	command -v sgdisk >/dev/null 2>&1 || command -v sfdisk >/dev/null 2>&1 || die "sgdisk or sfdisk is required"
	command -v wipefs >/dev/null 2>&1 || die "wipefs is required"
	command -v mkfs.fat >/dev/null 2>&1 || die "mkfs.fat (dosfstools) is required"
	command -v mkswap >/dev/null 2>&1 || die "mkswap is required"
	command -v mount >/dev/null 2>&1 || die "mount is required"
	command -v partprobe >/dev/null 2>&1 || die "partprobe is required"
}

get_partition_suffix() {
	_disk="$1"
	_basename="$(basename "$_disk")"

	case "$_basename" in
	nvme* | loop* | rd*)
		echo "p"
		;;
	*)
		echo ""
		;;
	esac
}

get_disk_size() {
	_disk="$1"
	lsblk -n -o SIZE -b "$_disk" 2>/dev/null | head -1 | tr -d ' '
}

get_disk_model() {
	_disk="$1"
	_model="$(lsblk -n -o MODEL "$_disk" 2>/dev/null | head -1 | tr -d ' ' || true)"

	_sysfs_model="/sys/block/$(basename "$_disk")/device/model"
	if [ -z "$_model" ] && [ -f "$_sysfs_model" ]; then
		_model="$(cat "$_sysfs_model" 2>/dev/null | tr -d ' ' || true)"
	fi

	[ -z "$_model" ] && _model="Unknown"
	echo "$_model"
}

is_safe_disk() {
	_disk="$1"
	_basename="$(basename "$_disk")"

	case "$_basename" in
	loop* | rom* | squashfs*) return 1 ;;
	esac

	_root_fs="$(df / | tail -1 | awk '{print $1}')"
	# Solo ejecutar lsblk si la raiz es un dispositivo fisico (/dev/...)
	if echo "$_root_fs" | grep -q "^/dev/"; then
		_root_dev="$(lsblk -n -o PKNAME "$_root_fs" 2>/dev/null | head -1 || true)"
		if [ "$_basename" = "$_root_dev" ]; then
			return 1
		fi
	fi

	return 0
}

list_available_disks() {
	_disks=""
	for _dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]*n1; do
		if [ -e "$_dev" ] && is_safe_disk "$_dev"; then
			_disks="$_disks $_dev"
		fi
	done
	echo "$_disks" | tr -s ' '
}

detect_ram_size() {
	_ram_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
	_ram_gb=$((_ram_kb / 1024 / 1024))

	if [ "$_ram_gb" -le 2 ]; then
		echo "1G"
	elif [ "$_ram_gb" -le 8 ]; then
		echo "2G"
	elif [ "_ram_gb" -le 16 ]; then
		echo "4G"
	elif [ "$_ram_gb" -le 32 ]; then
		echo "8G"
	else
		echo "8G"
	fi
}

TUI_BACKEND=""

detect_tui() {
	if command -v whiptail >/dev/null 2>&1; then
		TUI_BACKEND="whiptail"
	elif command -v dialog >/dev/null 2>&1; then
		TUI_BACKEND="dialog"
	else
		TUI_BACKEND="select"
	fi
}

render_msgbox() {
	_title="$1"
	_message="$2"

	case "$TUI_BACKEND" in
	whiptail)
		# Elimina 2>/dev/null y agrega el swap de descriptores
		eval whiptail --title "$_title" --msgbox "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	dialog)
		eval dialog --title "$_title" --msgbox "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	*)
		echo "=== $_title ==="
		echo "$_message"
		echo "Press Enter to continue..."
		read -r _
		;;
	esac
}

render_yesno() {
	_title="$1"
	_message="$2"

	case "$TUI_BACKEND" in
	whiptail)
		# Elimina 2>/dev/null y agrega el swap de descriptores
		eval whiptail --title "$_title" --yesno "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	dialog)
		eval dialog --title "$_title" --yesno "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	*)
		echo "=== $_title ==="
		echo "$_message"
		printf "Type 'yes' to confirm: "
		read -r _ans
		[ "$_ans" = "yes" ]
		;;
	esac
}

render_menu() {
	_title="$1"
	_prompt="$2"
	shift 2

	_items=""
	while [ $# -gt 0 ]; do
		_items="$_items \"$1\" \"$2\""
		shift 2
	done

	case "$TUI_BACKEND" in
	whiptail)
		# Elimina 2>/dev/null y agrega el swap de descriptores
		eval whiptail --title "$_title" --menu "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	dialog)
		eval dialog --title "$_title" --menu "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	*)
		echo "=== $_title ==="
		echo "$_prompt"
		_i=1
		_options=""
		while [ $# -gt 0 ]; do
			echo "$_i) $1 ($2)"
			_options="$_options $1"
			shift 2
			_i=$((_i + 1))
		done
		printf "Select option: "
		read -r _ans
		_i=1
		for _opt in $_options; do
			[ "$_ans" = "$_i" ] && echo "$_opt" && return 0
			_i=$((_i + 1))
		done
		echo ""
		;;
	esac
}

render_input() {
	_title="$1"
	_prompt="$2"
	_default="$3"

	case "$TUI_BACKEND" in
	whiptail)
		# Elimina 2>/dev/null y agrega el swap de descriptores
		eval whiptail --title "$_title" --inputbox "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	dialog)
		eval dialog --title "$_title" --inputbox "$_prompt" 0 0 0 $_items 3>&1 1>&2 2>&3
		;;
	*)
		echo "=== $_title ==="
		echo "$_prompt"
		[ -n "$_default" ] && echo "Default: $_default"
		printf "Value: "
		read -r _ans
		[ -z "$_ans" ] && echo "$_default" || echo "$_ans"
		;;
	esac
}

apply_defaults() {
	[ -z "$ESP_SIZE" ] && ESP_SIZE="$DEFAULT_ESP_SIZE"
	[ -z "$SWAP_SIZE" ] && SWAP_SIZE="$(detect_ram_size)"
	[ -z "$FS" ] && FS="$DEFAULT_FS"
	[ -z "$MOUNT_POINT" ] && MOUNT_POINT="$DEFAULT_MOUNT_POINT"
	[ -z "$LABEL" ] && LABEL="$DEFAULT_LABEL"
	[ -z "$BTRFS_SUBVOLS" ] && BTRFS_SUBVOLS="@,@home,@nix,@var"
}

show_disk_selection() {
	_disks="$(list_available_disks)"

	if [ -z "$_disks" ]; then
		die "No available disks found"
	fi

	_items=""
	for _disk in $_disks; do
		_size="$(get_disk_size "$_disk")"
		_model="$(get_disk_model "$_disk")"
		_items="$_items \"$_disk\" \"${_size} - ${_model}\""
	done

	_selected="$(render_menu "Select Disk" "Choose the target disk:" $_items)" || die "No disk selected"

	TARGET_DISK="$_selected"
}

show_layout_choice() {
	_choice="$(render_menu "Partition Layout" "Choose partition scheme:" \
		"default" "ESP + Swap + Root (recommended)" \
		"custom" "Customize partition sizes")" || _choice="default"

	if [ "$_choice" = "default" ]; then
		ROOT_SIZE="+"
	else
		show_custom_layout
	fi
}

show_custom_layout() {
	_esp="$(render_input "EFI Partition" "Enter EFI partition size:" "$ESP_SIZE")" || _esp="$ESP_SIZE"
	ESP_SIZE="${_esp:-$DEFAULT_ESP_SIZE}"

	_swap="$(render_input "Swap Partition" "Enter swap size (or 'none' to skip):" "$SWAP_SIZE")" || _swap="$SWAP_SIZE"
	SWAP_SIZE="${_swap:-$DEFAULT_SWAP_SIZE}"

	_root="$(render_input "Root Partition" "Enter root size (+ for rest, or exact size):" "+")"
	ROOT_SIZE="${_root:-"+"}"

	_home="$(render_input "Home Partition" "Enter home size (empty for none):" "")"
	if [ -n "$_home" ]; then
		HOME_SIZE="$_home"
	fi
}

show_fs_selection() {
	_choice="$(render_menu "Filesystem" "Choose filesystem:" \
		"ext4" "ext4 (recommended, stable)" \
		"btrfs" "btrfs (with subvolumes support)" \
		"xfs" "xfs (high performance)")" || _choice="$DEFAULT_FS"

	FS="$_choice"

	if [ "$FS" = "btrfs" ]; then
		show_btrfs_subvols
	fi
}

show_btrfs_subvols() {
	_subvols="$(render_input "BTRFS Subvolumes" "Enter comma-separated subvolume names:" "$BTRFS_SUBVOLS")" || _subvols="$BTRFS_SUBVOLS"
	BTRFS_SUBVOLS="${_subvols:-"@,@home,@nix,@var"}"
}

show_review() {
	_summary="Target Disk: $TARGET_DISK
EFI Size: $ESP_SIZE
Swap Size: $SWAP_SIZE
Root Size: $ROOT_SIZE"

	if [ -n "$HOME_SIZE" ]; then
		_summary="$_summary
Home Size: $HOME_SIZE"
	fi

	_summary="$_summary
Filesystem: $FS
Mount Point: $MOUNT_POINT
Label: $LABEL"

	if [ "$FS" = "btrfs" ]; then
		_summary="$_summary
Subvolumes: $BTRFS_SUBVOLS"
	fi

	if [ "$DRY_RUN" = "true" ]; then
		_summary="$_summary
*** DRY RUN MODE - No changes will be made ***"
	fi

	render_msgbox "Review Configuration" "$_summary"
}

confirm_execution() {
	if [ "$AUTO_CONFIRM" = "true" ]; then
		return 0
	fi

	_msg="This will ERASE ALL DATA on $TARGET_DISK
Are you sure you want to continue?"

	render_yesno "Confirm Execution" "$_msg" || die "Operation cancelled"
}

execute_partitioning() {
	_disk="$TARGET_DISK"
	_suffix="$(get_partition_suffix "$_disk")"

	if [ "$DRY_RUN" = "true" ]; then
		echo "=== DRY RUN - Commands that would be executed ==="
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Wiping disk signatures..."
		wipefs -a "$_disk" 2>/dev/null || true
		sgdisk -Z "$_disk"
	fi

	_part_num=1
	_start_sector=1M

	if [ "$DRY_RUN" != "true" ]; then
		echo "Creating EFI partition..."
		sgdisk -n "${_part_num}:${_start_sector}:+${ESP_SIZE}" \
			-c "${_part_num}:${_disk}${_suffix}${_part_num}-ESP" \
			-t "${_part_num}:ef00" "$_disk"
	else
		echo "sgdisk -n ${_part_num}:${_start_sector}:+${ESP_SIZE} -c ${_part_num}:ESP -t ${_part_num}:ef00 $_disk"
	fi

	_part_num=$((_part_num + 1))
	_next_start="+${ESP_SIZE}"

	if [ "$SWAP_SIZE" != "none" ] && [ -n "$SWAP_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Creating swap partition..."
			sgdisk -n "${_part_num}:${_next_start}:+${SWAP_SIZE}" \
				-c "${_part_num}:${_disk}${_suffix}${_part_num}-swap" \
				-t "${_part_num}:8200" "$_disk"
		else
			echo "sgdisk -n ${_part_num}:${_next_start}:+${SWAP_SIZE} -c ${_part_num}:swap -t ${_part_num}:8200 $_disk"
		fi
		_part_num=$((_part_num + 1))
		_next_start="+${SWAP_SIZE}"
	fi

	if [ -n "$HOME_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Creating home partition..."
			sgdisk -n "${_part_num}:${_next_start}:+${HOME_SIZE}" \
				-c "${_part_num}:${_disk}${_suffix}${_part_num}-home" \
				-t "${_part_num}:8300" "$_disk"
		else
			echo "sgdisk -n ${_part_num}:${_next_start}:+${HOME_SIZE} -c ${_part_num}:home -t ${_part_num}:8300 $_disk"
		fi
		_part_num=$((_part_num + 1))
		_next_start="+${HOME_SIZE}"
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Creating root partition..."
		sgdisk -n "${_part_num}:${_next_start}:0" \
			-c "${_part_num}:${_disk}${_suffix}${_part_num}-root" \
			-t "${_part_num}:8300" "$_disk"
	else
		echo "sgdisk -n ${_part_num}:${_next_start}:0 -c ${_part_num}:root -t ${_part_num}:8300 $_disk"
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Refreshing partition table..."
		partprobe "$_disk"
		udevadm trigger
		sleep 2
	fi

	_part_num=1

	if [ "$DRY_RUN" != "true" ]; then
		echo "Formatting EFI partition..."
		mkfs.fat -F 32 "${_disk}${_suffix}${_part_num}"
	else
		echo "mkfs.fat -F 32 ${_disk}${_suffix}${_part_num}"
	fi

	_part_num=$((_part_num + 1))

	if [ "$SWAP_SIZE" != "none" ] && [ -n "$SWAP_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Formatting swap partition..."
			mkswap "${_disk}${_suffix}${_part_num}"
			swapon "${_disk}${_suffix}${_part_num}"
		else
			echo "mkswap ${_disk}${_suffix}${_part_num}"
			echo "swapon ${_disk}${_suffix}${_part_num}"
		fi
		_part_num=$((_part_num + 1))
	fi

	if [ -n "$HOME_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Formatting home partition..."
			case "$FS" in
			ext4)
				mkfs.ext4 -F "${_disk}${_suffix}${_part_num}"
				;;
			btrfs)
				mkfs.btrfs -f "${_disk}${_suffix}${_part_num}"
				;;
			xfs)
				mkfs.xfs -f "${_disk}${_suffix}${_part_num}"
				;;
			esac
		else
			echo "mkfs.$FS ${_disk}${_suffix}${_part_num}"
		fi
		_part_num=$((_part_num + 1))
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Formatting root partition..."
		case "$FS" in
		ext4)
			mkfs.ext4 -L "$LABEL" -F "${_disk}${_suffix}${_part_num}"
			;;
		btrfs)
			mkfs.btrfs -L "$LABEL" -f "${_disk}${_suffix}${_part_num}"
			;;
		xfs)
			mkfs.xfs -L "$LABEL" -f "${_disk}${_suffix}${_part_num}"
			;;
		esac
	else
		echo "mkfs.$FS -L $LABEL ${_disk}${_suffix}${_part_num}"
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Mounting filesystems..."

		if [ "$FS" = "btrfs" ]; then
			mount -o "$BTRFS_OPTS" "${_disk}${_suffix}${_part_num}" "$MOUNT_POINT"

			_old_ifs="$IFS"
			IFS=','
			for _subvol in $BTRFS_SUBVOLS; do
				echo "Creating subvolume: $_subvol"
				btrfs subvolume create "$MOUNT_POINT/$_subvol"
			done
			IFS="$_old_ifs"

			umount "$MOUNT_POINT"

			mount -o "$BTRFS_OPTS,subvol=@" "${_disk}${_suffix}${_part_num}" "$MOUNT_POINT"

			mkdir -p "$MOUNT_POINT/boot"
		else
			mount "${_disk}${_suffix}${_part_num}" "$MOUNT_POINT"
		fi

		mkdir -p "$MOUNT_POINT/boot/efi"
		mount "${_disk}${_suffix}1" "$MOUNT_POINT/boot/efi"

		echo "Mounting complete!"
		echo ""
		echo "Summary:"
		echo "  Mount point: $MOUNT_POINT"
		echo "  EFI: ${_disk}${_suffix}1 -> $MOUNT_POINT/boot/efi"
		echo "  Root: ${_disk}${_suffix}${_part_num} -> $MOUNT_POINT"
		if [ "$FS" = "btrfs" ]; then
			echo "  BTRFS subvolumes: $BTRFS_SUBVOLS"
		fi
	else
		echo "mount -o $BTRFS_OPTS ${_disk}${_suffix}${_part_num} $MOUNT_POINT"
	fi
}

main() {
	parse_args "$@"

	check_root
	check_dependencies
	detect_tui

	apply_defaults

	if [ "$INTERACTIVE" = "true" ]; then
		show_disk_selection
		show_layout_choice
		show_fs_selection
		show_review
		confirm_execution
	else
		if [ -z "$TARGET_DISK" ]; then
			die "Error: --disk is required in non-interactive mode"
		fi

		if [ ! -b "$TARGET_DISK" ]; then
			die "Error: $TARGET_DISK is not a valid block device"
		fi

		if [ "$DRY_RUN" != "true" ]; then
			render_msgbox "Starting Partitioning" "Target: $TARGET_DISK\nFilesystem: $FS\nMount: $MOUNT_POINT"
		fi
	fi

	execute_partitioning

	if [ "$DRY_RUN" = "true" ]; then
		echo ""
		echo "=== DRY RUN COMPLETE ==="
		echo "No changes were made. Remove --dry-run to apply."
	fi
}

main "$@"
