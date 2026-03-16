# AGENTS.md - ParTUI (Partitioning Wizard)

## Project Overview

ParTUI is an interactive TUI wizard for partitioning, formatting, and mounting storage devices on UNIX-like systems. It is designed to be distributed via `curl | bash` from a remote URL.

## Specification Document

See `docs/specifications-product-document.md` for full requirements.

## Build/Lint/Test Commands

### Linting
```bash
# Install shellcheck first (required for linting)
# nix: nix-env -iA nixpkgs.shellcheck
# apt: apt install shellcheck
# brew: brew install shellcheck

# Lint all shell scripts (use -s for POSIX mode)
shellcheck -s sh partui.sh
```

### Running the Script
```bash
# Must run as root
sudo sh partui.sh

# Interactive mode
sudo sh partui.sh

# Non-interactive with CLI flags
sudo sh partui.sh --disk /dev/sda --fs btrfs --yes

# Dry-run mode (no changes)
sudo sh partui.sh --disk /dev/sda --dry-run --yes

# Installation via curl
curl -fsSL https://raw.githubusercontent.com/user/repo/main/partui.sh | sudo sh -s -- --disk /dev/sda
```

### Testing
- No automated tests exist for this project
- Manual testing required on a VM or test disk

## Code Style Guidelines (POSIX Compliance)

### CRITICAL: POSIX Only
- Use `#!/bin/sh` or `#!/usr/bin/env sh` (NOT `#!/bin/bash` or `#!/usr/bin/env bash`)
- NO bash-specific features: `declare`, `[[ ]]`, arrays associatives `declare -A`, `local` keyword
- Use POSIX-compliant constructs only

### Script Header
```sh
#!/bin/sh
# ParTUI - Interactive partitioning wizard
# Usage: sh partui.sh [--disk /dev/sda] [--fs ext4] [--dry-run] [--yes]
set -euo pipefail

die() { echo "$*" >&2; exit 1; }
```

### Variables
- Use UPPERCASE for constants: `TARGET_DISK`, `ESP_SIZE`
- Use lowercase for local variables: `disk_path`, `esp_size`
- Always quote variables: `"$VAR"` not `$VAR`
- Use meaningful, descriptive names

### Functions
- Define functions before calling them
- Use `function_name() { ... }` syntax
- Use `local` if available (bash), otherwise use prefixed vars: `_disk_path="$1"`
- Return values via `echo` or exit codes

### Error Handling
- Check exit codes: `command || die "error message"`
- Use `die()` function for fatal errors
- Verify prerequisites before executing
- Confirm destructive operations with user input

### Command Substitution
- Use `$(command)` over backticks: `$(date +%s)` not `` `date +%s` ``

### Conditionals
- Use `[ ]` (POSIX): `[ -z "$var" ]` not `[[ -z "$var" ]]`
- Quote strings in conditionals: `[ -z "$var" ]` not `[ -z $var ]`

### Loops (No Arrays in POSIX)
- Use word splitting with `for` and `read`:
  ```sh
  for disk in $disks; do
    echo "$disk"
  done
  ```
- Parse CSV/lists with `IFS=',' read -r ... <<EOF`

### State Management (No Associative Arrays)
Use naming convention instead:
```sh
# Bad (bash-specific)
declare -A LAYOUT
LAYOUT[type]="efi"

# Good (POSIX)
LAYOUT_PART1_TYPE="efi"
LAYOUT_PART1_SIZE="+512M"
```

## TUI Implementation

### Primary: whiptail
```sh
# Menu
whiptail --title "Select Disk" --menu "Choose:" 0 0 0 \
  "/dev/sda" "500GB SSD" \
  "/dev/nvme0n1" "1TB NVMe"

# Yes/No
whiptail --yesno "Continue?" 0 0

# Input
whiptail --inputbox "Enter size:" 0 0 "512M"
```

### Fallbacks (in order)
1. `whiptail` - primary TUI
2. `dialog` - fallback
3. `select` + `read` - final fallback (no external deps)

### TUI Wrapper Functions
```sh
render_menu() {
  local title="$1"
  local prompt="$2"
  shift 2
  # Try whiptail, then dialog, then select
}

render_yesno() {
  whiptail --yesno "$1" 0 0 2>/dev/null || dialog --yesno "$1" 0 0
}
```

## CLI Flags

Support these flags for non-interactive mode:
| Flag | Description |
| --- | --- |
| `--disk` | Target device (e.g., /dev/sda) |
| `--esp-size` | EFI partition size (default: 512M) |
| `--swap-size` | Swap size (default: 2G) |
| `--root-size` | Root partition size (default: rest) |
| `--fs` | Filesystem: ext4, btrfs, xfs (default: ext4) |
| `--btrfs-subvols` | BTRFS subvolumes comma-separated |
| `--mount-point` | Base mount point (default: /mnt) |
| `--dry-run` | Show commands without executing |
| `-y, --yes` | Skip confirmation |
| `-h, --help` | Show help |

## External Tools Required

| Tool | Package | Purpose |
| --- | --- | --- |
| `lsblk` | util-linux | List block devices |
| `sgdisk` | gdisk | Partition table (GPT) |
| `sfdisk` | fdisk | Alternative partitioner |
| `wipefs` | util-linux | Clear signatures |
| `mkfs.fat` | dosfstools | EFI/FAT32 |
| `mkswap` | util-linux | Swap |
| `mkfs.ext4` | e2fsprogs | ext4 |
| `mkfs.btrfs` | btrfs-progs | btrfs |
| `btrfs` | btrfs-progs | Subvolumes |
| `mount` | util-linux | Mount filesystems |
| `partprobe` | parted | Refresh partition table |
| `udevadm` | systemd | Trigger udev |
| `whiptail` | newt | TUI (or dialog) |

## Naming Conventions

### Files
- Shell scripts: `kebab-case`: `part-wizard.sh`, `disk-utils.sh`

### Functions
- Use snake_case: `check_root()`, `partition_disk()`, `mount_btrfs()`

### Variables
- Constants: `UPPERCASE`: `DEFAULT_ESP_SIZE`, `BTRFS_OPTS`
- Locals: `lowercase`: `disk_path`, `esp_size`
- Layout fields: `LAYOUT_PART1_TYPE`, `LAYOUT_PART1_SIZE`

## Documentation

### Comments
- Use comments to explain WHY, not WHAT
- Group related commands with comment headers

### Function Documentation
```sh
# Creates BTRFS subvolumes at the given mount point
# Arguments:
#   $1 - Mount point path
#   $2 - Subvolume name (comma-separated for multiple)
# Returns:
#   0 on success, 1 on failure
```

## Git Workflow

### Commit Messages
- Use imperative mood: "Add disk selection" not "Added disk selection"
- First line: max 50 characters
- Body: wrap at 72 characters

### Branch Naming
- Features: `feature/add-wizard-menu`
- Bug fixes: `fix/shebang-typo`
- Refactoring: `refactor/extract-utils`
