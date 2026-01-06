#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
trap 'echo "ERROR on line $LINENO"; exit 1' ERR

HOSTNAME="${HOSTNAME:-harchlaptop}"
USERNAME="${USERNAME:-hsuazo}"
TIMEZONE="${TIMEZONE:-America/Santo_Domingo}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"

DISK="${DISK:-}"

EFI_SIZE_MB="${EFI_SIZE_MB:-1024}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-8}"

die() { echo "ERROR: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

get_part() {
  local idx="$1"
  if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
    echo "${DISK}p${idx}"
  else
    echo "${DISK}${idx}"
  fi
}

prompt_secret() {
  local varname="$1" prompt="$2"
  local v1 v2
  while true; do
    read -r -s -p "$prompt: " v1; echo
    read -r -s -p "Confirm $prompt: " v2; echo
    [[ "$v1" == "$v2" ]] || { echo "Mismatch. Try again."; continue; }
    [[ -n "$v1" ]] || { echo "Empty not allowed. Try again."; continue; }
    printf -v "$varname" '%s' "$v1"
    break
  done
}

detect_wifi_iface() {
  iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit 0}'
}

need lsblk
need sgdisk
need wipefs
need parted
need mkfs.fat
need mkfs.ext4
need mkswap
need pacstrap
need genfstab
need arch-chroot
need sed

[[ -d /sys/firmware/efi/efivars ]] || die "Boot in UEFI mode."

if [[ -z "$DISK" ]]; then
  lsblk -d -o NAME,SIZE,MODEL,TRAN
  read -r -p "Enter target DISK (example: /dev/nvme0n1): " DISK
fi
[[ -b "$DISK" ]] || die "DISK is not a block device: $DISK"

lsblk -o NAME,SIZE,MODEL,TRAN,MOUNTPOINTS "$DISK"
read -r -p "Type EXACTLY: WIPE $DISK  to confirm destructive install: " CONFIRM
[[ "$CONFIRM" == "WIPE $DISK" ]] || die "Confirmation failed."

WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD=""

read -r -p "Wi-Fi SSID (leave blank to skip): " WIFI_SSID
if [[ -n "$WIFI_SSID" ]]; then
  prompt_secret WIFI_PASSWORD "Wi-Fi password"
  if command -v iwctl >/dev/null 2>&1; then
    WIFI_IFACE="$(detect_wifi_iface || true)"
    if [[ -n "${WIFI_IFACE:-}" ]]; then
      iwctl --passphrase "$WIFI_PASSWORD" station "$WIFI_IFACE" connect "$WIFI_SSID" || true
      sleep 3
    fi
  fi
fi

ping -c 1 -W 2 archlinux.org &>/dev/null || die "No internet connectivity."

USER_PASSWORD=""
ROOT_PASSWORD=""

prompt_secret USER_PASSWORD "Password for user '$USERNAME'"
read -r -p "Set a root password? [y/N]: " SETROOT
SETROOT="${SETROOT,,}"
if [[ "$SETROOT" == "y" ]]; then
  prompt_secret ROOT_PASSWORD "Root password"
fi

timedatectl set-ntp true

umount -f "${DISK}"* "${DISK}p"* 2>/dev/null || true
swapoff "${DISK}"* "${DISK}p"* 2>/dev/null || true

wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
partprobe "$DISK" || true
sleep 2

EFI_END_MB="$EFI_SIZE_MB"
SWAP_END_MB="$((EFI_END_MB + SWAP_SIZE_GB * 1024))"

parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart EFI fat32 1MiB "${EFI_END_MB}MiB"
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart swap linux-swap "${EFI_END_MB}MiB" "${SWAP_END_MB}MiB"
parted -s "$DISK" mkpart root ext4 "${SWAP_END_MB}MiB" 100%
partprobe "$DISK" || true
sleep 2

mkfs.fat -F32 "$(get_part 1)"
mkswap "$(get_part 2)"
mkfs.ext4 -F "$(get_part 3)"

mount "$(get_part 3)" /mnt
mkdir -p /mnt/boot
mount "$(get_part 1)" /mnt/boot
swapon "$(get_part 2)"

sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

pacstrap -K /mnt \
  base base-devel linux linux-headers linux-firmware \
  intel-ucode \
  nvidia nvidia-utils nvidia-settings lib32-nvidia-utils \
  networkmanager grub efibootmgr \
  git vim nano sudo man-db man-pages \
  pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
  ntfs-3g exfatprogs wget curl rsync htop btop neofetch unzip p7zip \
  gnome gnome-tweaks gdm gnome-shell-extensions \
  docker docker-compose docker-buildx \
  python python-pip python-pipx \
  dotnet-sdk-8.0 aspnet-runtime-8.0 \
  git-lfs vlc

genfstab -U /mnt >> /mnt/etc/fstab

awk '
  $2=="/" && $3=="ext4" {
    if ($4 !~ /(^|,)noatime(,|$)/) $4=$4",noatime";
  }
  {print}
' /mnt/etc/fstab > /mnt/etc/fstab.tmp && mv /mnt/etc/fstab.tmp /mnt/etc/fstab

arch-chroot /mnt /bin/bash <<CHROOT
set -euo pipefail
IFS=\$'\n\t'

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

if grep -qE "^[# ]*$LOCALE[ ]+UTF-8" /etc/locale.gen; then
  sed -i "s/^[# ]*$LOCALE[ ]\\+UTF-8/$LOCALE UTF-8/" /etc/locale.gen
else
  echo "$LOCALE UTF-8" >> /etc/locale.gen
fi
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

cat > /etc/modprobe.d/nvidia.conf <<EOF
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_UsePageAttributeTable=1
EOF

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/nvidia.hook <<'EOF'
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia
Target=linux

[Action]
Description=Updating NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
Exec=/usr/bin/mkinitcpio -P
EOF

systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume || true

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 nvidia_drm.modeset=1"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i '/^#\\[multilib\\]/,/^#Include/ s/^#//' /etc/pacman.conf
pacman -Syu --noconfirm

useradd -m -G wheel,video,audio,docker -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd
if [[ -n "${ROOT_PASSWORD:-}" ]]; then
  echo "root:$ROOT_PASSWORD" | chpasswd
else
  passwd -l root || true
fi
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
chmod 440 /etc/sudoers.d/wheel

systemctl enable NetworkManager fstrim.timer gdm docker

cat > /etc/sysctl.d/99-performance.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF

sudo -u $USERNAME git config --global init.defaultBranch main
sudo -u $USERNAME git config --global core.autocrlf input

sudo -u $USERNAME bash -lc 'cd /tmp && rm -rf yay-bin && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'

sudo -u $USERNAME bash -lc 'yay -S --noconfirm \
  visual-studio-code-bin \
  brave-bin \
  postman-bin \
  protonvpn-gui \
  zoom \
  slack-desktop \
  spotify \
  gnome-shell-extension-dash-to-dock'

sudo -u $USERNAME bash -lc 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh"
nvm install --lts'

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-desktop-defaults <<'EOF'
[org/gnome/desktop/interface]
enable-animations=false

[org/gnome/mutter]
experimental-features=['scale-monitor-framebuffer']

[org/gnome/shell/extensions/dash-to-dock]
dock-fixed=true
autohide=false
EOF
dconf update || true

CHROOT

umount -R /mnt
swapoff -a || true

echo "Installation complete. Reboot."
