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
  --disk DEVICE        Target device (e.g., /dev/sda)
  --esp-size SIZE      EFI partition size (default: 512M)
  --swap-size SIZE     Swap size (default: 2G)
  --root-size SIZE     Root partition size (default: rest)
  --home-size SIZE     Home partition size (optional)
  --fs FS              Filesystem: ext4, btrfs, xfs (default: ext4)
  --btrfs-subvols SUBS Comma-separated BTRFS subvolumes (default: @,@home,@nix,@var)
  --mount-point PATH   Base mount point (default: /mnt)
  --label LABEL        Root partition label (default: root)
  --dry-run            Show commands without executing
  -y, --yes            Skip confirmation
  -h, --help           Show this help

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
	_basename
	basename="$(basename "$disk")"

	case "$basename" in
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
	lsblk -n -o SIZE -b "$disk" 2>/dev/null | head -1 | tr -d ' '
}

get_disk_model() {
	_disk="$1"
	_model
	model="$(lsblk -n -o MODEL "$disk" 2>/dev/null | head -1 | tr -d ' ')"
	if [ -z "$model" ]; then
		model="$(cat "/sys/block/$(basename "$disk")/device/model" 2>/dev/null | tr -d ' ')"
	fi
	if [ -z "$model" ]; then
		model="Unknown"
	fi
	echo "$model"
}

is_safe_disk() {
	_disk="$1"
	_basename
	basename="$(basename "$disk")"

	case "$basename" in
	loop* | rom* | squashfs*)
		return 1
		;;
	esac

	_root_dev
	root_dev="$(lsblk -n -o PKNAME "$(df / | tail -1 | awk '{print $1}')" 2>/dev/null | head -1)"
	if [ "$basename" = "$root_dev" ]; then
		return 1
	fi

	return 0
}

list_available_disks() {
	_disks=""
	for dev in /dev/sd[a-z] /dev/vd[a-z] /dev/nvme[0-9]*n1; do
		if [ -e "$dev" ] && is_safe_disk "$dev"; then
			disks="$disks $dev"
		fi
	done
	echo "$disks" | tr -s ' '
}

detect_ram_size() {
	_ram_kb
	ram_kb="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
	_ram_gb
	ram_gb=$((ram_kb / 1024 / 1024))

	if [ "$ram_gb" -le 2 ]; then
		echo "1G"
	elif [ "$ram_gb" -le 8 ]; then
		echo "2G"
	elif [ "$ram_gb" -le 16 ]; then
		echo "4G"
	elif [ "$ram_gb" -le 32 ]; then
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
		whiptail --title "$title" --msgbox "$message" 0 0 2>/dev/null
		;;
	dialog)
		dialog --title "$title" --msgbox "$message" 0 0 2>/dev/null
		;;
	*)
		echo "=== $title ==="
		echo "$message"
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
		whiptail --title "$title" --yesno "$message" 0 0 2>/dev/null
		;;
	dialog)
		dialog --title "$title" --yesno "$message" 0 0 2>/dev/null
		;;
	*)
		echo "=== $title ==="
		echo "$message"
		printf "Type 'yes' to confirm: "
		read -r ans
		[ "$ans" = "yes" ]
		;;
	esac
}

render_menu() {
	_title="$1"
	_prompt="$2"
	shift 2

	_items=""
	while [ $# -gt 0 ]; do
		items="$items \"$1\" \"$2\""
		shift 2
	done

	case "$TUI_BACKEND" in
	whiptail)
		eval whiptail --title "$title" --menu "$prompt" 0 0 0 $items 2>/dev/null
		;;
	dialog)
		eval dialog --title "$title" --menu "$prompt" 0 0 0 $items 2>/dev/null
		;;
	*)
		echo "=== $title ==="
		echo "$prompt"
		_i=1
		_options=""
		while [ $# -gt 0 ]; do
			echo "$i) $1 ($2)"
			options="$options $1"
			shift 2
			i=$((i + 1))
		done
		printf "Select option: "
		read -r ans
		i=1
		for opt in $options; do
			[ "$ans" = "$i" ] && echo "$opt" && return 0
			i=$((i + 1))
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
		whiptail --title "$title" --inputbox "$prompt" 0 0 "$default" 2>/dev/null
		;;
	dialog)
		dialog --title "$title" --inputbox "$prompt" 0 0 "$default" 2>/dev/null
		;;
	*)
		echo "=== $title ==="
		echo "$prompt"
		[ -n "$default" ] && echo "Default: $default"
		printf "Value: "
		read -r ans
		[ -z "$ans" ] && echo "$default" || echo "$ans"
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
	_disks
	disks="$(list_available_disks)"

	if [ -z "$disks" ]; then
		die "No available disks found"
	fi

	_items=""
	for disk in $disks; do
		_size model
		size="$(get_disk_size "$disk")"
		model="$(get_disk_model "$disk")"
		items="$items \"$disk\" \"${size} - ${model}\""
	done

	_selected
	selected="$(render_menu "Select Disk" "Choose the target disk:" $items)" || die "No disk selected"

	TARGET_DISK="$selected"
}

show_layout_choice() {
	_choice
	choice="$(render_menu "Partition Layout" "Choose partition scheme:" \
		"default" "ESP + Swap + Root (recommended)" \
		"custom" "Customize partition sizes")" || choice="default"

	if [ "$choice" = "default" ]; then
		ROOT_SIZE="+"
	else
		show_custom_layout
	fi
}

show_custom_layout() {
	_esp
	esp="$(render_input "EFI Partition" "Enter EFI partition size:" "$ESP_SIZE")" || esp="$ESP_SIZE"
	ESP_SIZE="${esp:-$DEFAULT_ESP_SIZE}"

	_swap
	swap="$(render_input "Swap Partition" "Enter swap size (or 'none' to skip):" "$SWAP_SIZE")" || swap="$SWAP_SIZE"
	SWAP_SIZE="${swap:-$DEFAULT_SWAP_SIZE}"

	_root
	root="$(render_input "Root Partition" "Enter root size (+ for rest, or exact size):" "+")"
	ROOT_SIZE="${root:-"+"}"

	_home
	home="$(render_input "Home Partition" "Enter home size (empty for none):" "")"
	if [ -n "$home" ]; then
		HOME_SIZE="$home"
	fi
}

show_fs_selection() {
	_choice
	choice="$(render_menu "Filesystem" "Choose filesystem:" \
		"ext4" "ext4 (recommended, stable)" \
		"btrfs" "btrfs (with subvolumes support)" \
		"xfs" "xfs (high performance)")" || choice="$DEFAULT_FS"

	FS="$choice"

	if [ "$FS" = "btrfs" ]; then
		show_btrfs_subvols
	fi
}

show_btrfs_subvols() {
	_subvols
	subvols="$(render_input "BTRFS Subvolumes" "Enter comma-separated subvolume names:" "$BTRFS_SUBVOLS")" || subvols="$BTRFS_SUBVOLS"
	BTRFS_SUBVOLS="${subvols:-"@,@home,@nix,@var"}"
}

show_review() {
	_summary
	summary="Target Disk: $TARGET_DISK
EFI Size: $ESP_SIZE
Swap Size: $SWAP_SIZE
Root Size: $ROOT_SIZE"

	if [ -n "$HOME_SIZE" ]; then
		summary="$summary
Home Size: $HOME_SIZE"
	fi

	summary="$summary
Filesystem: $FS
Mount Point: $MOUNT_POINT
Label: $LABEL"

	if [ "$FS" = "btrfs" ]; then
		summary="$summary
Subvolumes: $BTRFS_SUBVOLS"
	fi

	if [ "$DRY_RUN" = "true" ]; then
		summary="$summary
*** DRY RUN MODE - No changes will be made ***"
	fi

	render_msgbox "Review Configuration" "$summary"
}

confirm_execution() {
	if [ "$AUTO_CONFIRM" = "true" ]; then
		return 0
	fi

	_msg="This will ERASE ALL DATA on $TARGET_DISK
Are you sure you want to continue?"

	render_yesno "Confirm Execution" "$msg" || die "Operation cancelled"
}

execute_partitioning() {
	_disk="$TARGET_DISK"
	_suffix
	suffix="$(get_partition_suffix "$disk")"

	if [ "$DRY_RUN" = "true" ]; then
		echo "=== DRY RUN - Commands that would be executed ==="
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Wiping disk signatures..."
		wipefs -a "$disk" 2>/dev/null || true
		sgdisk -Z "$disk"
	fi

	_part_num=1
	_start_sector=1M

	if [ "$DRY_RUN" != "true" ]; then
		echo "Creating EFI partition..."
		sgdisk -n "${part_num}:${start_sector}:+${ESP_SIZE}" \
			-c "${part_num}:${disk}${suffix}${part_num}-ESP" \
			-t "${part_num}:ef00" "$disk"
	else
		echo "sgdisk -n ${part_num}:${start_sector}:+${ESP_SIZE} -c ${part_num}:ESP -t ${part_num}:ef00 $disk"
	fi

	part_num=$((part_num + 1))
	_next_start
	next_start="+${ESP_SIZE}"

	if [ "$SWAP_SIZE" != "none" ] && [ -n "$SWAP_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Creating swap partition..."
			sgdisk -n "${part_num}:${next_start}:+${SWAP_SIZE}" \
				-c "${part_num}:${disk}${suffix}${part_num}-swap" \
				-t "${part_num}:8200" "$disk"
		else
			echo "sgdisk -n ${part_num}:${next_start}:+${SWAP_SIZE} -c ${part_num}:swap -t ${part_num}:8200 $disk"
		fi
		part_num=$((part_num + 1))
		next_start="+${SWAP_SIZE}"
	fi

	if [ -n "$HOME_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Creating home partition..."
			sgdisk -n "${part_num}:${next_start}:+${HOME_SIZE}" \
				-c "${part_num}:${disk}${suffix}${part_num}-home" \
				-t "${part_num}:8300" "$disk"
		else
			echo "sgdisk -n ${part_num}:${next_start}:+${HOME_SIZE} -c ${part_num}:home -t ${part_num}:8300 $disk"
		fi
		part_num=$((part_num + 1))
		next_start="+${HOME_SIZE}"
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Creating root partition..."
		sgdisk -n "${part_num}:${next_start}:0" \
			-c "${part_num}:${disk}${suffix}${part_num}-root" \
			-t "${part_num}:8300" "$disk"
	else
		echo "sgdisk -n ${part_num}:${next_start}:0 -c ${part_num}:root -t ${part_num}:8300 $disk"
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Refreshing partition table..."
		partprobe "$disk"
		udevadm trigger
		sleep 2
	fi

	part_num=1

	if [ "$DRY_RUN" != "true" ]; then
		echo "Formatting EFI partition..."
		mkfs.fat -F 32 "${disk}${suffix}${part_num}"
	else
		echo "mkfs.fat -F 32 ${disk}${suffix}${part_num}"
	fi

	part_num=$((part_num + 1))

	if [ "$SWAP_SIZE" != "none" ] && [ -n "$SWAP_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Formatting swap partition..."
			mkswap "${disk}${suffix}${part_num}"
			swapon "${disk}${suffix}${part_num}"
		else
			echo "mkswap ${disk}${suffix}${part_num}"
			echo "swapon ${disk}${suffix}${part_num}"
		fi
		part_num=$((part_num + 1))
	fi

	if [ -n "$HOME_SIZE" ]; then
		if [ "$DRY_RUN" != "true" ]; then
			echo "Formatting home partition..."
			case "$FS" in
			ext4)
				mkfs.ext4 -F "${disk}${suffix}${part_num}"
				;;
			btrfs)
				mkfs.btrfs -f "${disk}${suffix}${part_num}"
				;;
			xfs)
				mkfs.xfs -f "${disk}${suffix}${part_num}"
				;;
			esac
		else
			echo "mkfs.$FS ${disk}${suffix}${part_num}"
		fi
		part_num=$((part_num + 1))
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Formatting root partition..."
		case "$FS" in
		ext4)
			mkfs.ext4 -L "$LABEL" -F "${disk}${suffix}${part_num}"
			;;
		btrfs)
			mkfs.btrfs -L "$LABEL" -f "${disk}${suffix}${part_num}"
			;;
		xfs)
			mkfs.xfs -L "$LABEL" -f "${disk}${suffix}${part_num}"
			;;
		esac
	else
		echo "mkfs.$FS -L $LABEL ${disk}${suffix}${part_num}"
	fi

	if [ "$DRY_RUN" != "true" ]; then
		echo "Mounting filesystems..."

		if [ "$FS" = "btrfs" ]; then
			mount -o "$BTRFS_OPTS" "${disk}${suffix}${part_num}" "$MOUNT_POINT"

			old_ifs="$IFS"
			IFS=','
			for subvol in $BTRFS_SUBVOLS; do
				echo "Creating subvolume: $subvol"
				btrfs subvolume create "$MOUNT_POINT/$subvol"
			done
			IFS="$old_ifs"

			umount "$MOUNT_POINT"

			mount -o "$BTRFS_OPTS,subvol=@" "${disk}${suffix}${part_num}" "$MOUNT_POINT"

			mkdir -p "$MOUNT_POINT/boot"
		else
			mount "${disk}${suffix}${part_num}" "$MOUNT_POINT"
		fi

		mkdir -p "$MOUNT_POINT/boot/efi"
		mount "${disk}${suffix}1" "$MOUNT_POINT/boot/efi"

		echo "Mounting complete!"
		echo ""
		echo "Summary:"
		echo "  Mount point: $MOUNT_POINT"
		echo "  EFI: ${disk}${suffix}1 -> $MOUNT_POINT/boot/efi"
		echo "  Root: ${disk}${suffix}${part_num} -> $MOUNT_POINT"
		if [ "$FS" = "btrfs" ]; then
			echo "  BTRFS subvolumes: $BTRFS_SUBVOLS"
		fi
	else
		echo "mount -o $BTRFS_OPTS ${disk}${suffix}${part_num} $MOUNT_POINT"
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
