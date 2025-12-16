#!/bin/bash

# ================================================================
# Arch Linux Automated Installer with Enlightenment Desktop
# ================================================================
# Author: Jojo Nazareno (based on Robin Candau)
# Purpose: Fully automated Arch Linux installation with Enlightenment DE
# Notes:
#   - Designed for UEFI systems
#   - Automatically partitions the selected disk
#   - Configures user, hostname, timezone, locale
#   - Installs GPU drivers, CPU microcode, and common packages
#   - Enables key services
# ================================================================

echo "================================================================"
echo "Arch Linux Installer with Enlightenment Desktop"
echo "Self-documenting version with annotations for clarity"
echo "================================================================"
echo ""
echo "/!\ WARNING /!\\"
echo "This will ERASE ALL DATA on the selected disk!"
echo "Ensure you have backups of any important data!"
echo ""
read -n 1 -r -s -p $'Press \"enter\" to continue or \"ctrl + c\" to abort\n'

# ===========================================================================
# Disk Management Functions
# ===========================================================================

# List available storage devices and their partitions
list_disks() {
    echo ""
    echo "=== Available Storage Devices ==="
    echo "Device     Size        Type    Model"
    echo "-----------------------------------"
    lsblk -d -o NAME,SIZE,TYPE,MODEL | grep -E "(disk|nvme)" | grep -v loop | while read line; do
        echo "  $line"
    done
    
    echo ""
    echo "=== Current Partition Layout ==="
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v loop | head -20
    echo ""
}

# Ask the user to select which disk to install on
select_disk() {
    local disk=""
    while [ -z "$disk" ]; do
        list_disks
        echo "Enter the disk to install on (e.g., sda, nvme0n1, vda):"
        read -p "Disk (without /dev/): " disk_input
        
        # Remove any accidental /dev/ prefix
        disk_input=$(echo "$disk_input" | tr -d '/dev/')
        
        # Validate the disk exists
        if [ -b "/dev/$disk_input" ] && lsblk -d -o NAME | grep -q "^$disk_input$"; then
            echo ""
            echo "Selected disk: /dev/$disk_input"
            lsblk -d -o NAME,SIZE,MODEL,TRAN | grep "^$disk_input"
            echo ""
            
            read -p "WARNING: This will erase ALL data on /dev/$disk_input. Continue? (type 'YES' to confirm): " confirm
            if [ "$confirm" = "YES" ]; then
                echo "$disk_input"
                return
            else
                echo "Selection cancelled."
                disk=""
            fi
        else
            echo "Error: /dev/$disk_input does not exist or is not a valid disk."
            disk=""
        fi
    done
}

# Partition the disk and format partitions
partition_disk() {
    local disk="$1"
    
    # Partition naming differs for NVMe
    if [[ "$disk" == nvme* ]]; then
        BOOT_PART="/dev/${disk}p1"
        SWAP_PART="/dev/${disk}p2"
        ROOT_PART="/dev/${disk}p3"
    else
        BOOT_PART="/dev/${disk}1"
        SWAP_PART="/dev/${disk}2"
        ROOT_PART="/dev/${disk}3"
    fi
    
    echo ""
    echo "=== Partitioning /dev/$disk ==="
    echo "Partition layout:"
    echo "  1) EFI System Partition: 512 MiB, FAT32"
    echo "  2) Linux Swap: 4 GiB (adjustable)"
    echo "  3) Root Partition: remaining space, ext4"
    
    # Ensure nothing is mounted
    umount -R /mnt 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    
    # Clean existing partition table
    echo "Cleaning existing partition table..."
    sgdisk --zap-all "/dev/$disk"
    
    # Create GPT partition table
    parted -s "/dev/$disk" mklabel gpt
    
    # Create EFI partition (512 MiB)
    parted -s "/dev/$disk" mkpart primary fat32 1MiB 513MiB
    parted -s "/dev/$disk" set 1 esp on
    
    # Create swap partition (4 GiB)
    parted -s "/dev/$disk" mkpart primary linux-swap 513MiB 4609MiB
    
    # Create root partition (remaining space)
    parted -s "/dev/$disk" mkpart primary ext4 4609MiB 100%
    
    # Update kernel partition info
    partprobe "/dev/$disk"
    sleep 2
    
    # Format partitions
    mkfs.fat -F32 "$BOOT_PART" && echo "EFI partition formatted: $BOOT_PART"
    mkswap "$SWAP_PART" && swapon "$SWAP_PART" && echo "Swap enabled: $SWAP_PART"
    mkfs.ext4 -F "$ROOT_PART" && echo "Root partition formatted: $ROOT_PART"
    
    echo ""
    echo "Partitioning complete!"
    echo "  Boot: $BOOT_PART"
    echo "  Swap: $SWAP_PART"
    echo "  Root: $ROOT_PART"
}

# ===========================================================================
# Password Handling Functions
# ===========================================================================

# Securely prompt for password (with confirmation)
get_password() {
    local prompt="$1"
    local password=""
    local password_confirm=""
    
    while true; do
        echo ""
        echo -n "$prompt: "
        read -s password
        echo
        echo -n "Confirm $prompt: "
        read -s password_confirm
        echo
        
        if [ "$password" = "$password_confirm" ] && [ -n "$password" ]; then
            if [ ${#password} -ge 8 ]; then
                echo "$password"
                break
            else
                echo "Password must be at least 8 characters. Please try again."
            fi
        else
            echo "Passwords do not match or are empty. Please try again."
        fi
    done
}

# ===========================================================================
# User Configuration Section
# ===========================================================================

echo ""
echo "=== System Configuration ==="

# Disk selection and partitioning
SELECTED_DISK=$(select_disk)
partition_disk "$SELECTED_DISK"

# Set variables for partition mounting
if [[ "$SELECTED_DISK" == nvme* ]]; then
    BOOT_PART="/dev/${SELECTED_DISK}p1"
    ROOT_PART="/dev/${SELECTED_DISK}p3"
else
    BOOT_PART="/dev/${SELECTED_DISK}1"
    ROOT_PART="/dev/${SELECTED_DISK}3"
fi

# Basic system settings (prompt user with defaults)
read -p "Hostname [Arch-Linux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-Arch-Linux}

read -p "Username [jojo]: " USER_NAME
USER_NAME=${USER_NAME:-jojo}

read -p "Timezone [Asia/Manila]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Asia/Manila}

read -p "Language [en_US.UTF-8]: " LANGUAGE
LANGUAGE=${LANGUAGE:-en_US.UTF-8}

read -p "Keyboard layout [us]: " KEYMAP
KEYMAP=${KEYMAP:-us}

# Detect CPU type and select microcode
if grep -q "GenuineIntel" /proc/cpuinfo; then
    CPU="intel-ucode"
    echo "Detected Intel CPU -> will install $CPU"
elif grep -q "AuthenticAMD" /proc/cpuinfo; then
    CPU="amd-ucode"
    echo "Detected AMD CPU -> will install $CPU"
else
    CPU=""
    echo "CPU microcode not detected -> skipping"
fi

# GPU driver selection
echo ""
echo "Select GPU driver:"
echo "  1) mesa (Intel/AMD)"
echo "  2) nvidia (NVIDIA proprietary)"
echo "  3) nvidia-lts (NVIDIA LTS kernel)"
read -p "Choice [1]: " gpu_choice
case $gpu_choice in
    2) GPU="nvidia" ;;
    3) GPU="nvidia-lts" ;;
    *) GPU="mesa" ;;
esac
echo "Selected: $GPU"

# Kernel selection
read -p "Install LTS kernel instead of regular? (y/N): " kernel_choice
if [[ "$kernel_choice" =~ ^[Yy]$ ]]; then
    KERNEL="linux-lts"
    [[ "$GPU" == "nvidia" ]] && GPU="nvidia-lts"
else
    KERNEL="linux"
fi

# Passwords
ROOT_PWD=$(get_password "Root password")
USER_PWD=$(get_password "User password for $USER_NAME")

# ===========================================================================
# Package Installation Function
# ===========================================================================

PACKAGES() {
    echo "Installing Enlightenment desktop and utilities..."
    
    pacman -S --noconfirm --needed \
        networkmanager network-manager-applet wireless_tools wpa_supplicant \
        vim nano base-devel git linux-headers bash-completion man-db man-pages texinfo \
        xorg-server xorg-xinit xorg-xrandr xorg-xsetroot xorg-xprop xorg-xbacklight \
        enlightenment terminology efl efl-docs lightdm lightdm-gtk-greeter \
        arc-gtk-theme papirus-icon-theme ttf-dejavu ttf-liberation noto-fonts \
        pulseaudio pulseaudio-alsa pavucontrol alsa-utils \
        smartmontools nvme-cli bluez bluez-utils cups hplip \
        firefox file-roller p7zip unrar gvfs gvfs-mtp gvfs-smb ntfs-3g imagemagick \
        htop neofetch
     
    # Enable core services
    systemctl enable NetworkManager
    systemctl enable lightdm
    systemctl enable bluetooth
    systemctl enable cups
    
    echo "Package installation complete!"
}

# ===========================================================================
# Main Installation Process
# ===========================================================================

echo ""
echo "=== Mounting partitions ==="
mount $ROOT_PART /mnt || exit 1
mkdir -p /mnt/boot/EFI
mount $BOOT_PART /mnt/boot/EFI || exit 1

echo ""
echo "=== Base system installation ==="
pacstrap /mnt base $KERNEL linux-firmware dosfstools exfatprogs f2fs-tools xfsprogs btrfs-progs lvm2 mdadm

echo ""
echo "=== Generating fstab ==="
genfstab -U /mnt >> /mnt/etc/fstab

echo ""
echo "=== Configuring system (timezone, locale, hostname) ==="
arch-chroot /mnt bash -c "
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
sed -i 's/#$LANGUAGE/$LANGUAGE/' /etc/locale.gen
locale-gen
echo LANG=$LANGUAGE > /etc/locale.conf
echo KEYMAP=$KEYMAP > /etc/vconsole.conf
echo $HOSTNAME > /etc/hostname
echo -e '127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t$HOSTNAME.localdomain\t$HOSTNAME' >> /etc/hosts
"

echo ""
echo "=== Setting up users ==="
arch-chroot /mnt bash -c "
echo root:$ROOT_PWD | chpasswd
useradd -m -G wheel,audio,video,optical,storage,games -s /bin/bash $USER_NAME
echo $USER_NAME:$USER_PWD | chpasswd
pacman -S --noconfirm sudo
echo '%wheel ALL=(ALL) ALL' >> /etc/sudoers
echo 'Defaults !tty_tickets' >> /etc/sudoers
"

echo ""
echo "=== Installing bootloader ==="
arch-chroot /mnt bash -c "
pacman -S --noconfirm grub efibootmgr os-prober
grub-install --target=x86_64-efi --bootloader-id=GRUB --efi-directory=/boot/EFI
grub-mkconfig -o /boot/grub/grub.cfg
"

echo ""
echo "=== Installing GPU/CPU drivers and desktop ==="
[[ -n "$CPU" ]] && arch-chroot /mnt bash -c "pacman -S --noconfirm $CPU"
arch-chroot /mnt bash -c "pacman -S --noconfirm $GPU"
arch-chroot /mnt bash -c "PACKAGES"

echo ""
echo "=== Final cleanup ==="
sync
umount -R /mnt
swapoff -a

echo ""
echo "Installation complete!"
echo "Rebooting in 30 seconds..."
sleep 30
reboot
