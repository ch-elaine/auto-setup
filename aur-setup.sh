#!/usr/bin/env bash
# aur-setup.sh — runs INSIDE the new system (arch-install.sh calls it through
# arch-chroot with the username as $1). Installs yay, then the AUR packages below.
# makepkg refuses to run as root, so the user gets temporary password-less sudo,
# which the trap removes again on exit — even if something fails.
set -u
AUR_PACKAGES=(
    ttf-ms-win11-auto    # Windows 11 fonts, extracted from Microsoft's Win11 evaluation ISO
    timeshift-autosnap   # Timeshift snapshot before every pacman upgrade. KEEP LAST: its
                         # pacman hook would otherwise snapshot every later install here
)

echo "$1 ALL=(ALL) NOPASSWD: ALL" | install -m 440 /dev/stdin /etc/sudoers.d/zz-install
trap 'rm -f /etc/sudoers.d/zz-install' EXIT

# shellcheck disable=SC2016  # $@ must expand inside the user's shell, not here
sudo -u "$1" bash -euc '
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    cd /tmp/yay-bin && makepkg -si --noconfirm
    yay -Y --gendb && yay -Y --devel --save     # yay first-use setup (track -git packages)
    for pkg in "$@"; do                         # one at a time: a failure only skips that package
        yay -S --noconfirm --needed "$pkg" || echo "WARNING: $pkg failed — after reboot run: yay -S $pkg"
    done
' _ "${AUR_PACKAGES[@]}"
