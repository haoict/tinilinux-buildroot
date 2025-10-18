#!/bin/bash
#sudo nmui

# Copyright (c) 2021
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public
# License as published by the Free Software Foundation; either
# version 2 of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public
# License along with this program; if not, write to the
# Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
# Boston, MA 02110-1301 USA
#
# Authored by: Kris Henriksen <krishenriksen.work@gmail.com>
# Thanks to Quack for modifications to account for SSIDs with spaces
#
# Wi-Fi-dialog
#

export TERM=linux
export XDG_RUNTIME_DIR=/run/user/$UID/

## hack: since we have getty3 (buildroot login promt), it will interfere with dialog, so we need to use an empty tty (3)
chvt 3

sudo chmod 666 /dev/tty3
reset

# hide cursor
printf "\e[?25l" >/dev/tty3
dialog --clear
printf "\033c" >/dev/tty3
printf "Starting Wifi Manager.  Please wait..." >/dev/tty3

height="15"
width="55"

old_ifs="$IFS"

###################################
# Wifi functions
###################################
CURRENT_CONNECTED_SSID=""
getCurrentConnectedSSID() {
  CURRENT_CONNECTED_SSID=$(iw dev wlan0 info | grep ssid | cut -c 7-30)
  if [[ -z $CURRENT_CONNECTED_SSID ]]; then
    CURRENT_CONNECTED_SSID=$(nmcli -t -f name,device connection show --active | grep wlan0 | cut -d\: -f1)
  fi
}

deleteConnection() {

  dialog --clear --title "Removing $1" --clear \
    --yesno "\nWould you like to continue to remove this connection?" $height $width 2>&1 >/dev/tty3
  if [[ $? != 0 ]]; then
    chvt 1
    exit 1
  fi
  case $? in
  0) sudo rm -f "/etc/NetworkManager/system-connections/$1.nmconnection" ;;
  esac

  DeleteMenu
}

connectExisting() {
  getCurrentConnectedSSID

  dialog --infobox "\nConnecting to: $1 ..." 5 $width >/dev/tty3

  nmcli con down "$CURRENT_CONNECTED_SSID" >>/dev/null
  sleep 1

  output=$(nmcli con up "$1")

  success=$(echo "$output" | grep successfully)

  if [ -z "$success" ]; then
    dialog --infobox "\nFailed to connect to $1" 6 $width >/dev/tty3
    sleep 3
    ActivateExistingMenu
  else
    NetworkInfo "Device successfully activated and connected to: "
    MainMenu
  fi
}

makeConnection() {
  ps aux | grep gptokeyb2 | grep -v grep | awk '{print $1}' | xargs kill -9
  # get password from input
  LD_LIBRARY_PATH=/usr/local/lib /usr/local/bin/SimpleTerminal -d "/usr/local/bin/enter-wifi-password.sh"
  PASS=$(cat /tmp/wifi-password.txt)
  rm -f /tmp/wifi-password.txt
  /usr/local/bin/gptokeyb2 -1 "Wifi.sh" -c "/root/gptokeyb2.ini" >/dev/null &

  dialog --infobox "\nConnecting to: $1 ..." 5 $width >/dev/tty3
  clist2=$(sudo nmcli -f ALL --mode tabular --terse --fields IN-USE,SSID,CHAN,SIGNAL,SECURITY dev wifi)
  WPA3=$(echo "$clist2" | grep "$1" | grep "WPA3")

  # try to connect
  output=$(nmcli con delete "$1")
  if [[ "$WPA3" != *"WPA3"* ]]; then
    output=$(nmcli device wifi connect "$1" password "$PASS")
  else
    #workaround for wpa2/wpa3 connectivity
    output=$(nmcli device wifi connect "$1" password "$PASS")
    sudo sed -i '/key-mgmt\=sae/s//key-mgmt\=wpa-psk/' /etc/NetworkManager/system-connections/"$1".nmconnection
    sudo systemctl restart NetworkManager
    sleep 5
    output=$(nmcli con up "$1")
  fi
  success=$(echo "$output" | grep successfully)

  if [ -z "$success" ]; then
    sudo rm -f /etc/NetworkManager/system-connections/"$1".nmconnection
    dialog --infobox "\nActivation failed: Secrets were required, but not provided!" 6 $width >/dev/tty3
    sleep 3
    MainMenu
  else
    NetworkInfo "Device successfully activated and connected to: "
    MainMenu
  fi
}

###################################
# Menu
###################################
MainMenu() {
  if [[ "$(tr -d '\0' </proc/device-tree/compatible)" == *"rk3566"* ]] || [[ "$(tr -d '\0' </proc/device-tree/compatible)" == *"h700"* ]]; then
    if [[ ! -z $(rfkill -n -o TYPE,SOFT | grep wlan | grep -w unblocked) ]]; then
      local Wifi_Stat="On"
      local Wifi_MStat="Off"
    else
      local Wifi_Stat="Off"
      local Wifi_MStat="On"
      mainMenuTitle="Wifi Disabled"
    fi

    mainoptions=(1 "Turn Wifi $Wifi_MStat (Currently: $Wifi_Stat)" 2 "Connect to new Wifi connection" 3 "Activate existing Wifi Connection" 4 "Delete exiting connections" 5 "Current Network Info" 6 "Change Country Code" 7 "Exit")
  else
    mainoptions=(2 "Connect to new Wifi connection" 3 "Activate existing Wifi Connection" 4 "Delete exiting connections" 5 "Current Network Info" 6 "Change Country Code" 7 "Exit")
  fi

  if [ $Wifi_Stat == "On" ]; then
    getCurrentConnectedSSID
    if [[ -z $CURRENT_CONNECTED_SSID ]]; then
      mainMenuTitle="Not connected"
    else
      mainMenuTitle="Currently connected to \"$CURRENT_CONNECTED_SSID\""
    fi
  fi


  IFS="$old_ifs"
  while true; do
    mainselection=(dialog --backtitle "Wifi Manager: $mainMenuTitle"
      --title "Main Menu"
      --no-collapse
      --clear
      --cancel-label "Exit"
      --menu "Please make your selection" $height $width 15)

    mainchoices=$("${mainselection[@]}" "${mainoptions[@]}" 2>&1 >/dev/tty3)
    if [[ $? != 0 ]]; then
      chvt 1
      exit 1
    fi
    for mchoice in $mainchoices; do
      case $mchoice in
      1) ToggleWifi $Wifi_MStat ;;
      2) ScanAndConnectMenu ;;
      3) ActivateExistingMenu ;;
      4) DeleteMenu ;;
      5) NetworkInfo ;;
      6) CountryMenu ;;
      7) ExitMenu ;;
      esac
    done
  done
}

ToggleWifi() {
  dialog --infobox "\nTurning Wifi $1, please wait..." 5 $width >/dev/tty3
  if [[ ${1} == "Off" ]]; then
    sudo systemctl stop NetworkManager &
    sudo systemctl disable NetworkManager &
    sudo rfkill block wlan
  else
    sudo rfkill unblock wlan
    sudo systemctl enable NetworkManager
    sudo systemctl start NetworkManager
    sleep 5
  fi
  MainMenu
}

ActivateExistingMenu() {
  declare aoptions=()
  while IFS= read -r -d $'\n' ssid; do
    aoptions+=("$ssid" ".")
  done < <(ls -1 /etc/NetworkManager/system-connections/ | sed 's/.\{13\}$//' | sed -e 's/$//')

  while true; do
    aselection=(dialog --title "Which existing connection would you like to connect to?"
      --no-collapse
      --clear
      --cancel-label "Back"
      --menu "" $height $width 15)

    achoice=$("${aselection[@]}" "${aoptions[@]}" 2>&1 >/dev/tty3) || MainMenu
    if [[ $? != 0 ]]; then
      chvt 1
      exit 1
    fi

    # There is only one choice possible
    connectExisting "$achoice"
  done
}

ScanAndConnectMenu() {
  dialog --infobox "\nScanning available Wi-Fi access points..." 5 $width >/dev/tty3
  clist=$(sudo nmcli -f ALL --mode tabular --terse --fields IN-USE,SSID,CHAN,SIGNAL,SECURITY dev wifi)
  if [ -z "$clist" ]; then
    clist=$(sudo nmcli -f ALL --mode tabular --terse --fields IN-USE,SSID,CHAN,SIGNAL,SECURITY dev wifi)
  fi
  getCurrentConnectedSSID

  # Set colon as the delimiter
  IFS=':'
  unset coptions
  while IFS= read -r clist; do
    # Read the split words into an array based on colon delimiter
    read -a strarr <<<"$clist"

    INUSE=$(printf '%-5s' "${strarr[0]}")
    SSID="${strarr[1]}"
    CHAN=$(printf '%-5s' "${strarr[2]}")
    SIGNAL=$(printf '%-5s' "${strarr[3]}%")
    SECURITY="${strarr[4]}"

    coptions+=("$SSID" "$INUSE $CHAN $SIGNAL $SECURITY")
  done <<<"$clist"

  while true; do
    cselection=(dialog --title "SSID  IN-USE  CHANNEL  SIGNAL  SECURITY"
      --no-collapse
      --clear
      --cancel-label "Back"
      --menu "" $height $width 15)

    cchoices=$("${cselection[@]}" "${coptions[@]}" 2>&1 >/dev/tty3) || MainMenu
    if [[ $? != 0 ]]; then
      chvt 1
      exit 1
    fi

    for cchoice in $cchoices; do
      case $cchoice in
      *) makeConnection $cchoice ;;
      esac
    done
  done
}

DeleteMenu() {
  declare deloptions=()
  while IFS= read -r -d $'\n' ssid; do
    deloptions+=("$ssid" ".")
  done < <(ls -1 /etc/NetworkManager/system-connections/ | sed 's/.\{13\}$//' | sed -e 's/$//')

  while true; do
    delselection=(dialog
      --title "Which connection would you like to delete?"
      --no-collapse
      --clear
      --cancel-label "Back"
      --menu "" $height $width 15)

    # There is only a single choice possible
    delchoice=$("${delselection[@]}" "${deloptions[@]}" 2>&1 >/dev/tty3) || MainMenu
    if [[ $? != 0 ]]; then
      chvt 1
      exit 1
    fi
    deleteConnection "$delchoice"
  done
}

NetworkInfo() {
  gateway=$(ip r | grep default | awk '{print $3}')
  currentip=$(ip -f inet addr show wlan0 | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')
  getCurrentConnectedSSID
  currentdns=$( (nmcli dev list || nmcli dev show) 2>/dev/null | grep DNS | awk '{print $2}')
  message=$1

  dialog --clear --title "Your Network Information" --clear \
    --msgbox "\n$message\nSSID: $CURRENT_CONNECTED_SSID\nIP: $currentip\nGateway: $gateway\nDNS: $currentdns" $height $width 2>&1 >/dev/tty3
  if [[ $? != 0 ]]; then
    chvt 1
    exit 1
  fi
}

CountryMenu() {

  cur_country=$(sudo iw reg get | grep country | cut -c 9-10)
  if [[ "$cur_country" == "00" ]]; then
    cur_country="WORLD"
  fi

  declare coptions=()
  coptions=("WORLD" . "US" . "DZ" . "AR" . "AU" . "AT" . "BH" . "BM" . "BO" . "BR" . "BG" . "CA" . "CL" . "CN" . "CO" . "CR" . "CY" . "CZ" . "DK" . "DO" . "EC" . "EG" . "SV" . "EE" . "FI" . "FR" . "DE" . "GR" . "GT" . "HN" . "HK" . "IS" . "IN" . "ID" . "IE" . "PK" . "IL" . "IT" . "JM" . "JP3" . "JO" . "KE" . "KW" . "KW" . "LB" . "LI" . "LI" . "LT" . "LT" . "LU" . "MU" . "MX" . "MX" . "MA" . "MA" . "NL" . "NZ" . "NZ" . "NO" . "OM" . "PA" . "PA" . "PE" . "PH" . "PL" . "PL" . "PT" . "PR" . "PR" . "QA" . "KR" . "RO" . "RU" . "RU" . "SA" . "CS" . "SG" . "SK" . "SK" . "SI" . "SI" . "ZA" . "ES" . "LK" . "CH" . "TW" . "TH" . "TH" . "TT" . "TN" . "TR" . "UA" . "AE" . "GB" . "UY" . "UY" . "VE" . "VN" .)

  while true; do
    cselection=(dialog
      --backtitle "Country currently set to $cur_country"
      --title "Which country would you like to set your wifi to?"
      --no-collapse
      --clear
      --cancel-label "Back"
      --menu "" $height $width 15)

    cchoice=$("${cselection[@]}" "${coptions[@]}" 2>&1 >/dev/tty3) || MainMenu
    if [[ $? != 0 ]]; then
      chvt 1
      exit 1
    fi

    # There is only one choice possible
    if [[ "$cchoice" == "WORLD" ]]; then
      sudo iw reg set 00
    else
      sudo iw reg set "$cchoice"
    fi
    CountryMenu
  done

}

ExitMenu() {
  printf "\033c" >/dev/tty3
  ps aux | grep gptokeyb2 | grep -v grep | awk '{print $1}' | xargs kill -9
  chvt 1
  exit 0
}

###################################
# Joystick controls (only one instance)
###################################
sudo chmod 666 /dev/uinput
export SDL_GAMECONTROLLERCONFIG_FILE="/root/gamecontrollerdb.txt"
if [[ ! -z $(ps aux | grep gptokeyb2 | grep -v grep | awk '{print $1}') ]]; then
  ps aux | grep gptokeyb2 | grep -v grep | awk '{print $1}' | xargs kill -9
fi
/usr/local/bin/gptokeyb2 -1 "Wifi.sh" -c "/usr/local/bin/Wifi-gptokeyb2.ini" >/dev/null 2>&1 &
printf "\033c" >/dev/tty3
dialog --clear
trap ExitMenu EXIT
MainMenu
