
# Arch GUI Installer

An **automated Arch Linux installer** with a dialog-based "GUI", optional **LUKS encryption**, **desktop environments**, **swap choices**, **bootloader selection (systemd-boot or GRUB)**, and even a little **Snake game** to play while your system installs.

Built for the official [Arch Linux ISO](https://archlinux.org/download/).  
Safe: if Snake fails, the install continues.  
Resilient: retries downloads, refreshes mirrors if needed, supports a **Best-Effort mode** to keep going on non-critical errors.

---

## Features

- **Interactive TUI** with [dialog](https://invisible-island.net/dialog/)  
- **Disk setup**: EFI + swap (partition/file) + root  
- **Filesystem choices**: `ext4`, `btrfs` (with basic subvolumes), or `xfs`  
- **Encryption**: optional LUKS for root partition  
- **Swap options**: none / swap partition / swapfile  
- **Bootloaders**: choose between **systemd-boot** and **GRUB**  
- **Profiles**:  
  - `server` (minimal, no GUI)  
  - `xfce` (lightweight desktop)  
  - `kde` (Plasma desktop)  
  - `gnome` (GNOME desktop)  
- **User setup**: hostname, timezone, root password, non-root user  
- **Error handling**:  
  - **Critical steps** (partitioning, base install) → stop on error  
  - **Non-critical steps** (Snake, extra packages, services) → skip if they fail  
- **Snake game** runs in a `tmux` pane while Arch is installing 🐍  

---

## Quick Start

Run directly from the **Arch ISO**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Orang-Studio/OrangArch/main/setup.sh)
````

## Requirements

* **UEFI system** (script assumes UEFI boot)
* **Internet connection** (for pacstrap + package downloads)
* Run as **root** (`sudo -i` or root shell on the Arch ISO)
* Official **Arch Linux ISO** environment

The script installs needed tools (`dialog`, `tmux`, `python`, `parted`) if missing.

---

## Options Explained

* **Filesystem**: choose what to format root with (`ext4`, `btrfs`, or `xfs`)
* **Encryption**: optional LUKS (root password reused as passphrase by default)
* **Swap**:

  * None
  * Partition (dedicated swap partition)
  * File (on ext4/xfs; btrfs swapfile is skipped for safety)
* **Bootloader**:

  * `systemd-boot`: simple & clean (UEFI only)
  * `GRUB`: widely supported, better for dual-boot setups
* **Profiles**: install just base system or add a desktop
* **Best-Effort Mode**:

  * OFF → stop on any error (safer)
  * ON → skip non-critical errors and continue

---

## Snake Mode

During installation, the script launches `tmux` with two panes:

* **Left**: live install log (`tail -f`)
* **Right**: Python-based Snake game

Detach with <kbd>Ctrl</kbd>+<kbd>b</kbd> then <kbd>d</kbd>.
Reattach later with:

```bash
tmux attach -t archinst
```

---

## Disclaimer

* This script will **erase the target disk** you select.
* While it has some safety checks and retries, **no installer is 100% error-proof**.
* Always back up your data before installing.
* Use at your own risk.

---

## License

[GPLv3 License](./LICENSE) — copyleft, no warranty is provided.