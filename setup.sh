#!/usr/bin/env bash
# Arch GUI Installer with Snake HUD + UEFI/BIOS autodetect
# MIT License

set -euo pipefail
VERSION="1.6.0"

# ---------------- helpers ----------------
die(){ echo "[ERROR] $*" >&2; exit 1; }
warn(){ echo "[WARN]  $*" >&2; }
info(){ echo "[INFO]  $*"; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root on the Arch ISO."; }
cmd(){ command -v "$1" >/dev/null 2>&1; }
is_uefi(){ [[ -d /sys/firmware/efi/efivars ]]; }
devpart(){ local d="$1" i="$2"; [[ "$d" =~ (nvme|mmcblk) ]] && echo "${d}p${i}" || echo "${d}${i}"; }
mem_mib(){ awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }
retry(){ local t="${1:-3}"; shift; local n=0; until "$@"; do n=$((n+1)); ((n>=t)) && return 1; sleep $((n*3)); done; }

# ---------------- preflight ----------------
need_root
for p in dialog tmux python parted; do cmd "$p" || pacman -Sy --noconfirm --needed "$p"; done

FIRMWARE="uefi"; is_uefi || FIRMWARE="bios"
TMPDIR="/tmp/arch-gui-installer"; mkdir -p "$TMPDIR"
LOGFILE="$TMPDIR/install.log"; : >"$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

STATUS_JSON="/tmp/arch_gui_status.json"
emit_status(){ local pct="$1"; shift; local msg="$*"; printf '{"percent":%d,"step":"%s"}\n' "$pct" "$(printf %s "$msg" | sed 's/"/\\"/g')" >"$STATUS_JSON"; }

title="Arch GUI Installer v$VERSION ($FIRMWARE)"

# ---------------- dialogs ----------------
mapfile -t DISKS < <(lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1" "$2}')
((${#DISKS[@]})) || die "No disks found."
disk_items=(); for l in "${DISKS[@]}"; do disk_items+=("$(awk '{print $1}'<<<"$l")" "$(awk '{print $2}'<<<"$l")"); done
DISK=$(dialog --stdout --no-tags --title "$title" --menu "Select target disk (ERASES ALL DATA)" 20 70 10 "${disk_items[@]}") || exit 1

FS=$(dialog --stdout --title "$title" --menu "Root filesystem" 12 60 3 ext4 "Reliable" btrfs "Snapshots (@/@home)" xfs "Fast") || exit 1

# Bootloader choice: only when UEFI (BIOS forces GRUB)
if [[ "$FIRMWARE" == "uefi" ]]; then
  BOOTLOADER=$(dialog --stdout --title "$title" --menu "Bootloader (UEFI)" 12 60 2 systemd-boot "Simple" grub "GRUB") || exit 1
else
  BOOTLOADER="grub"
fi

PROFILE=$(dialog --stdout --title "$title" --menu "Install profile" 14 60 4 server "Minimal (no GUI)" xfce "XFCE" kde "KDE Plasma" gnome "GNOME") || exit 1
ENCRYPT=$(dialog --stdout --title "$title" --menu "Encrypt root (LUKS)?" 10 60 2 no "No" yes "Yes") || exit 1

RAM_MIB=$(mem_mib); SUG_SWAP=$((RAM_MIB<8192 ? RAM_MIB : 8192))
SWAP_KIND=$(dialog --stdout --title "$title" --menu "Swap type" 12 60 3 none "No swap" partition "Swap partition" file "Swapfile") || exit 1
SWAP_MIB=0
if [[ "$SWAP_KIND" != "none" ]]; then
  SWAP_MIB=$(dialog --stdout --title "$title" --inputbox "Swap size (MiB)" 8 60 "$SUG_SWAP") || exit 1
  [[ "$SWAP_MIB" =~ ^[0-9]+$ ]] || die "Swap size must be a number."
fi

BEST_EFFORT=$(dialog --stdout --title "$title" --menu "On non-critical failures" 10 60 2 0 "Stop (safer)" 1 "Best-Effort: continue") || exit 1
HOSTNAME=$(dialog --stdout --title "$title" --inputbox "Hostname" 8 60 "archbox") || exit 1
USERNAME=$(dialog --stdout --title "$title" --inputbox "New user" 8 60 "arch") || exit 1
TIMEZONE=$(dialog --stdout --title "$title" --inputbox "Timezone" 8 60 "Europe/Vilnius") || exit 1

PASS_ROOT=$(dialog --stdout --insecure --title "$title" --passwordbox "Root password" 8 60) || exit 1
PASS_ROOT2=$(dialog --stdout --insecure --title "$title" --passwordbox "Repeat root password" 8 60) || exit 1
[[ "$PASS_ROOT" == "$PASS_ROOT2" ]] || die "Root passwords do not match."
PASS_USER=$(dialog --stdout --insecure --title "$title" --passwordbox "Password for $USERNAME" 8 60) || exit 1
PASS_USER2=$(dialog --stdout --insecure --title "$title" --passwordbox "Repeat password for $USERNAME" 8 60) || exit 1
[[ "$PASS_USER" == "$PASS_USER2" ]] || die "User passwords do not match."

dialog --title "$title" --yes-label "I UNDERSTAND" --no-label "Cancel" --yesno \
"THIS WILL ERASE $DISK\nFirmware: $FIRMWARE\nFS: $FS\nBootloader: $BOOTLOADER\nDesktop: $PROFILE\nEncrypt: $ENCRYPT\nSwap: $SWAP_KIND ${SWAP_MIB}MiB\nHostname: $HOSTNAME / User: $USERNAME\n\nProceed?" 18 70 || exit 1

# ---------------- Snake HUD (start IMMEDIATELY) ----------------
emit_status 1 "Launching Snake & logs…"

cat > "$TMPDIR/snake.py" <<'PY'
import curses, time, json, os, random
STATUS=os.environ.get("STATUS_JSON","/tmp/arch_gui_status.json")
def read_status():
    try:
        with open(STATUS) as f: d=json.load(f)
        p=max(0,min(100,int(d.get("percent",0)))); s=str(d.get("step","…")); return p,s
    except: return 0,"…"
def main(stdscr):
    curses.curs_set(0); stdscr.nodelay(True)
    sh,sw=stdscr.getmaxyx(); gh=max(5,sh-3)
    snake=[(gh//2,sw//2+1),(gh//2,sw//2),(gh//2,sw//2-1)]
    d=curses.KEY_RIGHT; food=(random.randint(1,gh-2),random.randint(1,sw-2))
    score=0; sp=0.07; last=0; p,s=read_status()
    while True:
        if time.time()-last>0.2: p,s=read_status(); last=time.time()
        hud=stdscr.subwin(3,sw,gh,0); hud.border()
        txt=f"{p:3d}% {s}"[:sw-4]; hud.addstr(1,2,txt)
        game=stdscr.subwin(gh,sw,0,0); game.border(); game.addstr(0,2,f"SNAKE {score}")
        game.addch(food[0],food[1],'*')
        key=stdscr.getch()
        if key in [curses.KEY_RIGHT,curses.KEY_LEFT,curses.KEY_UP,curses.KEY_DOWN]:
            if (d,key) not in [(curses.KEY_RIGHT,curses.KEY_LEFT),(curses.KEY_LEFT,curses.KEY_RIGHT),(curses.KEY_UP,curses.KEY_DOWN),(curses.KEY_DOWN,curses.KEY_UP)]: d=key
        y,x=snake[0]; y+= (d==curses.KEY_DOWN)-(d==curses.KEY_UP); x+= (d==curses.KEY_RIGHT)-(d==curses.KEY_LEFT)
        if x<=0:x=sw-2
        if x>=sw-1:x=1
        if y<=0:y=gh-2
        if y>=gh-1:y=1
        head=(y,x)
        if head in snake:
            score=0; snake=[(gh//2,sw//2+1),(gh//2,sw//2),(gh//2,sw//2-1)]; d=curses.KEY_RIGHT
        snake.insert(0,head)
        if head==food:
            score+=1; sp=max(0.03,sp-0.002); food=(random.randint(1,gh-2),random.randint(1,sw-2))
        else: snake.pop()
        for yy,xx in snake:
            try: game.addch(yy,xx,'#')
            except: pass
        game.refresh(); hud.refresh(); time.sleep(sp)
if __name__=="__main__":
    try: curses.wrapper(main)
    except: pass
PY

export TERM=xterm-256color
tmux new-session -d -s archinst "tail -f $LOGFILE"
STATUS_JSON="$STATUS_JSON" tmux split-window -h -t archinst "python $TMPDIR/snake.py"
tmux select-pane -t archinst:0.0

# ---------------- main install runs IN BACKGROUND ----------------
BEST_EFFORT="${BEST_EFFORT}"

install_main() {
  set -euo pipefail
  emit_status 5 "Partitioning $DISK ($FIRMWARE)"
  umount -R /mnt 2>/dev/null || true; swapoff -a || true

  if [[ "$FIRMWARE" == "uefi" ]]; then
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
    parted -s "$DISK" set 1 esp on
    next=513
  else
    parted -s "$DISK" mklabel gpt
    parted -s "$DISK" mkpart BIOSBOOT 1MiB 3MiB
    parted -s "$DISK" set 1 bios_grub on
    next=3
  fi

  if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then
    parted -s "$DISK" mkpart primary linux-swap ${next}MiB $((next+SWAP_MIB))MiB
    next=$((next+SWAP_MIB))
  fi
  parted -s "$DISK" mkpart primary $FS ${next}MiB 100%

  if [[ "$FIRMWARE" == "uefi" ]]; then
    P_EFI=$(devpart "$DISK" 1)
    if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then P_SWAP=$(devpart "$DISK" 2); ROOT_IDX=3; else ROOT_IDX=2; fi
  else
    P_EFI=""  # none on BIOS
    if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then ROOT_IDX=3; P_SWAP=$(devpart "$DISK" 2); else ROOT_IDX=2; fi
  fi
  P_ROOT=$(devpart "$DISK" "$ROOT_IDX")

  emit_status 12 "Formatting"
  [[ -n "${P_EFI:-}" ]] && mkfs.fat -F32 "$P_EFI"
  [[ -n "${P_SWAP:-}" ]] && mkswap "$P_SWAP" && swapon "$P_SWAP"

  if [[ "$ENCRYPT" == "yes" ]]; then
    emit_status 15 "Encrypting root (LUKS)…"
    echo -n "$PASS_ROOT" | cryptsetup luksFormat "$P_ROOT" -q --batch-mode --type luks2 --key-file=-
    echo -n "$PASS_ROOT" | cryptsetup open "$P_ROOT" cryptroot --key-file=-
    ROOT_DEV=/dev/mapper/cryptroot
  else
    ROOT_DEV="$P_ROOT"
  fi

  case "$FS" in
    ext4) mkfs.ext4 -F "$ROOT_DEV" ;;
    btrfs) mkfs.btrfs -f "$ROOT_DEV" ;;
    xfs) mkfs.xfs -f "$ROOT_DEV" ;;
  esac

  emit_status 20 "Mounting target"
  if [[ "$FS" == "btrfs" ]]; then
    mount "$ROOT_DEV" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount -R /mnt
    mount -o subvol=@ "$ROOT_DEV" /mnt
    mkdir -p /mnt/home
    mount -o subvol=@home "$ROOT_DEV" /mnt/home
  else
    mount "$ROOT_DEV" /mnt
  fi
  if [[ -n "${P_EFI:-}" ]]; then mkdir -p /mnt/boot; mount "$P_EFI" /mnt/boot; fi

  emit_status 30 "Installing base system…"
  EXTRA=(networkmanager vim sudo)
  CPUV=$(lscpu | awk -F: '/Vendor ID/{print $2}' | xargs)
  [[ "$CPUV" == "GenuineIntel" ]]   && EXTRA+=(intel-ucode)
  [[ "$CPUV" == "AuthenticAMD" ]]   && EXTRA+=(amd-ucode)
  case "$PROFILE" in
    xfce)  EXTRA+=(xorg-server lightdm lightdm-gtk-greeter xfce4 xfce4-goodies) ;;
    kde)   EXTRA+=(xorg-server sddm plasma-meta kde-applications-meta) ;;
    gnome) EXTRA+=(xorg-server gnome gdm) ;;
  esac

  install_base(){ pacstrap -K /mnt base linux linux-firmware "${EXTRA[@]}"; }
  if ! retry 3 install_base; then
    warn "pacstrap failed; trying mirror refresh…"
    pacman -Sy --noconfirm --needed reflector || true
    reflector --country 'Lithuania,Latvia,Estonia,Poland,Germany' --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true
    retry 2 install_base
  fi

  emit_status 55 "Generating fstab"
  genfstab -U /mnt >> /mnt/etc/fstab

  # ---- chroot config ----
  emit_status 60 "Entering chroot…"
  ROOT_UUID=$(blkid -s UUID -o value "$P_ROOT")

  # Export all needed vars into chroot env
  export HOSTNAME USERNAME PASS_USER PASS_ROOT TIMEZONE PROFILE ENCRYPT BOOTLOADER FS FIRMWARE DISK SWAP_MIB ROOT_UUID
  export P_EFI P_ROOT

  arch-chroot /mnt /bin/bash -euo pipefail <<'CHROOT'
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

echo "==> Enable services"
systemctl enable NetworkManager
if [[ "$PROFILE" == "xfce" ]]; then systemctl enable lightdm; fi
if [[ "$PROFILE" == "kde"  ]]; then systemctl enable sddm;   fi
if [[ "$PROFILE" == "gnome"]]; then systemctl enable gdm;    fi

if [[ "$ENCRYPT" == "yes" ]]; then
  echo "==> mkinitcpio with LUKS"
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf || true
  mkinitcpio -P
fi

echo "==> Bootloader: $BOOTLOADER ($FIRMWARE)"
if [[ "$FIRMWARE" == "uefi" && "$BOOTLOADER" == "systemd-boot" ]]; then
  bootctl install
  mkdir -p /boot/loader/entries
  cat >/boot/loader/loader.conf <<EOF
default arch.conf
timeout 5
console-mode max
editor no
EOF
  UCODE=""
  if pacman -Q intel-ucode >/dev/null 2>&1; then UCODE="initrd  /intel-ucode.img"; fi
  if pacman -Q amd-ucode   >/dev/null 2>&1; then UCODE="initrd  /amd-ucode.img"; fi
  cat >/boot/loader/entries/arch.conf <<EOF
title   Arch Linux
linux   /vmlinuz-linux
$UCODE
initrd  /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
EOF

else
  pacman -Sy --noconfirm --needed grub efibootmgr
  if [[ "$FIRMWARE" == "uefi" ]]; then
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id="Arch" --recheck
  else
    # BIOS install (MBR/BIOS). On GPT we created bios_grub earlier.
    grub-install --target=i386-pc "$DISK" --recheck
  fi
  grub-mkconfig -o /boot/grub/grub.cfg
fi

# Optional swapfile (safe on ext4/xfs; skipped on btrfs)
if [[ "$FS" != "btrfs" && "$SWAP_MIB" -gt 0 ]]; then
  echo "==> Creating swapfile (${SWAP_MIB}M)"
  fallocate -l ${SWAP_MIB}M /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo "/swapfile none swap defaults 0 0" >> /etc/fstab
fi
CHROOT

  emit_status 95 "Finalizing…"
  cp "$LOGFILE" /mnt/var/log/arch-gui-installer.log 2>/dev/null || true
  umount -R /mnt || true
  [[ -n "${P_SWAP:-}" ]] && swapoff "$P_SWAP" || true
  [[ "$ENCRYPT" == "yes" ]] && cryptsetup close cryptroot || true

  emit_status 100 "Done! You can reboot."
}

# Launch installer in the background so we can ATTACH tmux now
install_main & disown

# Drop the user straight into Snake+logs
exec tmux attach -t archinst
