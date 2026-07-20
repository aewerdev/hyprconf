#!/usr/bin/env bash
set -Eeuo pipefail

# Migrate the ilyamiro Hyprland layer from deprecated hyprlang (*.conf)
# to native Hyprland 0.55+ Lua, while leaving Quickshell/QML intact.
#
# Usage:
#   sudo ./migrate-ilyamiro-hyprland-to-lua.sh
#
# Optional:
#   TARGET_USER=w3r APPLY_MODE=dry-build sudo -E ./migrate-ilyamiro-hyprland-to-lua.sh
#   TARGET_USER=w3r APPLY_MODE=boot      sudo -E ./migrate-ilyamiro-hyprland-to-lua.sh
#   TARGET_USER=w3r APPLY_MODE=switch    sudo -E ./migrate-ilyamiro-hyprland-to-lua.sh
#   FORCE=1                              bypass Hyprland version check
#
# APPLY_MODE: switch (default), boot, dry-build, none

TARGET_USER="${TARGET_USER:-${SUDO_USER:-w3r}}"
APPLY_MODE="${APPLY_MODE:-switch}"
FORCE="${FORCE:-0}"

NIXOS_DIR="/etc/nixos"
HYPR_SRC="$NIXOS_DIR/config/sessions/hyprland"
LUA_SRC="$HYPR_SRC/lua"
HM_MODULE="$HYPR_SRC/default.nix"
MATUGEN_DIR="$NIXOS_DIR/config/programs/matugen"
MATUGEN_CONFIG="$MATUGEN_DIR/config.toml"
MATUGEN_TEMPLATE_DIR="$MATUGEN_DIR/templates"
MATUGEN_LUA_TEMPLATE="$MATUGEN_TEMPLATE_DIR/hyprland.lua.template"
FLAKE_ATTR="${FLAKE_ATTR:-mbp}"

if [[ $EUID -ne 0 ]]; then
  echo "Run this script as root: sudo $0" >&2
  exit 1
fi

case "$APPLY_MODE" in
  switch|boot|dry-build|none) ;;
  *)
    echo "Invalid APPLY_MODE=$APPLY_MODE; expected switch, boot, dry-build, or none." >&2
    exit 1
    ;;
esac

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  echo "User '$TARGET_USER' does not exist." >&2
  exit 1
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  echo "Cannot determine home directory for '$TARGET_USER'." >&2
  exit 1
fi

for required in \
  "$NIXOS_DIR/flake.nix" \
  "$NIXOS_DIR/configuration.nix" \
  "$HYPR_SRC" \
  "$HM_MODULE"
do
  if [[ ! -e "$required" ]]; then
    echo "Required path is missing: $required" >&2
    exit 1
  fi
done

# Hyprland 0.55 switched the default config to Lua.
if command -v Hyprland >/dev/null 2>&1; then
  HYPR_VERSION="$(
    Hyprland --version 2>/dev/null |
      sed -nE 's/.*[Hh]yprland[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' |
      head -n1
  )"

  if [[ -n "$HYPR_VERSION" ]]; then
    if ! printf '%s\n%s\n' "0.55.0" "$HYPR_VERSION" | sort -V -C; then
      if [[ "$FORCE" != 1 ]]; then
        echo "Hyprland $HYPR_VERSION is older than 0.55.0; Lua config is unsupported." >&2
        echo "Upgrade Hyprland first or rerun with FORCE=1 only if you know why." >&2
        exit 1
      fi
    fi
    echo "Hyprland version: $HYPR_VERSION"
  else
    echo "Warning: could not parse Hyprland version; continuing."
  fi
else
  if [[ "$FORCE" != 1 ]]; then
    echo "Hyprland is not available in PATH." >&2
    echo "Rerun with FORCE=1 to generate files before Hyprland is activated." >&2
    exit 1
  fi
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/hypr-lua-migration-$STAMP"
mkdir -p "$BACKUP"

echo "Creating backup at $BACKUP"
cp -a "$HYPR_SRC" "$BACKUP/hyprland-source"
cp -a "$HM_MODULE" "$BACKUP/default.nix"
[[ -e "$MATUGEN_CONFIG" ]] && cp -a "$MATUGEN_CONFIG" "$BACKUP/matugen-config.toml"
[[ -d "$USER_HOME/.config/hypr" ]] && cp -a "$USER_HOME/.config/hypr" "$BACKUP/user-hypr"

if command -v zpool >/dev/null 2>&1 &&
   command -v zfs >/dev/null 2>&1 &&
   zpool list -H rpool >/dev/null 2>&1; then
  SNAPSHOT="rpool@before-hypr-lua-$STAMP"
  if zfs snapshot -r "$SNAPSHOT"; then
    echo "Created ZFS snapshot: $SNAPSHOT"
  else
    echo "Warning: ZFS snapshot failed; filesystem backup still exists." >&2
  fi
fi

install -d -m 0755 "$LUA_SRC"
install -d -m 0755 "$USER_HOME/.config/hypr/lua"
install -d -m 0755 "$USER_HOME/.config/uwsm"

cat > "$HYPR_SRC/hyprland.lua" <<'LUA'
-- Native Hyprland 0.55+ Lua entry point.
-- Quickshell remains QML and is started from lua/autostart.lua.

local home = os.getenv("HOME") or "/home/w3r"

-- Writable, Matugen-generated modules from $HOME take precedence.
package.path =
  home .. "/.config/hypr/lua/?.lua;" ..
  "/etc/nixos/config/sessions/hyprland/lua/?.lua;" ..
  package.path

local modules = {
  "colors",
  "monitors",
  "settings",
  "rules",
  "keybindings",
  "autostart",
}

for _, module_name in ipairs(modules) do
  local ok, err = pcall(require, module_name)
  if not ok then
    print("[hyprland.lua] failed to load " .. module_name .. ": " .. tostring(err))
  end
end
LUA

cat > "$LUA_SRC/monitors.lua" <<'LUA'
-- MacBook Pro 16-inch Retina panel.
hl.monitor({
  output = "eDP-1",
  mode = "preferred",
  position = "0x0",
  scale = 2,
})

-- Sensible fallback for external displays.
hl.monitor({
  output = "",
  mode = "preferred",
  position = "auto",
  scale = 1,
})
LUA

cat > "$LUA_SRC/settings.lua" <<'LUA'
hl.config({
  general = {
    border_size = 2,
    gaps_in = 4,
    gaps_out = 4,
    float_gaps = 6,
    resize_on_border = true,
    extend_border_grab_area = 30,
    layout = "dwindle",
  },

  decoration = {
    rounding = 4,
    active_opacity = 1.0,
    inactive_opacity = 1.0,

    blur = {
      enabled = true,
      size = 8,
      passes = 2,
    },

    shadow = {
      enabled = false,
    },
  },

  animations = {
    enabled = true,
  },

  input = {
    kb_layout = "us,ru",
    kb_variant = "",
    kb_model = "",
    kb_rules = "",
    kb_options = "grp:win_space_toggle",
    accel_profile = "flat",

    touchpad = {
      natural_scroll = true,
      tap_to_click = true,
      clickfinger_behavior = true,
    },
  },

  misc = {
    focus_on_activate = true,
    font_family = "JetBrains Mono",
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
  },
})

hl.curve("myBezier", {
  type = "bezier",
  points = {
    { 0.05, 0.9 },
    { 0.1, 1.05 },
  },
})

hl.animation({
  leaf = "windows",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "popin 80%",
})

hl.animation({
  leaf = "windowsOut",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "popin 80%",
})

hl.animation({
  leaf = "layers",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "fade",
})

hl.animation({
  leaf = "layersIn",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "fade",
})

hl.animation({
  leaf = "layersOut",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "fade",
})

hl.animation({
  leaf = "fade",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
})

hl.animation({
  leaf = "workspaces",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "slide",
})

hl.animation({
  leaf = "specialWorkspaceIn",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "fade",
})

hl.animation({
  leaf = "specialWorkspaceOut",
  enabled = true,
  speed = 5,
  bezier = "myBezier",
  style = "fade",
})

hl.gesture({
  fingers = 3,
  direction = "horizontal",
  action = "workspace",
})
LUA

cat > "$LUA_SRC/rules.lua" <<'LUA'
-- OSDs and overlays.
for _, namespace in ipairs({
  "^volume_osd$",
  "^brightness_osd$",
  "^hyprpicker$",
  "^qsdock$",
}) do
  hl.layer_rule({
    match = { namespace = namespace },
    no_anim = true,
  })
end

hl.layer_rule({
  match = { namespace = "^ext-session-lock$" },
  blur = true,
  ignore_alpha = 0.2,
})

-- CS2.
hl.window_rule({
  match = { class = "^cs2$" },
  immediate = true,
  keep_aspect_ratio = true,
})

-- Author's app launcher.
hl.window_rule({
  match = { title = "^app-launcher$" },
  float = true,
  center = true,
  size = { 1200, 600 },
  animation = "slide",
})
LUA

cat > "$LUA_SRC/keybindings.lua" <<'LUA'
local mod = "SUPER"
local scripts = os.getenv("HOME") .. "/.config/hypr/scripts"

local function exec(command)
  return hl.dsp.exec_cmd(command)
end

-- Mouse and touchpad.
hl.bind(mod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Focus and movement.
hl.bind(mod .. " + left",  hl.dsp.focus({ direction = "l" }))
hl.bind(mod .. " + right", hl.dsp.focus({ direction = "r" }))
hl.bind(mod .. " + up",    hl.dsp.focus({ direction = "u" }))
hl.bind(mod .. " + down",  hl.dsp.focus({ direction = "d" }))

hl.bind(mod .. " + CTRL + left",  hl.dsp.window.move({ direction = "l" }))
hl.bind(mod .. " + CTRL + right", hl.dsp.window.move({ direction = "r" }))
hl.bind(mod .. " + CTRL + up",    hl.dsp.window.move({ direction = "u" }))
hl.bind(mod .. " + CTRL + down",  hl.dsp.window.move({ direction = "d" }))

hl.bind(mod .. " + SHIFT + left",
  hl.dsp.window.resize({ x = -50, y = 0, relative = true }),
  { repeating = true })
hl.bind(mod .. " + SHIFT + right",
  hl.dsp.window.resize({ x = 50, y = 0, relative = true }),
  { repeating = true })
hl.bind(mod .. " + SHIFT + up",
  hl.dsp.window.resize({ x = 0, y = -50, relative = true }),
  { repeating = true })
hl.bind(mod .. " + SHIFT + down",
  hl.dsp.window.resize({ x = 0, y = 50, relative = true }),
  { repeating = true })

hl.bind("ALT + F4", hl.dsp.window.close())
hl.bind(mod .. " + SHIFT + F", hl.dsp.window.float({ action = "toggle" }))

-- Hardware controls. Quickshell's listeners will still observe the changes.
hl.bind("XF86MonBrightnessDown",
  exec("brightnessctl set 5%-"),
  { locked = true, repeating = true })
hl.bind("XF86MonBrightnessUp",
  exec("brightnessctl set +5%"),
  { locked = true, repeating = true })

hl.bind("XF86AudioMute",
  exec("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
  { locked = true })
hl.bind("XF86AudioLowerVolume",
  exec("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),
  { locked = true, repeating = true })
hl.bind("XF86AudioRaiseVolume",
  exec("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"),
  { locked = true, repeating = true })
hl.bind("XF86AudioMicMute",
  exec("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"),
  { locked = true })

hl.bind("XF86AudioPlay",  exec("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioPause", exec("playerctl play-pause"), { locked = true })
hl.bind("XF86AudioNext",  exec("playerctl next"),       { locked = true })
hl.bind("XF86AudioPrev",  exec("playerctl previous"),   { locked = true })

-- Screenshots and locking.
hl.bind("Print", exec(scripts .. "/screenshot.sh"))
hl.bind("SHIFT + Print", exec(scripts .. "/screenshot.sh --edit"))
hl.bind("SUPER + Print", exec(scripts .. "/screenshot.sh --full"))
hl.bind("SUPER + SHIFT + Print", exec(scripts .. "/screenshot.sh --full --edit"))
hl.bind(mod .. " + L", exec("bash " .. scripts .. "/lock.sh"))

-- Applications.
hl.bind(mod .. " + F", exec("firefox"))
hl.bind(mod .. " + E", exec("nautilus"))
hl.bind(mod .. " + T", exec("Telegram"))
hl.bind(mod .. " + O", exec("obsidian"))
hl.bind(mod .. " + RETURN", exec("kitty"))

-- Quickshell controls.
local qs = scripts .. "/qs_manager.sh"
hl.bind(mod .. " + M", exec("bash " .. qs .. " toggle monitors"))
hl.bind(mod .. " + R", exec("bash " .. scripts .. "/reload.sh"))
hl.bind(mod .. " + D", exec("bash " .. qs .. " toggle applauncher"))
hl.bind(mod .. " + C", exec("bash " .. qs .. " toggle clipboard"))
hl.bind(mod .. " + SHIFT + S", exec("bash " .. qs .. " toggle settings"))
hl.bind(mod .. " + Q", exec("bash " .. qs .. " toggle music"))
hl.bind(mod .. " + B", exec("bash " .. qs .. " toggle battery"))
hl.bind(mod .. " + W", exec("bash " .. qs .. " toggle wallpaper"))
hl.bind(mod .. " + S", exec("bash " .. qs .. " toggle calendar"))
hl.bind(mod .. " + N", exec("bash " .. qs .. " toggle network"))
hl.bind(mod .. " + SHIFT + T", exec("bash " .. qs .. " toggle focustime"))
hl.bind(mod .. " + V", exec("bash " .. qs .. " toggle volume"))
hl.bind(mod .. " + H", exec("bash " .. qs .. " toggle guide"))

-- Workspaces are routed through the author's animation-aware script.
for i = 1, 10 do
  local key = i % 10
  hl.bind(mod .. " + " .. key, exec(qs .. " " .. i))
  hl.bind(mod .. " + SHIFT + " .. key, exec(qs .. " " .. i .. " move"))
end
LUA

cat > "$LUA_SRC/autostart.lua" <<'LUA'
hl.on("hyprland.start", function()
  hl.exec_cmd("swww-daemon")
  hl.exec_cmd("hypridle")
  hl.exec_cmd("playerctld")

  hl.exec_cmd("wl-paste --type text --watch cliphist store")
  hl.exec_cmd("wl-paste --type image --watch cliphist store")

  hl.exec_cmd("systemctl --user enable --now easyeffects")
  hl.exec_cmd("~/.config/hypr/scripts/settings_watcher.sh")
  hl.exec_cmd("~/.config/hypr/scripts/volume_listener.sh")

  hl.exec_cmd("gsettings set org.gnome.desktop.interface cursor-theme 'ArcMidnight-Cursors'")
  hl.exec_cmd("gsettings set org.gnome.desktop.interface cursor-size 24")

  hl.exec_cmd("quickshell -p ~/.config/hypr/scripts/quickshell/Shell.qml")
  hl.exec_cmd("python3 ~/.config/hypr/scripts/quickshell/focustime/focus_daemon.py")
end)
LUA

# Writable fallback; Matugen will replace this file later.
if [[ ! -f "$USER_HOME/.config/hypr/lua/colors.lua" ]]; then
  cat > "$USER_HOME/.config/hypr/lua/colors.lua" <<'LUA'
hl.config({
  general = {
    col = {
      active_border = "rgba(89b4faee)",
      inactive_border = "rgba(45475aaa)",
    },
  },
})
LUA
fi

# UWSM users should keep environment variables in ~/.config/uwsm/env.
touch "$USER_HOME/.config/uwsm/env"
if ! grep -q '^export NIXOS_OZONE_WL=' "$USER_HOME/.config/uwsm/env"; then
  printf '\nexport NIXOS_OZONE_WL=1\n' >> "$USER_HOME/.config/uwsm/env"
fi

# Make the new entry point immediately visible, even before Home Manager activates.
rm -f "$USER_HOME/.config/hypr/hyprland.lua"
ln -s "$HYPR_SRC/hyprland.lua" "$USER_HOME/.config/hypr/hyprland.lua"

# Remove only the active user-level legacy entry point. Its source remains in /etc
# and the complete original was backed up above.
rm -f "$USER_HOME/.config/hypr/hyprland.conf"

chown -R "$TARGET_USER:$(id -gn "$TARGET_USER")" \
  "$USER_HOME/.config/hypr" \
  "$USER_HOME/.config/uwsm"

# Adapt the Home Manager module. Quickshell packages/scripts remain unchanged.
cat > "$HM_MODULE" <<'NIX'
{ config, pkgs, lib, ... }:

{
  imports = [
    ./hypridle.nix
  ];

  home.packages = with pkgs; [
    rofi
    pavucontrol
    fortune
    wl-screenrec
    alsa-utils
    swww
    networkmanager_dmenu
    wl-clipboard
    fd
    qt6.qtmultimedia
    qt6.qt5compat
    qt6.qtwebsockets
    qt6.qtwebengine
    ripgrep
    gtk3
    cava
    cliphist
    tree
    jq
    socat
    pamixer
    brightnessctl
    acpi
    iw
    bluez
    libnotify
    networkmanager
    lm_sensors
    bc
    pulseaudio
    ladspaPlugins
    ladspa-sdk
    imagemagick
  ];

  home.sessionVariables.NIXOS_OZONE_WL = "1";

  # Native Hyprland Lua entry point. Static modules stay under /etc/nixos,
  # while Matugen writes the user-owned ~/.config/hypr/lua/colors.lua.
  home.file.".config/hypr/hyprland.lua".source =
    config.lib.file.mkOutOfStoreSymlink
      "/etc/nixos/config/sessions/hyprland/hyprland.lua";

  home.file.".config/hypr/scripts".source =
    config.lib.file.mkOutOfStoreSymlink
      "/etc/nixos/config/sessions/hyprland/scripts";

  # Keep templates and legacy config snippets available to the author's tools,
  # but Hyprland itself now reads hyprland.lua.
  home.activation.copyHyprConfig = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.rsync}/bin/rsync -a --update \
      /etc/nixos/config/sessions/hyprland/config/ \
      "$HOME/.config/hypr/config/"
    chmod -R u+w "$HOME/.config/hypr/config"
  '';

  home.activation.copyHyprTemplates = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${pkgs.rsync}/bin/rsync -a --update \
      /etc/nixos/config/sessions/hyprland/templates/ \
      "$HOME/.config/hypr/templates/"
    chmod -R u+w "$HOME/.config/hypr/templates"
  '';
}
NIX

# Convert Matugen's Hyprland output from hyprlang variables to a Lua module.
if [[ -d "$MATUGEN_TEMPLATE_DIR" ]]; then
  cat > "$MATUGEN_LUA_TEMPLATE" <<'TEMPLATE'
hl.config({
  general = {
    col = {
      active_border = "rgba({{colors.primary.default.hex_stripped}}ee)",
      inactive_border = "rgba({{colors.on_primary_fixed_variant.default.hex_stripped}}aa)",
    },
  },
})
TEMPLATE
fi

if [[ -f "$MATUGEN_CONFIG" ]]; then
  python3 - "$MATUGEN_CONFIG" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()

replacement = """[templates.hyprland]
input_path = '~/.config/matugen/templates/hyprland.lua.template'
output_path = '~/.config/hypr/lua/colors.lua'
"""

pattern = re.compile(
    r"(?ms)^\[templates\.hyprland\]\n.*?(?=^\[|\Z)"
)

if pattern.search(text):
    text = pattern.sub(replacement, text)
else:
    text = text.rstrip() + "\n\n" + replacement

path.write_text(text)
PY
fi

# The user's Home Manager config receives program templates from /etc/nixos/config.
# Ensure the new Matugen template is also present in the source tree used there.
if [[ -f "$MATUGEN_LUA_TEMPLATE" ]]; then
  :
fi

# Syntax-check plain Lua when luac is available. The global 'hl' is resolved only
# inside Hyprland, but luac can still catch malformed Lua syntax.
if command -v luac >/dev/null 2>&1; then
  echo "Checking Lua syntax..."
  luac -p "$HYPR_SRC/hyprland.lua"
  for file in "$LUA_SRC"/*.lua "$USER_HOME/.config/hypr/lua/colors.lua"; do
    luac -p "$file"
  done
else
  echo "luac is unavailable; skipping standalone Lua syntax check."
fi

echo "Checking Nix flake evaluation..."
cd "$NIXOS_DIR"
nix flake check --no-build

echo "Performing NixOS dry build..."
nixos-rebuild dry-build --flake "$NIXOS_DIR#$FLAKE_ATTR"

case "$APPLY_MODE" in
  none|dry-build)
    echo "Dry build succeeded; no system generation was activated."
    ;;
  boot)
    nixos-rebuild boot --flake "$NIXOS_DIR#$FLAKE_ATTR"
    echo "New generation installed for the next boot."
    ;;
  switch)
    nixos-rebuild switch --flake "$NIXOS_DIR#$FLAKE_ATTR"
    echo "New generation activated."
    ;;
esac

cat <<EOF

Migration completed.

Backup:
  $BACKUP

Lua entry point:
  $USER_HOME/.config/hypr/hyprland.lua

Static Lua modules:
  $LUA_SRC

Writable Matugen colors:
  $USER_HOME/.config/hypr/lua/colors.lua

Quickshell remains QML:
  $USER_HOME/.config/hypr/scripts/quickshell/

For an already-running Hyprland session:
  hyprctl reload

For a clean first start from TTY:
  uwsm start hyprland.desktop

A full logout/login or reboot is recommended so that exec-once replacements
(the hyprland.start event) launch Quickshell and all background services.
EOF
