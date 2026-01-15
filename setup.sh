#!/bin/bash
#===============================================================================
# Arch Linux Setup - Desktop PC (Single Pass)
# i7-13700KF | RTX 3060 | 32GB DDR5 | 1TB NVMe | MSI Z790-P WiFi | 4K Monitor
#===============================================================================

set -e
trap 'echo "Error on line $LINENO"; exit 1' ERR

#-------------------------------------------------------------------------------
# CONFIGURATION
#-------------------------------------------------------------------------------
HOSTNAME="harchlaptop"
USERNAME="hsuazo"
USER_PASSWORD="froboski"
ROOT_PASSWORD="froboski"
TIMEZONE="America/Santo_Domingo"
LOCALE="en_US.UTF-8"
KEYMAP="us"

WIFI_SSID="TP-LINK-HY"
WIFI_PASSWORD="IAmSecured"

# External USB drive - VERIFY WITH 'lsblk -o NAME,SIZE,MODEL,TRAN' FIRST!
DISK="/dev/sda"
EFI_SIZE="1024"    # MB
SWAP_SIZE="8"      # GB
SYSTEM_SIZE="50"   # GB (for OS and programs)

# Partition helper
get_part() {
    if [[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]]; then
        echo "${DISK}p${1}"
    else
        echo "${DISK}${1}"
    fi
}

#-------------------------------------------------------------------------------
# CHECKS
#-------------------------------------------------------------------------------
[[ ! -d /sys/firmware/efi/efivars ]] && echo "ERROR: Boot in UEFI mode!" && exit 1

if [[ -n "$WIFI_SSID" ]]; then
    iwctl --passphrase "$WIFI_PASSWORD" station wlan0 connect "$WIFI_SSID" || true
    sleep 5
fi

ping -c 1 archlinux.org &>/dev/null || { echo "ERROR: No internet"; exit 1; }

echo ""; echo "TARGET: $DISK"; lsblk -o NAME,SIZE,MODEL "$DISK"
echo "ALL DATA WILL BE DESTROYED! (5s)"; sleep 5

#-------------------------------------------------------------------------------
# PARTITION & FORMAT
#-------------------------------------------------------------------------------
timedatectl set-ntp true

umount -f "${DISK}"* "${DISK}p"* 2>/dev/null || true
swapoff "${DISK}"* "${DISK}p"* 2>/dev/null || true
wipefs -af "$DISK"
sgdisk --zap-all "$DISK"
partprobe "$DISK"; sleep 2

# Partitions
EFI_END=$EFI_SIZE
SWAP_END=$((EFI_END + SWAP_SIZE * 1024))
SYSTEM_END=$((SWAP_END + SYSTEM_SIZE * 1024))

parted -s $DISK mklabel gpt
parted -s $DISK mkpart "EFI" fat32 1MiB "${EFI_END}MiB"
parted -s $DISK set 1 esp on
parted -s $DISK mkpart "swap" linux-swap "${EFI_END}MiB" "${SWAP_END}MiB"
parted -s $DISK mkpart "system" ext4 "${SWAP_END}MiB" "${SYSTEM_END}MiB"
parted -s $DISK mkpart "data" ext4 "${SYSTEM_END}MiB" 100%
partprobe $DISK; sleep 2

mkfs.fat -F32 "$(get_part 1)"
mkswap "$(get_part 2)"
mkfs.ext4 -F "$(get_part 3)"
mkfs.ext4 -F "$(get_part 4)"

mount "$(get_part 3)" /mnt
mkdir -p /mnt/boot
mount "$(get_part 1)" /mnt/boot
mkdir -p /mnt/home
mount "$(get_part 4)" /mnt/home
swapon "$(get_part 2)"

#-------------------------------------------------------------------------------
# INSTALL BASE
#-------------------------------------------------------------------------------
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

pacstrap -K /mnt \
    base base-devel linux linux-headers linux-firmware \
    intel-ucode nvidia nvidia-utils nvidia-settings lib32-nvidia-utils \
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
sed -i 's/relatime/noatime,discard=async/' /mnt/etc/fstab

#-------------------------------------------------------------------------------
# CONFIGURE SYSTEM (chroot)
#-------------------------------------------------------------------------------
arch-chroot /mnt /bin/bash <<CHROOT
set -e

# Timezone & locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# NVIDIA
sed -i 's/^MODULES=.*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
mkinitcpio -P

cat > /etc/modprobe.d/nvidia.conf <<EOF
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_UsePageAttributeTable=1
EOF

mkdir -p /etc/pacman.d/hooks
cat > /etc/pacman.d/hooks/nvidia.hook <<EOF
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

systemctl enable nvidia-suspend nvidia-hibernate nvidia-resume

# Bootloader (skip GRUB menu)
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet loglevel=3 nvidia_drm.modeset=1"/' /etc/default/grub
sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Pacman
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
pacman -Sy

# User
useradd -m -G wheel,video,audio,docker -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASSWORD" | chpasswd
echo "root:$ROOT_PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Services
systemctl enable NetworkManager fstrim.timer gdm docker

# WiFi config
if [[ -n "$WIFI_SSID" ]]; then
    mkdir -p /etc/NetworkManager/system-connections
    cat > "/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection" <<EOF
[connection]
id=$WIFI_SSID
type=wifi
autoconnect=true
[wifi]
ssid=$WIFI_SSID
[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PASSWORD
[ipv4]
method=auto
[ipv6]
method=auto
EOF
    chmod 600 "/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection"
fi

# Remove GNOME bloat
pacman -Rns --noconfirm \
    gnome-contacts \
    gnome-weather \
    gnome-maps \
    gnome-music \
    gnome-tour \
    yelp \
    totem \
    gnome-photos \
    gnome-calendar \
    gnome-clocks \
    cheese \
    epiphany \
    gnome-software \
    simple-scan \
    gnome-characters \
    gnome-font-viewer \
    gnome-logs \
    gnome-connections \
    gnome-remote-desktop \
    gnome-user-docs \
    malcontent \
    snapshot \
    gnome-text-editor \
    loupe \
    orca \
    rygel \
    gnome-color-manager \
    gnome-backgrounds \
    2>/dev/null || true

# Performance
cat > /etc/sysctl.d/99-performance.conf <<EOF
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.dirty_ratio=10
vm.dirty_background_ratio=5
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF

# Git config
sudo -u $USERNAME git config --global init.defaultBranch main
sudo -u $USERNAME git config --global core.autocrlf input

# Install yay
sudo -u $USERNAME bash -c 'cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'

# AUR packages
sudo -u $USERNAME yay -S --noconfirm \
    visual-studio-code-bin \
    brave-bin \
    postman-bin \
    protonvpn-gui \
    zoom \
    slack-desktop \
    spotify \
    gnome-shell-extension-dash-to-dock

# nvm and Node.js LTS
sudo -u $USERNAME bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash && source ~/.nvm/nvm.sh && nvm install --lts'

# GNOME settings: no animations, 200% scaling
sudo -u $USERNAME dbus-launch gsettings set org.gnome.desktop.interface enable-animations false
sudo -u $USERNAME dbus-launch gsettings set org.gnome.desktop.interface scaling-factor 2
sudo -u $USERNAME dbus-launch gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"

# Dash to Dock configuration
sudo -u $USERNAME dbus-launch gnome-extensions enable dash-to-dock@micxgx.gmail.com 2>/dev/null || true
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock dock-fixed true
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock autohide false
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock intellihide false
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock multi-monitor true
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock dock-position 'BOTTOM'
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock extend-height true
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock dash-max-icon-size 28
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock icon-size-fixed true
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock show-mounts false
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock show-trash false
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock custom-theme-shrink true
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock running-indicator-style 'DOTS'
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock custom-background-color true
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock background-color 'rgb(0,0,0)'
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock transparency-mode 'FIXED'
sudo -u $USERNAME dbus-launch gsettings set org.gnome.shell.extensions.dash-to-dock background-opacity 0.25

# Create /code and /downloads shortcuts
mkdir -p /home/$USERNAME/code
mkdir -p /home/$USERNAME/Downloads
chown $USERNAME:$USERNAME /home/$USERNAME/code
chown $USERNAME:$USERNAME /home/$USERNAME/Downloads
ln -sf /home/$USERNAME/code /code
ln -sf /home/$USERNAME/Downloads /downloads

# Remove default XDG folders (Documents, Music, Pictures, Videos)
sudo -u $USERNAME bash <<EOF
rm -rf ~/Documents ~/Music ~/Pictures ~/Videos ~/Templates ~/Public
mkdir -p ~/.config
cat > ~/.config/user-dirs.dirs <<'XDGEOF'
XDG_DESKTOP_DIR="\\\$HOME"
XDG_DOWNLOAD_DIR="\\\$HOME/Downloads"
XDG_DOCUMENTS_DIR="\\\$HOME"
XDG_MUSIC_DIR="\\\$HOME"
XDG_PICTURES_DIR="\\\$HOME"
XDG_VIDEOS_DIR="\\\$HOME"
XDG_TEMPLATES_DIR="\\\$HOME"
XDG_PUBLICSHARE_DIR="\\\$HOME"
XDGEOF
echo "enabled=false" > ~/.config/user-dirs.conf
EOF

CHROOT

#-------------------------------------------------------------------------------
# DONE
#-------------------------------------------------------------------------------
umount -R /mnt

echo ""
echo "=============================================="
echo "    Installation Complete!"
echo "=============================================="
echo ""
echo "Partition Layout:"
echo "  $(get_part 1) - EFI     (1GB)"
echo "  $(get_part 2) - Swap    (8GB)"
echo "  $(get_part 3) - System  (600GB)"
echo "  $(get_part 4) - Data    (rest)"
echo ""
echo "Shortcuts:"
echo "  /code      → ~/code"
echo "  /downloads → ~/Downloads"
echo ""
echo "Installed Apps:"
echo "  VS Code, Brave, Postman, VLC"
echo "  Docker, .NET 8, Node.js (nvm), Python"
echo "  ProtonVPN, Zoom, Slack, Spotify"
echo ""
echo "GNOME: Debloated, no animations, 200% scale"
echo "Dock: Bottom, black, 25% opacity, 28px icons"
echo ""
echo "Run: reboot"
echo ""
