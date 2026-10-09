#!/usr/bin/env bash
# =============================================================================
#  arch-install.sh — Arch Linux + Hyprland gaming setup for "baneberry45"
#  Follows the order of the ArchWiki Installation guide.
#
#  Repo layout
#    arch              short entry point (GitHub Pages): downloads the repo, runs this
#    arch-install.sh   this script: disk, install, users, boot loader
#    packages.txt      official packages (one pacstrap transaction)
#    aur-setup.sh      yay + AUR packages, run inside the new system
#    rootfs/           config files, copied 1:1 onto the new system's /
#
#  Run from the Arch ISO (booted in UEFI mode):
#    curl -fL ch-elaine.github.io/auto-setup/arch | bash
#  !!! The selected disk is ERASED !!!
# =============================================================================
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
cd "$(dirname "$(readlink -f "$0")")"   # find packages.txt and rootfs/ next to this script

# --- Settings ----------------------------------------------------------------
DISK=""                        # e.g. /dev/nvme0n1 — empty = choose from a list
HOST_NAME="baneberry45"
USERNAME="baneberry45"
TIMEZONE="Europe/Berlin"
LOCALE="en_US.UTF-8"           # keyboard: US is Arch's default, nothing to set
BTRFS_OPTS="noatime,compress=zstd:1"

# --- Passwords: asked once, never stored in the repo --------------------------
# Unattended run:  ROOT_PASSWORD=... USER_PASSWORD=... bash arch-install.sh
[[ -n ${ROOT_PASSWORD:-} ]] || { read -rsp "Root password: " ROOT_PASSWORD; echo; }
[[ -n ${USER_PASSWORD:-} ]] || { read -rsp "Password for $USERNAME: " USER_PASSWORD; echo; }


# =============================================================================
#  1. PRE-INSTALLATION
# =============================================================================
[[ -d /sys/firmware/efi ]] || { echo "Not booted in UEFI mode"; exit 1; }

# Pick the disk; refuse the Ventoy stick; confirm.
lsblk -dpo NAME,SIZE,MODEL -e 7,11
[[ -n $DISK ]] || read -rp "Disk to install on: " DISK
ventoy=$(lsblk -no PKNAME "$(blkid -L Ventoy)" 2>/dev/null || true)
[[ "/dev/$ventoy" != "$DISK" ]] || { echo "$DISK is the Ventoy USB"; exit 1; }
read -rp "Type ERASE to wipe $DISK: " answer
[[ $answer == ERASE ]] || exit 1

exec > >(tee /root/arch-install.log) 2>&1     # log everything from here on

# Partition (GPT): 1 GiB EFI | 32 GiB swap (= RAM, allows hibernation) | rest root
sgdisk -o -n1:0:+1G -t1:ef00 -n2:0:+32G -t2:8200 -n3:0:0 -t3:8304 "$DISK"
udevadm settle
mapfile -t PART < <(lsblk -lnpo NAME "$DISK" | tail -n +2)   # [0]=EFI [1]=swap [2]=root

# Format
mkfs.fat -F 32 "${PART[0]}"
mkswap "${PART[1]}"
mkfs.btrfs -f "${PART[2]}"

# Btrfs subvolumes. @ (/) and @home (/home) are the layout Timeshift requires;
# Timeshift snapshots only @. @log and @pkg keep logs and the package cache out
# of snapshots: logs survive a rollback (to see what broke), and old packages
# aren't pinned on disk by snapshots (ArchWiki: Timeshift).
mount "${PART[2]}" /mnt
btrfs subvolume create /mnt/@ /mnt/@home /mnt/@log /mnt/@pkg
umount /mnt

# Mount (ESP root-only: avoids bootctl's "world-readable random seed" warning)
mount -o "$BTRFS_OPTS,subvol=@" "${PART[2]}" /mnt
for sv in home:@home var/log:@log var/cache/pacman/pkg:@pkg; do   # <mount point>:<subvolume>
  mount --mkdir -o "$BTRFS_OPTS,subvol=${sv#*:}" "${PART[2]}" "/mnt/${sv%%:*}"
done
mount --mkdir -o fmask=0077,dmask=0077 "${PART[0]}" /mnt/boot
swapon "${PART[1]}"
# Plain dirs, so systemd won't create them as nested subvolumes inside @ —
# those make Timeshift unable to delete snapshots (ArchWiki: Timeshift)
mkdir -p /mnt/var/lib/machines /mnt/var/lib/portables


# =============================================================================
#  2. INSTALLATION
# =============================================================================
# German mirrors; pacstrap copies the mirrorlist into the new system.
reflector --country Germany --protocol https --latest 10 --sort rate \
          --save /etc/pacman.d/mirrorlist || true
# Enable [multilib] (Steam/32-bit libs); -P copies this pacman.conf to the target.
sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
mapfile -t PACKAGES < <(sed 's/#.*//' packages.txt | xargs -n1)   # drop comments, one name per line
pacstrap -K -P /mnt "${PACKAGES[@]}"


# =============================================================================
#  3. CONFIGURE THE SYSTEM
# =============================================================================
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/,subvolid=[0-9]*//' /mnt/etc/fstab   # mount by subvol name only (snapshot-safe)

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime
sed -i "s/^#$LOCALE/$LOCALE/" /mnt/etc/locale.gen
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
echo "$HOST_NAME" > /mnt/etc/hostname
# Initramfs: nothing to do. pacstrap already built it with the default hooks,
# whose "microcode" hook embeds the matching AMD/Intel ucode into each image.

# Config files: rootfs/ mirrors the new system, so placing them is one copy.
# Everything under /etc/skel reaches the user's home when useradd runs below.
cp -r rootfs/. /mnt/
chmod 440 /mnt/etc/sudoers.d/wheel                         # mode sudo expects (git can't store it)
cp /mnt/etc/skel/.zshrc /mnt/etc/skel/.nanorc /mnt/root/   # same shell/editor setup for root
mkdir -p /mnt/etc/skel/Pictures/Screenshots /mnt/etc/skel/Videos   # hyprshot + OBS folders (git can't store empty dirs)
sed -i "s|@HOME@|/home/$USERNAME|" /mnt/etc/skel/.config/obs-studio/basic/profiles/Untitled/basic.ini   # OBS wants an absolute path
# Steam compiles Vulkan shaders in the background on every CPU thread of this PC.
# Steam's first start unpacks next to this file and keeps it.
install -D -m 644 /dev/stdin /mnt/etc/skel/.local/share/Steam/steam_dev.cfg \
    <<< "unShaderBackgroundProcessingThreads $(nproc)"
# Fill in the root filesystem's UUID (boot entries + Timeshift's snapshot device)
sed -i "s/@ROOT_UUID@/$(blkid -s UUID -o value "${PART[2]}")/" \
    /mnt/boot/loader/entries/*.conf /mnt/etc/timeshift/timeshift.json
# Bluetooth: tweak the packaged main.conf in place (faster reconnects + battery level)
sed -i -E 's/^#?(FastConnectable|Experimental) *=.*/\1 = true/' /mnt/etc/bluetooth/main.conf

# Commands that must run inside the new system
arch-chroot /mnt /bin/bash -euc "
  hwclock --systohc
  locale-gen
  useradd -m -G wheel,docker,gamemode -s /usr/bin/zsh $USERNAME
  usermod -s /usr/bin/zsh root
  bootctl install            # keeps the loader.conf copied from rootfs/
  systemctl enable NetworkManager systemd-timesyncd systemd-boot-update bluetooth docker paccache.timer cronie sddm
"
printf 'root:%s\n%s:%s\n' "$ROOT_PASSWORD" "$USERNAME" "$USER_PASSWORD" | arch-chroot /mnt chpasswd

# AUR last & non-fatal, so a download problem can't leave the system unbootable
install -m 700 aur-setup.sh /mnt/root/
arch-chroot /mnt /root/aur-setup.sh "$USERNAME" \
  || echo "WARNING: yay setup failed (see log) — install yay and aur-setup.sh's packages after reboot"
rm /mnt/root/aur-setup.sh

cp /root/arch-install.log /mnt/var/log/
echo "Done. Remove the USB stick and run: reboot"
