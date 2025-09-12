#!/usr/bin/env bash
# arch-gui-installer.sh
# Automated Arch Linux installer with dialog TUI, bootloader choice (systemd-boot/GRUB),
# optional LUKS, swap (partition/file), desktop choices, Best-Effort mode,
# and a Snake game that shows live progress & current step.
# MIT License

set -euo pipefail
VERSION="1.4.0"

# -------------------- helpers --------------------
die(){ echo "[ERROR] $*" >&2; exit 1; }
warn(){ echo "[WARN]  $*" >&2; }
info(){ echo "[INFO]  $*"; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root (root shell on Arch ISO)."; }
cmd(){ command -v "$1" >/dev/null 2>&1; }
is_uefi(){ [[ -d /sys/firmware/efi/efivars ]]; }
devpart(){ local d="$1" i="$2"; [[ "$d" =~ (nvme|mmcblk) ]] && echo "${d}p${i}" || echo "${d}${i}"; }
mem_mib(){ awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }

retry(){ # retry <tries> <cmd...>
  local tries="${1:-3}"; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    (( n>=tries )) && return 1
    sleep $((n*3))
  done
}

safe_run(){ # safe_run "desc" <cmd...>   (skips on failure if BEST_EFFORT=1)
  local desc="$1"; shift
  if ! "$@" >>"$LOGFILE" 2>&1; then
    warn "$desc failed."
    [[ "$BEST_EFFORT" == "1" ]] || die "$desc failed (Best-Effort OFF)."
  fi
}

# --------------- preflight ---------------
need_root
info "Arch GUI Installer v$VERSION"
is_uefi || die "This script targets UEFI systems. (Legacy BIOS not supported here.)"

# quick net check
if ! ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
  warn "No internet detected. Connect first (e.g., 'iwctl')."
fi

# deps (Arch ISO usually has python; we ensure the rest)
for p in dialog tmux python parted; do
  cmd "$p" || pacman -Sy --noconfirm --needed "$p"
done

TMPDIR="/tmp/arch-gui-installer"
mkdir -p "$TMPDIR"
LOGFILE="$TMPDIR/install.log"
: > "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

STATUS_JSON="/tmp/arch_gui_status.json"
emit_status(){ # emit_status <percent_int> <step...>
  local pct="$1"; shift
  local msg="$*"
  local tmp="${STATUS_JSON}.tmp"
  printf '{"percent":%d,"step":"%s"}\n' "$pct" "$(printf '%s' "$msg" | sed 's/"/\\"/g')" > "$tmp" && mv "$tmp" "$STATUS_JSON"
}
emit_status 0 "Preparing installer…"

title="Arch GUI Installer"

# --------------- inputs (dialog) ---------------
mapfile -t DISKS < <(lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1" "$2}')
((${#DISKS[@]})) || die "No disks found."
disk_items=(); for l in "${DISKS[@]}"; do disk_items+=("$(awk '{print $1}'<<<"$l")" "$(awk '{print $2}'<<<"$l")"); done
DISK=$(dialog --clear --stdout --no-tags --title "$title" --menu "Select target disk (ERASES ALL DATA)" 20 70 10 "${disk_items[@]}") || exit 1

FS=$(dialog --clear --stdout --title "$title" --menu "Root filesystem" 12 60 4 \
  ext4 "Simple & reliable" \
  btrfs "Snapshots (basic @/@home)" \
  xfs "Fast (no shrink)") || exit 1

BOOTLOADER=$(dialog --clear --stdout --title "$title" --menu "Bootloader" 12 60 2 \
  "systemd-boot" "Simple UEFI boot manager" \
  "grub"         "GRUB (widely compatible)") || exit 1

PROFILE=$(dialog --clear --stdout --title "$title" --menu "Install profile" 14 60 4 \
  "server" "Minimal (no GUI)" \
  "xfce"   "Light XFCE" \
  "kde"    "KDE Plasma" \
  "gnome"  "GNOME") || exit 1

ENCRYPT=$(dialog --clear --stdout --title "$title" --menu "Encrypt root (LUKS)?" 10 60 2 \
  "no"  "No encryption" \
  "yes" "Encrypt root with LUKS") || exit 1

RAM_MIB=$(mem_mib); SUG_SWAP=$(( RAM_MIB < 8192 ? RAM_MIB : 8192 ))
SWAP_KIND=$(dialog --clear --stdout --title "$title" --menu "Swap type" 12 60 3 \
  "none" "No swap" \
  "partition" "Dedicated swap partition" \
  "file" "Swapfile on root FS") || exit 1
SWAP_MIB="0"
if [[ "$SWAP_KIND" != "none" ]]; then
  SWAP_MIB=$(dialog --clear --stdout --title "$title" --inputbox "Swap size (MiB)" 8 60 "$SUG_SWAP") || exit 1
  [[ "$SWAP_MIB" =~ ^[0-9]+$ ]] || die "Swap size must be a number."
fi

BEST_EFFORT=$(dialog --clear --stdout --title "$title" --menu "On non-critical failures" 10 60 2 \
  "0" "Stop on error (safer)" \
  "1" "Best-Effort: try to continue") || exit 1

HOSTNAME=$(dialog --clear --stdout --title "$title" --inputbox "Hostname" 8 60 "archbox") || exit 1
USERNAME=$(dialog --clear --stdout --title "$title" --inputbox "New user name" 8 60 "arch") || exit 1
TIMEZONE=$(dialog --clear --stdout --title "$title" --inputbox "Timezone (Region/City)" 8 60 "Europe/Vilnius") || exit 1

PASS_ROOT=$(dialog --clear --stdout --insecure --title "$title" --passwordbox "Root password" 8 60) || exit 1
PASS_ROOT2=$(dialog --clear --stdout --insecure --title "$title" --passwordbox "Repeat root password" 8 60) || exit 1
[[ "$PASS_ROOT" == "$PASS_ROOT2" ]] || die "Root passwords do not match."

PASS_USER=$(dialog --clear --stdout --insecure --title "$title" --passwordbox "Password for $USERNAME" 8 60) || exit 1
PASS_USER2=$(dialog --clear --stdout --insecure --title "$title" --passwordbox "Repeat password for $USERNAME" 8 60) || exit 1
[[ "$PASS_USER" == "$PASS_USER2" ]] || die "User passwords do not match."

dialog --title "$title" --yes-label "I UNDERSTAND" --no-label "Cancel" --yesno \
"THIS WILL ERASE $DISK\n\nFS: $FS\nBootloader: $BOOTLOADER\nDesktop: $PROFILE\nEncrypt root: $ENCRYPT\nSwap: $SWAP_KIND ${SWAP_MIB}MiB\nBest-Effort: $BEST_EFFORT\nHostname: $HOSTNAME\nUser: $USERNAME\nTimezone: $TIMEZONE\n\nProceed?" 18 72 || exit 1

# --------------- Snake HUD (tmux) ---------------
emit_status 1 "Launching Snake & log panes…"
cat > "$TMPDIR/snake.py" <<'PY'
import curses, random, time, json, os
STATUS_PATH = os.environ.get("STATUS_JSON", "/tmp/arch_gui_status.json")
def read_status():
    try:
        with open(STATUS_PATH, "r") as f:
            d = json.load(f)
        p = int(max(0, min(100, int(d.get("percent", 0)))))
        s = str(d.get("step", "Installing…"))
        return p, s
    except Exception:
        return 0, "Waiting for installer…"
def draw_progress(win, y, width, pct, step):
    bar_w = max(10, width - 12)
    filled = int(bar_w * (pct/100.0))
    bar = "█"*filled + " "*(bar_w-filled)
    pct_txt = f"{pct:3d}%"
    step_txt = step[:width-2]
    try:
        win.addstr(y,   1, step_txt.ljust(width-2))
        win.addstr(y+1, 1, "["+bar+"] "+pct_txt)
    except curses.error:
        pass
def snake_game(stdscr):
    curses.curs_set(0); stdscr.nodelay(True)
    sh, sw = stdscr.getmaxyx()
    hud_h = 3
    gh = max(5, sh - hud_h); gw = sw
    game = curses.newwin(gh, gw, 0, 0)
    hud  = curses.newwin(hud_h, gw, gh, 0)
    snake=[(gh//2,gw//2+1),(gh//2,gw//2),(gh//2,gw//2-1)]
    d=curses.KEY_RIGHT
    food=(random.randint(1,gh-2),random.randint(1,gw-2))
    score=0; speed=0.07; last=0; pct, step = read_status()
    while True:
        now=time.time()
        if now-last>0.2:
            pct, step = read_status(); last=now
        # HUD
        hud.erase()
        try:
            hud.border(0); hud.addstr(0,2," INSTALL STATUS ")
        except curses.error: pass
        draw_progress(hud,1,gw,pct,step); hud.noutrefresh()
        # Game
        game.erase()
        try:
            game.border(0); game.addstr(0,2,f" SNAKE | Score: {score} ")
            game.addch(food[0], food[1], '*')
        except curses.error: pass
        key=stdscr.getch()
        if key in [curses.KEY_RIGHT,curses.KEY_LEFT,curses.KEY_UP,curses.KEY_DOWN]:
            if (d,key) not in [(curses.KEY_RIGHT,curses.KEY_LEFT),(curses.KEY_LEFT,curses.KEY_RIGHT),(curses.KEY_UP,curses.KEY_DOWN),(curses.KEY_DOWN,curses.KEY_UP)]:
                d=key
        y,x=snake[0]
        if d==curses.KEY_RIGHT:x+=1
        elif d==curses.KEY_LEFT:x-=1
        elif d==curses.KEY_UP:y-=1
        elif d==curses.KEY_DOWN:y+=1
        if x<=0:x=gw-2
        if x>=gw-1:x=1
        if y<=0:y=gh-2
        if y>=gh-1:y=1
        head=(y,x)
        if head in snake:
            score=0; snake=[(gh//2,gw//2+1),(gh//2,gw//2),(gh//2,gw//2-1)]
            d=curses.KEY_RIGHT; food=(random.randint(1,gh-2),random.randint(1,gw-2))
        snake.insert(0,head)
        if head==food:
            score+=1; speed=max(0.03, speed-0.002)
            food=(random.randint(1,gh-2),random.randint(1,gw-2))
        else:
            snake.pop()
        for yy,xx in snake:
            try: game.addch(yy,xx,'#')
            except curses.error: pass
        game.noutrefresh(); curses.doupdate(); time.sleep(speed)
def main():
    try: curses.wrapper(snake_game)
    except Exception: pass
if __name__=="__main__": main()
PY

export TERM=xterm-256color
tmux new-session -d -s archinst "tail -f $LOGFILE" || true
STATUS_JSON="$STATUS_JSON" tmux split-window -h -t archinst "python $TMPDIR/snake.py" || true
tmux select-pane -t archinst:0.0 || true

# --------------- partition, format, mount ---------------
emit_status 5 "Partitioning $DISK"
ROOT_MNT="/mnt"
umount -R "$ROOT_MNT" >/dev/null 2>&1 || true; swapoff -a || true

parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on

next_start=513
if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then
  parted -s "$DISK" mkpart primary linux-swap ${next_start}MiB $((next_start+SWAP_MIB))MiB
  next_start=$((next_start+SWAP_MIB))
fi
parted -s "$DISK" mkpart primary ${FS} ${next_start}MiB 100%

P_EFI=$(devpart "$DISK" 1)
if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then P_SWAP=$(devpart "$DISK" 2); ROOT_IDX=3; else ROOT_IDX=2; fi
P_ROOT=$(devpart "$DISK" "$ROOT_IDX")

emit_status 15 "Formatting filesystems"
mkfs.fat -F32 "$P_EFI"
[[ "${P_SWAP:-}" ]] && mkswap "$P_SWAP" && swapon "$P_SWAP"

# encryption
MAPPER="/dev/mapper/cryptroot"
if [[ "$ENCRYPT" == "yes" ]]; then
  emit_status 20 "Securing root with LUKS (this can take a bit)"
  echo -n "$PASS_ROOT" | cryptsetup luksFormat "$P_ROOT" -q --batch-mode --type luks2 --pbkdf argon2id --iter-time 2000 --key-file=-
  echo -n "$PASS_ROOT" | cryptsetup open "$P_ROOT" cryptroot --key-file=-
  TARGET_DEV="$MAPPER"
else
  TARGET_DEV="$P_ROOT"
fi

case "$FS" in
  ext4) mkfs.ext4 -F "$TARGET_DEV" ;;
  btrfs) mkfs.btrfs -f "$TARGET_DEV" ;;
  xfs) mkfs.xfs -f "$TARGET_DEV" ;;
esac

emit_status 25 "Mounting target"
if [[ "$FS" == "btrfs" ]]; then
  mount "$TARGET_DEV" "$ROOT_MNT"
  btrfs subvolume create "$ROOT_MNT/@"
  btrfs subvolume create "$ROOT_MNT/@home"
  umount -R "$ROOT_MNT"
  mount -o subvol=@ "$TARGET_DEV" "$ROOT_MNT"
  mkdir -p "$ROOT_MNT/home"
  mount -o subvol=@home "$TARGET_DEV" "$ROOT_MNT/home"
else
  mount "$TARGET_DEV" "$ROOT_MNT"
fi
mkdir -p "$ROOT_MNT/boot"
mount "$P_EFI" "$ROOT_MNT/boot"

# --------------- base install ---------------
EXTRA=(networkmanager vim sudo)
CPUVND=$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2);print $2}')
[[ "$CPUVND" == "GenuineIntel" ]] && EXTRA+=(intel-ucode)
[[ "$CPUVND" == "AuthenticAMD" ]] && EXTRA+=(amd-ucode)

case "$PROFILE" in
  xfce)  EXTRA+=(xorg-server lightdm lightdm-gtk-greeter xfce4 xfce4-goodies) ;;
  kde)   EXTRA+=(xorg-server sddm plasma-meta kde-applications-meta) ;;
  gnome) EXTRA+=(xorg-server gnome gdm) ;;
esac

emit_status 30 "Installing base system (pacstrap)…"
install_base(){ pacstrap -K "$ROOT_MNT" base linux linux-firmware "${EXTRA[@]}"; }
if ! retry 3 install_base; then
  warn "pacstrap failed; refreshing mirrors with reflector and retrying…"
  pacman -Sy --noconfirm --needed reflector || true
  safe_run "Refresh mirrors" reflector --country 'Lithuania,Latvia,Estonia,Poland,Germany' --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
  retry 3 install_base || die "pacstrap failed after retries."
fi
emit_status 60 "Base installed"

emit_status 65 "Generating fstab"
genfstab -U "$ROOT_MNT" >> "$ROOT_MNT/etc/fstab"

# --------------- chroot config ---------------
emit_status 70 "Entering chroot for system configuration"

ROOT_UUID=$(blkid -s UUID -o value "$P_ROOT")
export ROOT_UUID

# swapfile only on ext4/xfs (skip on btrfs here)
DO_SWAPFILE=0
if [[ "$SWAP_KIND" == "file" && "$SWAP_MIB" != "0" ]]; then
  if [[ "$FS" == "btrfs" ]]; then
    warn "Swapfile on btrfs skipped (use swap partition instead)."
  else
    DO_SWAPFILE=1
  fi
fi

DM=""
case "$PROFILE" in
  xfce) DM="lightdm" ;;
  kde)  DM="sddm" ;;
  gnome)DM="gdm" ;;
esac

KCL=""
if [[ "$ENCRYPT" == "yes" ]]; then
  LUKS_UUID="$ROOT_UUID"
  KCL="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot"
fi

arch-chroot "$ROOT_MNT" /bin/bash <<CHROOT
set -euo pipefail

echo "==> [70%] Timezone & clock"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc || true

echo "==> [72%] Locale"
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "==> [74%] Hostname & hosts"
echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "==> [76%] Users & sudo"
echo "root:$PASS_ROOT" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASS_USER" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "==> [78%] Enable services"
systemctl enable NetworkManager
if [[ -n "$DM" ]]; then systemctl enable "$DM"; fi

# mkinitcpio hooks for LUKS
if [[ "$ENCRYPT" == "yes" ]]; then
  echo "==> [80%] Rebuilding initramfs with LUKS hooks"
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf || true
  mkinitcpio -P
fi

# Bootloader
echo "==> [85%] Installing bootloader: $BOOTLOADER"
if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  bootctl install
  mkdir -p /boot/loader/entries
  cat >/boot/loader/loader.conf <<EOF2
default arch.conf
timeout 5
console-mode max
editor no
EOF2

  UCODE=""
  if pacman -Q intel-ucode >/dev/null 2>&1; then UCODE="initrd  /intel-ucode.img"; fi
  if pacman -Q amd-ucode   >/dev/null 2>&1; then UCODE="initrd  /amd-ucode.img"; fi

  cat >/boot/loader/entries/arch.conf <<EOF3
title   Arch Linux
linux   /vmlinuz-linux
$UCODE
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
EOF3

else
  pacman -Sy --noconfirm --needed grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="Arch" --recheck
  if [[ "$ENCRYPT" == "yes" ]]; then
    sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="'"$KCL"'"/' /etc/default/grub
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# Swapfile (ext4/xfs only)
if [[ "$DO_SWAPFILE" -eq 1 ]]; then
  echo "==> [90%] Creating swapfile"
  fallocate -l ${SWAP_MIB}M /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi

echo "==> [95%] Chroot configuration complete"
CHROOT


# swapfile only on ext4/xfs (skip on btrfs here)
DO_SWAPFILE=0
if [[ "$SWAP_KIND" == "file" && "$SWAP_MIB" != "0" ]]; then
  if [[ "$FS" == "btrfs" ]]; then
    warn "Swapfile on btrfs skipped (use swap partition instead)."
  else
    DO_SWAPFILE=1
  fi
fi

DM=""
case "$PROFILE" in
  xfce) DM="lightdm" ;;
  kde)  DM="sddm" ;;
  gnome)DM="gdm" ;;
esac

KCL=""
if [[ "$ENCRYPT" == "yes" ]]; then
  # LUKS: cryptdevice=UUID=<luks-uuid>:cryptroot root=/dev/mapper/cryptroot
  LUKS_UUID="$ROOT_UUID"
  KCL="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot"
fi

arch-chroot "$ROOT_MNT" /bin/bash <<CHROOT >>"$LOGFILE" 2>&1
set -euo pipefail

echo "==> Timezone & clock"
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc || true

echo "==> Locale"
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "==> Hostname & hosts"
echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "==> Users & sudo"
echo "root:$PASS_ROOT" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASS_USER" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

# Display manager (if any)
if [[ -n "$DM" ]]; then systemctl enable "$DM"; fi

# mkinitcpio hooks for LUKS
if [[ "$ENCRYPT" == "yes" ]]; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf || true
  mkinitcpio -P
fi

# Bootloader
if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  bootctl install
  mkdir -p /boot/loader/entries
  cat >/boot/loader/loader.conf <<EOF2
default arch.conf
timeout 5
console-mode max
editor no
EOF2

  ROOTUUID="$ROOT_UUID"
  UCODE=""
  if pacman -Q intel-ucode >/dev/null 2>&1; then UCODE="initrd  /intel-ucode.img"; fi
  if pacman -Q amd-ucode   >/dev/null 2>&1; then UCODE="initrd  /amd-ucode.img"; fi

  {
    echo "title   Arch Linux"
    echo "linux   /vmlinuz-linux"
    [[ -n "\$UCODE" ]] && echo "\$UCODE"
    echo "initrd  /initramfs-linux.img"
    if [[ "$ENCRYPT" == "yes" ]]; then
      echo "options $KCL rw"
    else
      echo "options root=UUID=$ROOTUUID rw"
    fi
  } > /boot/loader/entries/arch.conf

else
  pacman -Sy --noconfirm --needed grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="Arch" --recheck
  if [[ "$ENCRYPT" == "yes" ]]; then
    sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="'"$KCL"'"/' /etc/default/grub
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# Swapfile (ext4/xfs only)
if [[ "$DO_SWAPFILE" -eq 1 ]]; then
  fallocate -l ${SWAP_MIB}M /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi
CHROOT

emit_status 85 "Bootloader: $BOOTLOADER configured"

# --------------- finalize ---------------
emit_status 95 "Finalizing, unmounting…"
cp "$LOGFILE" "$ROOT_MNT/var/log/arch-gui-installer.log" 2>/dev/null || true
umount -R "$ROOT_MNT" || true
[[ -n "${P_SWAP:-}" ]] && swapoff "$P_SWAP" || true
[[ "$ENCRYPT" == "yes" ]] && cryptsetup close cryptroot || true

emit_status 100 "Done! You can reboot."

dialog --title "$title" --msgbox "Installation completed.\n\nLogs:\n$LOGFILE (live ISO)\n/mnt/var/log/arch-gui-installer.log (copied to target)\n\nDetach tmux with Ctrl+b then d. Then run: reboot" 14 72 || true
tmux attach -t archinst || true
