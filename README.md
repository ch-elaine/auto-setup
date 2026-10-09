**Arch Linux:** boot the Arch ISO in UEFI mode and run:

```bash
curl -fL ch-elaine.github.io/auto-setup/arch | bash
```

Pick the disk, type `ERASE` to confirm, and enter the passwords. Settings (hostname, user, timezone) are at the top of `arch-install.sh`.

**Windows 11:** copy `windows/autounattend.xml` to the root of a Windows 11 install USB and boot from it. After the first sign-in, `PostInstall.ps1` runs on its own and restarts the PC once or twice.

## What it installs and configures

**Arch Linux**
- Btrfs with Timeshift snapshots, systemd-boot with `linux-zen` and `linux-lts`
- Hyprland with an SDDM login screen (trans pride theme), Waybar, zsh, PipeWire, Bluetooth
- Steam, GameMode, Gamescope, MangoHud, AMD drivers and gaming kernel tweaks
- Firefox, Kitty, Thunar, Docker, OBS (screen and game recording, set up for 1080p60 GPU-encoded MP4s in `~/Videos`)
- neofetch with `mysterious-shape.py` animated in place of the Arch logo (until Ctrl+C)

**Windows 11**
- Windows 11 Pro with `C:` (250 GB) and a `D:` data partition, most built-in apps removed
- AMD Adrenalin driver, Steam, Discord, Firefox, Lightshot, Twinkle Tray, DirectX
- WSL2 with Ubuntu, Docker Desktop
- Removes Edge and Windows Defender, runs Win11Debloat
