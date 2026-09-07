#!/bin/bash

set -e

# Config
DOOM_BIN="/usr/local/bin/fbdoom"
IWAD_DIR="/roms/doom"

# URLs (mirros)
URL_SHAREWARE="https://github.com/nneonneo/universal-doom/raw/refs/heads/main/DOOM1.WAD"
URL_ULTIMATE="https://github.com/Akbar30Bill/DOOM_wads/raw/refs/heads/master/doomu.wad"
URL_DOOM2="https://github.com/Akbar30Bill/DOOM_wads/raw/refs/heads/master/doom2.wad"
URL_PLUTONIA="https://github.com/Akbar30Bill/DOOM_wads/raw/refs/heads/master/plutonia.wad"
URL_TNT="https://github.com/Akbar30Bill/DOOM_wads/raw/refs/heads/master/tnt.wad"
URL_CHEX="https://github.com/Akbar30Bill/DOOM_wads/raw/refs/heads/master/chex.wad"

# --- functions ---
check_internet() {
  ping -c1 -W1 1.1.1.1 >/dev/null 2>&1
}

confirm_download() {
  dialog --yesno "IWAD not found:\n$1\n\nDownload it?" 10 50
}

validate_wad() {
  file "$1" | grep -qi "lumps"
}

error_box() {
  dialog --msgbox "$1" 8 50
}

# --- menu ---
CHOICE=$(dialog --clear \
  --title "DOOM Launcher" \
  --menu "Choose DOOM version:" 13 43 7 \
  1 "DOOM Shareware" \
  2 "DOOM I : The Ultimate Doom" \
  3 "DOOM II: Hell on Earth" \
  4 "DOOM II: The Plutonia Experiment" \
  5 "DOOM II: TNT: Evilution" \
  6 "Chex: Quest" \
  2>&1 >/dev/tty)

[ $? -ne 0 ] && clear && exit 0

case "$CHOICE" in
  1) IWAD="$IWAD_DIR/DOOM1.WAD"; URL="$URL_SHAREWARE" ;;
  2) IWAD="$IWAD_DIR/DOOMU.WAD"; URL="$URL_ULTIMATE" ;;
  3) IWAD="$IWAD_DIR/DOOM2.WAD"; URL="$URL_DOOM2" ;;
  4) IWAD="$IWAD_DIR/PLUTONIA.WAD"; URL="$URL_PLUTONIA" ;;
  5) IWAD="$IWAD_DIR/TNT.WAD"; URL="$URL_TNT" ;;
  6) IWAD="$IWAD_DIR/CHEX.WAD"; URL="$URL_CHEX" ;;
  *) clear; exit 0 ;;
esac

# --- download if missing ---
if [ ! -f "$IWAD" ]; then

  confirm_download "$IWAD"
  [ $? -ne 0 ] && clear && exit 0

  if ! check_internet; then
    error_box "No internet connection."
    clear
    exit 1
  fi

  mkdir -p "$IWAD_DIR"
  wget -O "$IWAD" "$URL" 2>&1 | dialog --progressbox "Downloading..." 10 70
fi

# --- validate wad ---
if ! validate_wad "$IWAD"; then
  error_box "Invalid WAD file: $IWAD.\nDeleting it..."
  rm -f "$IWAD"
  clear
  exit 1
fi

# --- launch ---
clear
echo "Launching DOOM with $IWAD..."
exec "$DOOM_BIN" -iwad "$IWAD" "$@"
