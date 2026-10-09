-- ~/.config/hypr/hyprland.lua — Hyprland 0.55+ Lua config
-- Defaults/reference: /usr/share/hypr/hyprland.lua
local mod = "SUPER"

-- Gigabyte M27Q: 1440p @ 144 Hz (up to 170 Hz over DisplayPort), FreeSync in fullscreen games (vrr = 2)
hl.monitor({ output = "", mode = "2560x1440@144", position = "0x0", scale = 1, vrr = 2 })

hl.config({
    input   = { kb_layout = "us", accel_profile = "flat" },  -- US keys, raw mouse input
    general = {
        allow_tearing = true,                                -- master switch for the game rule at the bottom
        border_size   = 2,
        col = {                                              -- trans flag gradient on the focused window
            active_border   = { colors = { "rgba(5bcefaee)", "rgba(f5a9b8ee)", "rgba(ffffffee)",
                                           "rgba(f5a9b8ee)", "rgba(5bcefaee)" }, angle = 45 },
            inactive_border = "rgba(3a3044aa)",
        },
    },
    -- render = { direct_scanout = 2 },  -- even lower latency, but has black-screen bugs in some games
})

hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    hl.exec_cmd("systemctl --user start hyprpolkitagent")
end)

-- Launcher (every app starts from here) + screenshots
hl.bind(mod .. " + space", hl.dsp.exec_cmd("wofi --show drun"))
hl.bind("ALT + SHIFT + 4", hl.dsp.exec_cmd("hyprshot -z -m region -o ~/Pictures/Screenshots"))  -- freeze, select, save + copy

-- Windows
hl.bind(mod .. " + Q",         hl.dsp.window.close())  -- asks the app to quit
hl.bind(mod .. " + SHIFT + Q", hl.dsp.window.kill())   -- force quit (SIGKILL) for hung apps
hl.bind(mod .. " + V", hl.dsp.window.float({ action = "toggle" }))
hl.bind(mod .. " + M", hl.dsp.exit())
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(),   { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
for _, dir in ipairs({ "left", "right", "up", "down" }) do
    hl.bind(mod .. " + " .. dir, hl.dsp.focus({ direction = dir }))
end

-- Workspaces 1-10 (key 0 = 10)
for i = 1, 10 do
    hl.bind(mod .. " + " .. i % 10,         hl.dsp.focus({ workspace = i }))
    hl.bind(mod .. " + SHIFT + " .. i % 10, hl.dsp.window.move({ workspace = i }))
end

-- Volume keys
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"), { locked = true, repeating = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),      { locked = true, repeating = true })
hl.bind("XF86AudioMute",        hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),     { locked = true })

-- Fullscreen games skip vsync = lowest input latency (Hyprland's own example uses cs2).
-- steam_app_* covers Proton games. Below the refresh rate FreeSync takes over instead.
hl.window_rule({ name = "game-tearing", match = { class = "^(cs2|steam_app_.*)$" }, immediate = true })
hl.bind(mod .. " + F", hl.dsp.window.fullscreen())
