#!/usr/bin/env bash
# ~/.config/waybar/scripts/sysmon.sh — feeds "custom/sysmon" in config.jsonc.
# Prints one JSON line every 2 s: bar text (CPU/RAM/GPU load), tooltip (the hover popup with
# temps, clocks and memory) and a CSS class when something runs hot. The loop only uses bash
# builtins on /proc and sysfs, so a tick costs one `sleep` fork.

# hwmonN numbers can shuffle between boots, so find each sensor chip by its driver name
for d in /sys/class/hwmon/hwmon*; do
  read -r name < "$d/name"
  case $name in
    coretemp) cpu_hw=$d ;;   # i7-7700K: temp1 = package, temp2-5 = cores
    amdgpu)   gpu_hw=$d ;;   # Radeon: temp1 edge, temp2 junction (hotspot), temp3 VRAM
    kraken2)  aio_hw=$d ;;   # NZXT Kraken: temp1 = coolant
  esac
done
gpu_dev=$gpu_hw/device

# Limits (°C) for the warning/critical colours. Sensor limits: CPU max 80 / crit 100,
# GPU hotspot crit 110
cpu_warn=80 cpu_crit=90
gpu_warn=95 gpu_crit=105
ram_warn=90   # % used

c_cpu='#5bcefa' c_mem='#f5a9b8' c_gpu='#ffffff' c_dim='#8a7f96'

# gib OUT KIB: OUT = "11.2" (GiB, one decimal)
gib() { local t=$(( ($2 * 10 + 524288) / 1048576 )); printf -v "$1" '%d.%d' $((t / 10)) $((t % 10)); }

# heat OUT VALUE WARN CRIT: OUT = VALUE, tinted amber/red past the limits; raises $state
heat() {
  if   (( $2 >= $4 )); then printf -v "$1" "<span color='#ff7aa2'>%s</span>" "$2"; state=2
  elif (( $2 >= $3 )); then printf -v "$1" "<span color='#ffb86c'>%s</span>" "$2"; (( state )) || state=1
  else printf -v "$1" '%s' "$2"; fi
}

cpu_times() {   # sets busy/total from the aggregate line of /proc/stat
  local _ user nice system idle iowait irq softirq steal
  read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
  total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  busy=$((total - idle - iowait))
}

cpu_times
while sleep 2; do
  state=0
  prev_busy=$busy prev_total=$total
  cpu_times
  cpu=$(( (busy - prev_busy) * 100 / (total - prev_total > 0 ? total - prev_total : 1) ))

  # --- CPU temps ---
  read -r t < "$cpu_hw/temp1_input"; heat cpu_t $((t / 1000)) $cpu_warn $cpu_crit
  cores=
  for f in "$cpu_hw"/temp[2-9]_input; do read -r t < "$f"; cores+=" $((t / 1000))"; done
  coolant=
  if [[ $aio_hw ]]; then
    read -r t < "$aio_hw/temp1_input"
    printf -v coolant '%-9s%d.%d°C' Coolant $((t / 1000)) $((t % 1000 / 100))
    coolant=$'\n'$coolant
  fi

  # --- Memory ---
  while read -r key val _; do
    case $key in
      MemTotal:) mem_total=$val ;; MemAvailable:) mem_avail=$val ;;
      SwapTotal:) swap_total=$val ;; SwapFree:) swap_free=$val ;;
    esac
  done < /proc/meminfo
  mem_used=$((mem_total - mem_avail))
  ram=$((mem_used * 100 / mem_total))
  (( ram >= ram_warn && state < 1 )) && state=1
  gib ram_used $mem_used; gib ram_total $mem_total
  gib swap_used $((swap_total - swap_free)); gib swap_tot $swap_total

  # --- GPU ---
  read -r gpu < "$gpu_dev/gpu_busy_percent"
  read -r vram_used < "$gpu_dev/mem_info_vram_used"
  read -r vram_total < "$gpu_dev/mem_info_vram_total"
  gib vram_used $((vram_used / 1024)); gib vram_total $((vram_total / 1024))
  read -r t < "$gpu_hw/temp1_input"; gpu_edge=$((t / 1000))
  read -r t < "$gpu_hw/temp2_input"; heat gpu_hot $((t / 1000)) $gpu_warn $gpu_crit
  read -r t < "$gpu_hw/temp3_input"; gpu_mem=$((t / 1000))
  read -r sclk < "$gpu_hw/freq1_input"
  read -r power < "$gpu_hw/power1_average"
  read -r fan < "$gpu_hw/fan1_input"

  # --- Output ---
  printf -v text '󰻠 %d%%  󰍛 %d%%  󰢮 %d%%' "$cpu" "$ram" "$gpu"

  printf -v tip_cpu "<span color='%s'><b>󰻠 CPU</b></span>\n%-9s%d%%\n%-9s%s°C  <span color='%s'>cores%s</span>%s" \
    "$c_cpu" Load "$cpu" Temp "$cpu_t" "$c_dim" "$cores" "$coolant"
  printf -v tip_mem "<span color='%s'><b>󰍛 Memory</b></span>\n%-9s%s / %s GiB  %d%%\n%-9s%s / %s GiB" \
    "$c_mem" RAM "$ram_used" "$ram_total" "$ram" Swap "$swap_used" "$swap_tot"
  printf -v tip_gpu "<span color='%s'><b>󰢮 GPU</b></span>\n%-9s%d%%  <span color='%s'>@ %d MHz</span>\n%-9s%s / %s GiB\n%-9s%d°C  <span color='%s'>hotspot</span> %s  <span color='%s'>mem</span> %d\n%-9s%d W  <span color='%s'>fan %d RPM</span>" \
    "$c_gpu" Load "$gpu" "$c_dim" $((sclk / 1000000)) VRAM "$vram_used" "$vram_total" \
    Temp "$gpu_edge" "$c_dim" "$gpu_hot" "$c_dim" "$gpu_mem" Power $((power / 1000000)) "$c_dim" "$fan"

  tip="$tip_cpu"$'\n\n'"$tip_mem"$'\n\n'"$tip_gpu"
  tip=${tip//$'\n'/\\n}   # JSON strings can't hold raw newlines

  case $state in 2) class=critical ;; 1) class=warning ;; *) class= ;; esac
  printf '{"text":"%s","tooltip":"<tt>%s</tt>","class":"%s"}\n' "$text" "$tip" "$class"
done
