# ParTUI - Interactive Partitioning Wizard

A POSIX-compliant shell script for partitioning, formatting, and mounting storage devices on Linux. Designed for live CD environments and automated workflows.

## Features

- **Interactive TUI**: Guided wizard with whiptail/dialog/fallback terminal menus
- **Zero Dependencies**: Uses only standard Linux utilities
- **BTRFS Support**: Native subvolume creation (@, @home, @nix, @var)
- **CLI Mode**: Non-interactive execution with flags
- **Dry-Run**: Preview operations before applying
- **Safe**: Excludes current system disk, requires root, confirms destructive actions
- **Portable**: 100% POSIX sh compatible

## Installation

### Quick Install (curl)

```bash
# Direct execution (requires root)
curl -fsSL https://raw.githubusercontent.com/user/repo/main/partui.sh | sudo sh -s -- --help

# Download locally
curl -fsSL https://raw.githubusercontent.com/user/repo/main/partui.sh -o partui.sh
chmod +x partui.sh
sudo ./partui.sh --help
```

### Requirements

- Root privileges (sudo)
- `lsblk`, `sgdisk` (or `sfdisk`), `wipefs`, `mkfs.fat`, `mkswap`, `mount`, `partprobe`
- Optional: `whiptail` or `dialog` for TUI (falls back to terminal prompts)

## Usage Guide

### Interactive Mode (Recommended for first use)

1. **Start the wizard:**
   ```bash
   sudo ./partui.sh
   ```

2. **Select target disk**: Choose from available disks (excludes current system disk)

3. **Choose layout**:
   - **Default**: ESP (512M) + Swap (auto-detected RAM) + Root (rest)
   - **Custom**: Define your own sizes

4. **Select filesystem**:
   - `ext4` - Stable, widely compatible
   - `btrfs` - Advanced with subvolumes, compression, snapshots
   - `xfs` - High performance

5. **BTRFS configuration** (if BTRFS selected):
   - Default subvolumes: `@`, `@home`, `@nix`, `@var`
   - Or enter custom comma-separated list

6. **Review**: Confirm the summary of operations

7. **Confirm**: Type "yes" to proceed (or use `--yes` flag to skip)

### Non-Interactive Mode (Automation)

```bash
# Basic usage
sudo ./partui.sh --disk /dev/sda --yes

# With BTRFS and custom sizes
sudo ./partui.sh --disk /dev/nvme0n1 --fs btrfs --esp-size 1G --swap-size 4G --yes

# Dry-run to preview
sudo ./partui.sh --disk /dev/sda --dry-run --yes
```

## CLI Options

| Flag | Description | Default |
|------|-------------|---------|
| `--disk DEVICE` | Target device | Interactive |
| `--esp-size SIZE` | EFI partition size | `512M` |
| `--swap-size SIZE` | Swap size (or `none`) | Auto (RAM) |
| `--root-size SIZE` | Root partition (`+` = rest) | Rest |
| `--home-size SIZE` | Home partition (optional) | None |
| `--fs FS` | Filesystem: ext4, btrfs, xfs | `ext4` |
| `--btrfs-subvols SUBS` | BTRFS subvolumes | `@,@home,@nix,@var` |
| `--mount-point PATH` | Base mount point | `/mnt` |
| `--label LABEL` | Root partition label | `root` |
| `--dry-run` | Show commands only | - |
| `-y, --yes` | Skip confirmation | - |
| `-h, --help` | Show help | - |

## Examples

### Basic ext4 Installation

```bash
sudo ./partui.sh --disk /dev/sda --yes
```

Output:
```
Target Disk: /dev/sda
EFI Size: 512M
Swap Size: 2G
Root Size: + (rest)
Filesystem: ext4
Mount Point: /mnt
```

### BTRFS with Subvolumes

```bash
sudo ./partui.sh \
  --disk /dev/nvme0n1 \
  --fs btrfs \
  --esp-size 1G \
  --swap-size 4G \
  --btrfs-subvols @,@home,@var,@snapshots \
  --mount-point /mnt \
  --yes
```

### Dry-Run Preview

```bash
sudo ./partui.sh --disk /dev/sda --fs btrfs --dry-run
```

Shows:
```
=== DRY RUN - Commands that would be executed ===
Wiping disk signatures...
sgdisk -Z /dev/sda
Creating EFI partition...
sgdisk -n 1:1M:+512M -c 1:ESP -t 1:ef00 /dev/sda
Creating swap partition...
sgdisk -n 2:+512M:+4G -c 2:swap -t 2:8200 /dev/sda
Creating root partition...
sgdisk -n 3:+4G:0 -c 3:root -t 3:8300 /dev/sda
...
```

### Using from Live CD

```bash
# Download and run with BTRFS
curl -fsSL https://your-repo/partitioning-wizard/partui.sh | sudo bash -s -- \
  --disk /dev/sda \
  --fs btrfs \
  --yes
```

## Partition Layout

### Default Scheme

| Partition | Type | Size | Filesystem | Mount |
|-----------|------|------|------------|-------|
| 1 | EFI | 512M | vfat | /boot/efi |
| 2 | Swap | RAM size | swap | - |
| 3 | Root | Rest | ext4/btrfs/xfs | /mnt |

### BTRFS Subvolumes

When BTRFS is selected, subvolumes are created:
- `@` - Root filesystem
- `@home` - /home
- `@nix` - /nix (NixOS store)
- `@var` - /var

Mounted with compression and discard options.

## Safety Features

- **Root check**: Aborts if not running as root
- **System disk protection**: Excludes the current boot disk
- **Device validation**: Verifies block device exists
- **Confirmation prompt**: Requires explicit "yes" unless `--yes` is used
- **Idempotent errors**: Stops on first failure, doesn't continue with inconsistent state
- **Dry-run mode**: Preview all commands without execution

## Disclaimer

**WARNING**: This script will ERASE ALL DATA on the selected disk. Always:
1. Backup important data before running
2. Verify the target disk is correct
3. Use `--dry-run` first to preview operations
4. Double-check the device path (e.g., `/dev/sda`, not `/dev/sda1`)

## License

MIT License - Use at your own risk.

## Contributing

Pull requests welcome. Ensure:
- POSIX compliance (pass `shellcheck -s sh`)
- Test on real hardware or VM
- Maintain idempotency and error handling
