#!/usr/bin/env bash
# Arch GUI Installer with Snake HUD progress
# Supports: ext4/btrfs/xfs, GRUB or systemd-boot, swap (file/partition), LUKS
# MIT License

set -euo pipefail
VERSION="1.5.0"

die(){ echo "[ERROR] $*" >&2; exit 1; }
warn(){ echo "[WARN]  $*" >&2; }
info(){ echo "[INFO]  $*"; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root (root shell on Arch ISO)."; }
cmd(){ command -v "$1" >/dev/null 2>&1; }
is_uefi(){ [[ -d /sys/firmware/efi/efivars ]]; }
devpart(){ local d="$1" i="$2"; [[ "$d" =~ (nvme|mmcblk) ]] && echo "${d}p${i}" || echo "${d}${i}"; }
mem_mib(){ awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }

retry(){ local t="${1:-3}"; shift; local n=0; until "$@"; do n=$((n+1)); (( n>=t )) && return 1; sleep $((n*3)); done; }

# ---------- preflight ----------
need_root
info "Arch GUI Installer v$VERSION"
is_uefi || die "This script requires UEFI mode."

for p in dialog tmux python parted; do
  cmd "$p" || pacman -Sy --noconfirm --needed "$p"
done

TMPDIR="/tmp/arch-gui-installer"
mkdir -p "$TMPDIR"
LOGFILE="$TMPDIR/install.log"
STATUS_JSON="/tmp/arch_gui_status.json"
: > "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

emit_status(){ local pct="$1"; shift; local msg="$*"; echo "{\"percent\":$pct,\"step\":\"$msg\"}" > "$STATUS_JSON"; }
emit_status 0 "Starting installer…"

title="Arch GUI Installer"

# ---------- dialog inputs ----------
mapfile -t DISKS < <(lsblk -dno NAME,SIZE,TYPE | awk '$3=="disk"{print "/dev/"$1" "$2}')
((${#DISKS[@]})) || die "No disks found."
disk_items=(); for l in "${DISKS[@]}"; do disk_items+=("$(awk '{print $1}'<<<"$l")" "$(awk '{print $2}'<<<"$l")"); done
DISK=$(dialog --stdout --no-tags --title "$title" --menu "Select disk (ERASES ALL)" 20 70 10 "${disk_items[@]}") || exit 1

FS=$(dialog --stdout --title "$title" --menu "Filesystem" 12 50 3 ext4 "Reliable" btrfs "Snapshots" xfs "Fast") || exit 1
BOOTLOADER=$(dialog --stdout --title "$title" --menu "Bootloader" 12 50 2 systemd-boot "Simple" grub "Compatible") || exit 1
PROFILE=$(dialog --stdout --title "$title" --menu "Profile" 14 60 4 server "No GUI" xfce "XFCE" kde "Plasma" gnome "GNOME") || exit 1
ENCRYPT=$(dialog --stdout --title "$title" --menu "Encrypt root?" 10 40 2 no "No" yes "Yes (LUKS)") || exit 1

RAM_MIB=$(mem_mib); SUG_SWAP=$(( RAM_MIB < 8192 ? RAM_MIB : 8192 ))
SWAP_KIND=$(dialog --stdout --title "$title" --menu "Swap type" 12 60 3 none "No" partition "Partition" file "Swapfile") || exit 1
SWAP_MIB=0
if [[ "$SWAP_KIND" != "none" ]]; then
  SWAP_MIB=$(dialog --stdout --title "$title" --inputbox "Swap size (MiB)" 8 60 "$SUG_SWAP") || exit 1
fi

BEST_EFFORT=$(dialog --stdout --title "$title" --menu "Error handling" 10 60 2 0 "Stop on error" 1 "Best-Effort: skip") || exit 1
HOSTNAME=$(dialog --stdout --title "$title" --inputbox "Hostname" 8 60 "archbox") || exit 1
USERNAME=$(dialog --stdout --title "$title" --inputbox "Username" 8 60 "arch") || exit 1
TIMEZONE=$(dialog --stdout --title "$title" --inputbox "Timezone" 8 60 "Europe/Vilnius") || exit 1

PASS_ROOT=$(dialog --stdout --insecure --title "$title" --passwordbox "Root password" 8 60) || exit 1
PASS_ROOT2=$(dialog --stdout --insecure --title "$title" --passwordbox "Repeat root password" 8 60) || exit 1
[[ "$PASS_ROOT" == "$PASS_ROOT2" ]] || die "Root passwords mismatch."
PASS_USER=$(dialog --stdout --insecure --title "$title" --passwordbox "Password for $USERNAME" 8 60) || exit 1
PASS_USER2=$(dialog --stdout --insecure --title "$title" --passwordbox "Repeat password for $USERNAME" 8 60) || exit 1
[[ "$PASS_USER" == "$PASS_USER2" ]] || die "User passwords mismatch."

# ---------- Snake HUD ----------
cat > "$TMPDIR/snake.py" <<'PY'
import curses, random, time, json, os
STATUS_PATH=os.environ.get("STATUS_JSON","/tmp/arch_gui_status.json")
def read_status():
    try:
        with open(STATUS_PATH) as f: d=json.load(f)
        return int(d.get("percent",0)), str(d.get("step","…"))
    except: return 0,"…"
def snake(stdscr):
    curses.curs_set(0); stdscr.nodelay(True)
    sh,sw=stdscr.getmaxyx(); gh=sh-3
    snake=[(gh//2,sw//2+1),(gh//2,sw//2),(gh//2,sw//2-1)]
    d=curses.KEY_RIGHT; food=(gh//2,sw//2+5); score=0; sp=0.07
    pct,step=read_status(); last=0
    while True:
        if time.time()-last>0.2: pct,step=read_status(); last=time.time()
        hud=stdscr.subwin(3,sw,gh,0); hud.border()
        hud.addstr(1,2,f"{pct}% {step}"[:sw-4])
        game=stdscr.subwin(gh,sw,0,0); game.border(); game.addstr(0,2,f"SNAKE {score}")
        game.addch(food[0],food[1],'*')
        key=stdscr.getch()
        if key in [curses.KEY_RIGHT,curses.KEY_LEFT,curses.KEY_UP,curses.KEY_DOWN]:
            if (d,key) not in [(curses.KEY_RIGHT,curses.KEY_LEFT),(curses.KEY_LEFT,curses.KEY_RIGHT),(curses.KEY_UP,curses.KEY_DOWN),(curses.KEY_DOWN,curses.KEY_UP)]: d=key
        y,x=snake[0]; y+= (d==curses.KEY_DOWN)-(d==curses.KEY_UP); x+= (d==curses.KEY_RIGHT)-(d==curses.KEY_LEFT)
        if x<=0:x=sw-2; 
        if x>=sw-1:x=1
        if y<=0:y=gh-2
        if y>=gh-1:y=1
        head=(y,x); 
        if head in snake: score=0; snake=[(gh//2,sw//2+1),(gh//2,sw//2),(gh//2,sw//2-1)]; d=curses.KEY_RIGHT
        snake.insert(0,head)
        if head==food: score+=1; sp=max(0.03,sp-0.002); food=(random.randint(1,gh-2),random.randint(1,sw-2))
        else: snake.pop()
        for yy,xx in snake:
            try: game.addch(yy,xx,'#')
            except: pass
        game.refresh(); hud.refresh(); time.sleep(sp)
curses.wrapper(snake)
PY

export TERM=xterm-256color
tmux new-session -d -s archinst "tail -f $LOGFILE"
STATUS_JSON="$STATUS_JSON" tmux split-window -h -t archinst "python $TMPDIR/snake.py"
tmux select-pane -t archinst:0.0

# ---------- partition & mount ----------
emit_status 5 "Partitioning $DISK"
umount -R /mnt 2>/dev/null || true; swapoff -a || true
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
next=513
if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then
  parted -s "$DISK" mkpart primary linux-swap ${next}MiB $((next+SWAP_MIB))MiB
  next=$((next+SWAP_MIB))
fi
parted -s "$DISK" mkpart primary $FS ${next}MiB 100%
P_EFI=$(devpart "$DISK" 1)
if [[ "$SWAP_KIND" == "partition" && "$SWAP_MIB" != "0" ]]; then P_SWAP=$(devpart "$DISK" 2); ROOT_IDX=3; else ROOT_IDX=2; fi
P_ROOT=$(devpart "$DISK" "$ROOT_IDX")
mkfs.fat -F32 "$P_EFI"
[[ "${P_SWAP:-}" ]] && mkswap "$P_SWAP" && swapon "$P_SWAP"

if [[ "$ENCRYPT" == "yes" ]]; then
  emit_status 10 "Encrypting root"
  echo -n "$PASS_ROOT" | cryptsetup luksFormat "$P_ROOT" -q --batch-mode --type luks2 --key-file=-
  echo -n "$PASS_ROOT" | cryptsetup open "$P_ROOT" cryptroot --key-file=-
  ROOT_DEV=/dev/mapper/cryptroot
else ROOT_DEV="$P_ROOT"; fi

case "$FS" in
  ext4) mkfs.ext4 -F "$ROOT_DEV";;
  btrfs) mkfs.btrfs -f "$ROOT_DEV";;
  xfs) mkfs.xfs -f "$ROOT_DEV";;
esac

emit_status 20 "Mounting filesystems"
mount "$ROOT_DEV" /mnt
mkdir -p /mnt/boot
mount "$P_EFI" /mnt/boot

# ---------- base install ----------
EXTRA=(networkmanager vim sudo)
CPUV=$(lscpu | awk -F: '/Vendor ID/{print $2}' | xargs)
[[ "$CPUV" == "GenuineIntel" ]] && EXTRA+=(intel-ucode)
[[ "$CPUV" == "AuthenticAMD" ]] && EXTRA+=(amd-ucode)
case "$PROFILE" in
  xfce) EXTRA+=(xorg-server lightdm lightdm-gtk-greeter xfce4) ;;
  kde) EXTRA+=(xorg-server sddm plasma-meta) ;;
  gnome) EXTRA+=(xorg-server gnome gdm) ;;
esac

emit_status 30 "Installing base system"
retry 3 pacstrap -K /mnt base linux linux-firmware "${EXTRA[@]}"
genfstab -U /mnt >> /mnt/etc/fstab

# ---------- chroot config ----------
ROOT_UUID=$(blkid -s UUID -o value "$P_ROOT")
export ROOT_UUID
emit_status 60 "Entering chroot…"

arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail
echo "==> Timezone"
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc || true
echo "==> Locale"
sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo LANG=en_US.UTF-8 > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
EOF
echo "root:$PASS_ROOT" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASS_USER" | chpasswd
sed -i 's/^# %wheel/%wheel/' /etc/sudoers
systemctl enable NetworkManager
[[ "$PROFILE" == "xfce" ]] && systemctl enable lightdm
[[ "$PROFILE" == "kde" ]] && systemctl enable sddm
[[ "$PROFILE" == "gnome" ]] && systemctl enable gdm

if [[ "$ENCRYPT" == "yes" ]]; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
  mkinitcpio -P
fi

if [[ "$BOOTLOADER" == "systemd-boot" ]]; then
  bootctl install
  mkdir -p /boot/loader/entries
  cat >/boot/loader/loader.conf <<EOF
default arch.conf
timeout 5
EOF
  cat >/boot/loader/entries/arch.conf <<EOF
title Arch Linux
linux /vmlinuz-linux
initrd /initramfs-linux.img
options root=UUID=$ROOT_UUID rw
EOF
else
  pacman -Sy --noconfirm grub efibootmgr
  grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=Arch
  grub-mkconfig -o /boot/grub/grub.cfg
fi
CHROOT

# ---------- finish ----------
emit_status 100 "Done! Reboot now"
umount -R /mnt || true
[[ -n "${P_SWAP:-}" ]] && swapoff "$P_SWAP" || true
[[ "$ENCRYPT" == "yes" ]] && cryptsetup close cryptroot || true
tmux attach -t archinst
