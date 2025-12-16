#!/bin/bash
set -e

# ================================================================
# Arch Linux + Enlightenment (E24) Installer
# ================================================================
#
# Target system:
#   Lenovo 100-15IBY
#   Intel Braswell (Gen8 iGPU)
#   HDD
#   8 GB RAM
#
# Design principles:
#   - Prefer simple, stock Arch components
#   - Avoid hacks and legacy workarounds
#   - Optimize for low memory + HDD performance
#
# Graphics:
#   - Uses standard Mesa + i915
#   - mesa-amber is NOT required for Braswell
#
# Networking:
#   - Assumes internet is already available in live ISO
#   - Wi-Fi in live ISO: use iwctl ONCE if needed
#   - Post-install networking handled by NetworkManager
#
# Desktop:
#   - Enlightenment E24 (lightweight, modern)
#   - Avoid installing multiple DEs (bloat)
#
# Last reviewed: 2025
# ================================================================


# ================================================================
# SAFETY: DISK SELECTION
# ================================================================
#
# This laptop may contain more than one drive.
# NEVER assume /dev/sda is correct.
#

echo "Available disks:"
lsblk -d -o NAME,SIZE,MODEL
echo

read -rp "Enter target disk (example: sda): " DISK
DISK="/dev/$DISK"

echo
echo "⚠️  WARNING"
echo "All data on $DISK will be permanently erased."
read -rp "Type YES (uppercase) to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi


# ================================================================
# PARTITIONING (UEFI)
# ================================================================
#
# Layout:
#   EFI System Partition: 512 MB (FAT32)
#   Root: rest of disk (ext4)
#

wipefs -af "$DISK"

parted "$DISK" --script \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 esp on \
    mkpart ROOT ext4 513MiB 100%

mkfs.fat -F32 "${DISK}1"
mkfs.ext4 "${DISK}2"

mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mount "${DISK}1" /mnt/boot


# ================================================================
# BASE SYSTEM INSTALL
# ================================================================
#
# Includes:
#   - linux + firmware
#   - intel-ucode (safe for Intel CPUs)
#   - NetworkManager for Wi-Fi
#

pacstrap /mnt \
    base linux linux-firmware \
    intel-ucode \
    networkmanager \
    grub efibootmgr \
    sudo vim

genfstab -U /mnt >> /mnt/etc/fstab


# ================================================================
# SYSTEM CONFIGURATION (CHROOT)
# ================================================================

arch-chroot /mnt /bin/bash <<EOF

# ------------------------------------------------
# Time & locale
# ------------------------------------------------
ln -sf /usr/share/zoneinfo/Asia/Manila /etc/localtime
hwclock --systohc

sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# ------------------------------------------------
# Hostname
# ------------------------------------------------
echo "arch-lenovo" > /etc/hostname

# ------------------------------------------------
# Enable networking
# ------------------------------------------------
systemctl enable NetworkManager


# ================================================================
# USER SETUP
# ================================================================
#
# Replace username if needed.
#

useradd -m -G wheel -s /bin/bash joseph
echo "Set password for joseph:"
passwd joseph

# Allow wheel group sudo access
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers


# ================================================================
# GRAPHICS STACK
# ================================================================
#
# Intel Braswell works correctly with:
#   - kernel i915
#   - stock mesa
#
# No legacy drivers needed.
#

pacman -S --noconfirm \
    mesa \
    xf86-video-intel \
    xorg-server xorg-xinit xorg-xrandr \
    enlightenment efl terminology \
    lightdm lightdm-gtk-greeter

systemctl enable lightdm


# ================================================================
# AUDIO, POWER, BLUETOOTH
# ================================================================
#
# PipeWire for modern audio
# acpid for laptop power events
#

pacman -S --noconfirm \
    pipewire pipewire-alsa pipewire-pulse wireplumber \
    acpi acpid \
    bluez bluez-utils blueman

systemctl enable bluetooth
systemctl enable acpid


# ================================================================
# BOOTLOADER
# ================================================================
#
# UEFI system using GRUB
#

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

EOF


# ================================================================
# INSTALL COMPLETE
# ================================================================

echo
echo "✅ Installation complete."
echo "Reboot, log in via LightDM, and enjoy Enlightenment E24."
