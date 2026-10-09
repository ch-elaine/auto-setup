# ~/.zprofile — log in on tty1 and Hyprland starts (other TTYs stay as rescue consoles)
[[ -z $WAYLAND_DISPLAY && ${XDG_VTNR:-0} -eq 1 ]] && exec start-hyprland
