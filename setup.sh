#!/usr/bin/env bash
# arch-gui-installer.sh
# Automated Arch Linux installer with dialog "GUI", GRUB/systemd-boot choice,
# optional LUKS, swap partition or swapfile, desktop choices, and a Snake game.
# MIT License

set -euo pipefail

VERSION="1.3.0"

# ---------- helpers ----------
die(){ echo "[ERROR] $*" >&2; exit 1; }
warn(){ echo "[WARN]  $*" >&2; }
info(){ echo "[INFO]  $*"; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root."; }
cmd(){ command -v "$1" >/dev/null 2>&1; }

is_uefi(){ [[ -d /sys/firmware/efi/efivars ]]; }

devpart(){ local d="$1" i="$2"; [[ "$d" =~ (nvme|mmcblk) ]] && echo "${d}p${i}" || echo "${d}${i}"; }
mem_mib(){ awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }

retry(){
  local tries="${1:-3}"; shift
  local n=0
  until "$@"; do
    n=$((n+1))
    (( n>=tries )) && return 1
    sleep $((n*3))
  done
}

safe_run(){ # safe_run "desc" cmd...
  local desc="$1"; shift
  if ! "$@" >>"$LOGFILE" 2>&1; then
    warn "$desc failed."
    [[ "$BEST_EFFORT" == "1" ]] || die "$desc failed (Best-Effort OFF)."
  fi
}

# ---------- preflight ----------
need_root
info "Arch GUI Installer v$VERSION"

if ! is_uefi; then
  die "This script targets UEFI systems. (GRUB in legacy BIOS could be added later.)"
fi

# minimal net check
if ! ping -c1 -W2 archlinux.org >/dev/null 2>&1; then
  warn "No internet detected. Connect first (e.g., 'iwctl'). The install will likely fail otherwise."
fi

for p in dialog tmux python parted; do
  cmd "$p" || pacman -Sy --noconfirm --needed "$p"
done

TMPDIR="/tmp/arch-gui-installer"
mkdir -p "$TMPDIR"
LOGFILE="$TMPDIR/install.log"
: > "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

title="Arch GUI Installer"

# ---------- gather inputs ----------
mapfile -t DISKS < <(lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1" "$2}')
((${#DISKS[@]})) || die "No disks found."
disk_items=(); for l in "${DISKS[@]}"; do disk_items+=("$(awk '{print $1}'<<<"$l")" "$(awk '{print $2}'<<<"$l")"); done
DISK=$(dialog --clear --stdout --no-tags --title "$title" --menu "Select target disk (ERASES ALL DATA)" 20 70 10 "${disk_items[@]}") || exit 1

FS=$(dialog --clear --stdout --title "$title" --menu "Root filesystem" 12 60 4 \
  ext4 "Simple & reliable" \
  btrfs "Snapshots (basic subvols @,@home)" \
  xfs "Fast (no shrink)") || exit 1

BOOTLOADER=$(dialog --clear --stdout --title "$title" --menu "Bootloader" 12 60 2 \
  "systemd-boot" "Simple UEFI boot manager" \
  "grub"         "GRUB (widely compatible)") || exit 1

# Desktop profile
PROFILE=$(dialog --clear --stdout --title "$title" --menu "Install profile" 14 60 4 \
  "server" "Minimal (no GUI)" \
  "xfce"   "Light XFCE" \
  "kde"    "KDE Plasma" \
  "gnome"  "GNOME") || exit 1

# Encryption
ENCRYPT=$(dialog --clear --stdout --title "$title" --menu "Encrypt root (LUKS)?" 10 60 2 \
  "no"  "No encryption" \
  "yes" "Encrypt root with LUKS") || exit 1

# Swap choice
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

# ---------- tmux + snake (non-fatal) ----------
SNAKE_PY="$TMPDIR/snake.py"
cat > "$SNAKE_PY" <<'PY'
import curses, random, time
def main(stdscr):
    curses.curs_set(0); stdscr.nodelay(True)
    sh,sw=stdscr.getmaxyx(); w=curses.newwin(sh,sw,0,0); w.border(0)
    snake=[(sh//2,sw//2+1),(sh//2,sw//2),(sh//2,sw//2-1)]; d=curses.KEY_RIGHT
    food=(random.randint(1,sh-2),random.randint(1,sw-2)); score=0; sp=0.07
    while True:
        w.addstr(0,2,f" SNAKE | Score:{score} "); w.addch(food[0],food[1],'*')
        k=stdscr.getch()
        if k in [curses.KEY_RIGHT,curses.KEY_LEFT,curses.KEY_UP,curses.KEY_DOWN] and (d,k) not in [(curses.KEY_RIGHT,curses.KEY_LEFT),(curses.KEY_LEFT,curses.KEY_RIGHT),(curses.KEY_UP,curses.KEY_DOWN),(curses.KEY_DOWN,curses.KEY_UP)]: d=k
        y,x=snake[0]; x+= (d==curses.KEY_RIGHT)-(d==curses.KEY_LEFT); y+= (d==curses.KEY_DOWN)-(d==curses.KEY_UP)
        if x<=0:x=sw-2
        if x>=sw-1:x=1
        if y<=0:y=sh-2
        if y>=sh-1:y=1
        nh=(y,x)
        if nh in snake: score=0; snake=[(sh//2,sw//2+1),(sh//2,sw//2),(sh//2,sw//2-1)]; d=curses.KEY_RIGHT; food=(random.randint(1,sh-2),random.randint(1,sw-2)); w.clear(); w.border(0)
        snake.insert(0,nh)
        if nh==food: score+=1; sp=max(0.03,sp-0.002); food=(random.randint(1,sh-2),random.randint(1,sw-2))
        else: snake.pop()
        w.clear(); w.border(0)
        for yy,xx in snake:
            try: w.addch(yy,xx,'#')
            except: pass
        w.refresh(); time.sleep(sp)
if __name__=="__main__":
    try: curses.wrapper(main)
    except: pass
PY

# Start tmux; if python/curses fails, it's OK.
tmux new-session -d -s archinst "tail -f $LOGFILE" || true
tmux split-window -h -t archinst "python $SNAKE_PY" || true
tmux select-pane -t archinst:0.0 || true

# ---------- partition, format, mount ----------
ROOT_MNT="/mnt"
umount -R "$ROOT_MNT" >/dev/null 2>&1 || true; swapoff -a || true

info "Partitioning $DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on

# layout: [ESP][optional swap][root]
next_start=513
if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then
  parted -s "$DISK" mkpart primary linux-swap ${next_start}MiB $((next_start+SWAP_MIB))MiB
  next_start=$((next_start+SWAP_MIB))
fi
parted -s "$DISK" mkpart primary ${FS} ${next_start}MiB 100%

P_EFI=$(devpart "$DISK" 1)
if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then P_SWAP=$(devpart "$DISK" 2); ROOT_IDX=3; else ROOT_IDX=2; fi
P_ROOT=$(devpart "$DISK" "$ROOT_IDX")

info "Formatting"
mkfs.fat -F32 "$P_EFI"
[[ "${P_SWAP:-}" ]] && mkswap "$P_SWAP" && swapon "$P_SWAP"

# encryption & mkfs
MAPPER="/dev/mapper/cryptroot"
if [[ "$ENCRYPT" == "yes" ]]; then
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

# mount (with basic btrfs subvols)
mount_opts="defaults"
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

# ---------- base install with retries & mirror refresh ----------
EXTRA=(networkmanager vim sudo)
CPUVND=$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2);print $2}')
[[ "$CPUVND" == "GenuineIntel" ]] && EXTRA+=(intel-ucode)
[[ "$CPUVND" == "AuthenticAMD" ]] && EXTRA+=(amd-ucode)

case "$PROFILE" in
  xfce)  EXTRA+=(xorg-server lightdm lightdm-gtk-greeter xfce4 xfce4-goodies) ;;
  kde)   EXTRA+=(xorg-server sddm plasma-meta kde-applications-meta) ;;
  gnome) EXTRA+=(xorg-server gnome gdm) ;;
esac

install_base(){
  pacstrap -K "$ROOT_MNT" base linux linux-firmware "${EXTRA[@]}"
}
if ! retry 3 install_base; then
  warn "pacstrap failed; refreshing mirrors with reflector and retrying…"
  pacman -Sy --noconfirm --needed reflector || true
  safe_run "Refresh mirrors" reflector --country 'Lithuania,Latvia,Estonia,Poland,Germany' --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
  retry 3 install_base || die "pacstrap failed after retries."
fi

genfstab -U "$ROOT_MNT" >> "$ROOT_MNT/etc/fstab"

# ---------- chroot configuration ----------
ROOT_UUID=$(blkid -s UUID -o value "$P_ROOT")
LUKS_UUID="$ROOT_UUID"
if [[ "$ENCRYPT" == "yes" ]]; then
  LUKS_UUID=$(blkid -s UUID -o value "$P_ROOT")
fi

# Prepare swapfile creation (only for ext4/xfs; btrfs swapfile is unsafe by default)
DO_SWAPFILE=0
if [[ "$SWAP_KIND" == "file" && "$SWAP_MIB" != "0" ]]; then
  if [[ "$FS" == "btrfs" ]]; then
    warn "Swapfile on btrfs skipped (not set up here). Use swap partition instead."
  else
    DO_SWAPFILE=1
  fi
fi

# services & display managers
DM=""
case "$PROFILE" in
  xfce) DM="lightdm" ;;
  kde)  DM="sddm" ;;
  gnome)DM="gdm" ;;
esac

# kernel cmdline for encryption
KCL=""
if [[ "$ENCRYPT" == "yes" ]]; then
  KCL="cryptdevice=UUID=$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot"
fi

arch-chroot "$ROOT_MNT" /bin/bash <<CHROOT >>"$LOGFILE" 2>&1
set -euo pipefail

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc || true

sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

echo "root:$PASS_ROOT" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASS_USER" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

systemctl enable NetworkManager

if [[ "$DM" != "" ]]; then systemctl enable "\$DM"; fi

# mkinitcpio: ensure encrypt hook if LUKS
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
  UCODE_LINE=""
  if pacman -Q intel-ucode >/dev/null 2>&1; then UCODE_LINE="initrd  /intel-ucode.img"; fi
  if pacman -Q amd-ucode   >/dev/null 2>&1; then UCODE_LINE="initrd  /amd-ucode.img"; fi

  if [[ "$ENCRYPT" == "yes" ]]; then
    cat >/boot/loader/entries/arch.conf <<EOF3
title   Arch Linux
linux   /vmlinuz-linux
\$UCODE_LINE
initrd  /initramfs-linux.img
options $KCL rw
EOF3
  else
    ROOTUUID=\$(blkid -s UUID -o value "$TARGET_DEV")
    cat >/boot/loader/entries/arch.conf <<EOF4
title   Arch Linux
linux   /vmlinuz-linux
\$UCODE_LINE
initrd  /initramfs-linux.img
options root=UUID=\$ROOTUUID rw
EOF4
  fi

else
  pacman -Sy --noconfirm --needed grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="Arch" --recheck
  if [[ "$ENCRYPT" == "yes" ]]; then
    sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="'"$KCL"'"/' /etc/default/grub
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# Optional swapfile (ext4/xfs)
if [[ "$DO_SWAPFILE" -eq 1 ]]; then
  fallocate -l ${SWAP_MIB}M /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi
CHROOT

# ---------- wrap up ----------
info "Finalizing"
umount -R "$ROOT_MNT" || true
[[ -n "${P_SWAP:-}" ]] && swapoff "$P_SWAP" || true
[[ "$ENCRYPT" == "yes" ]] && cryptsetup close cryptroot || true

dialog --title "$title" --msgbox "Installation completed (Best-Effort=${BEST_EFFORT}).\n\nLog: $LOGFILE\n\nDetach tmux with Ctrl+b, d. Then run: reboot" 12 70 || true
tmux attach -t archinst || true
