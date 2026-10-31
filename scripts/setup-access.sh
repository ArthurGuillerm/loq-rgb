#!/bin/sh
# setup-access.sh VID PID IFACE BUS NODE
#
# One-time setup run in a terminal by the LOQ RGB plugin: lets your *logged-in user session* (and nobody
# else) talk to your keyboard's *lighting* interface. It installs one udev rules file, shows you exactly what
# it writes, asks before doing anything, and finally checks that the device node really became accessible.
# It never touches the network.
#
#   VID PID  USB ids of the keyboard (4 hex digits each)
#   IFACE    USB interface number of the lighting interface (2 hex digits, required)
#   BUS      HID bus of the device; only USB (0003) is supported
#   NODE     the /dev/hidrawN node of the lighting interface, used for the final check
set -u

lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }
VID=$(lower "${1:-}")
PID=$(lower "${2:-}")
IFACE=$(lower "${3:-}")
BUS=$(lower "${4:-}")
NODE=${5:-}

valid4() { case "$1" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0 ;; esac; return 1; }
valid2() { case "$1" in [0-9a-f][0-9a-f]) return 0 ;; esac; return 1; }
pause() { printf '\nPress Enter to close this window... '; read -r _ || true; }
refuse() { printf '%s\nNothing was changed.\n' "$1"; pause; exit 1; }

valid4 "$VID" && valid4 "$PID" ||
  refuse "Invalid or missing USB ids (got VID='$VID' PID='$PID')."

# The rule must be limited to the lighting interface, otherwise it would also open the typing interface
# (raw keystrokes). If that interface cannot be identified, install nothing.
valid2 "$IFACE" ||
  refuse "Cannot identify the keyboard's lighting interface (got '$IFACE'). The rule has to be limited to
that interface so the typing interface stays private, so no rule is installed."

# bInterfaceNumber / idVendor only exist for USB devices.
[ "$BUS" = "0003" ] ||
  refuse "This automatic setup only supports USB keyboards (HID bus '$BUS'). See the plugin README for how
to write the rule by hand."

case "$NODE" in /dev/hidraw*) ;; *) refuse "Invalid device node '$NODE'." ;; esac
case "${NODE#/dev/hidraw}" in '' | *[!0-9]*) refuse "Invalid device node '$NODE'." ;; esac

FILE="/etc/udev/rules.d/70-noctalia-loq-rgb-$VID-$PID.rules"
VAR="NOCTALIA_LAMPARRAY_${VID}_${PID}"   # unique per device, so rule files cannot interfere with each other

# udev requires all the ATTRS/SUBSYSTEMS keys of ONE rule to match the SAME parent device. The interface
# number belongs to the USB interface and the ids to the USB device above it, so each gets its own rule and
# an environment variable links the two.
RULES="# Installed by the Noctalia \"LOQ RGB\" plugin
# 1) mark the HID node that belongs to USB interface $IFACE (the keyboard's lighting interface)
SUBSYSTEM==\"hidraw\", SUBSYSTEMS==\"usb\", ATTRS{bInterfaceNumber}==\"$IFACE\", ENV{$VAR}=\"1\"
# 2) and give the logged-in user access to it, only when it belongs to USB device $VID:$PID
SUBSYSTEM==\"hidraw\", ENV{$VAR}==\"1\", SUBSYSTEMS==\"usb\", ATTRS{idVendor}==\"$VID\", ATTRS{idProduct}==\"$PID\", TAG+=\"uaccess\""

cat <<MSG
LOQ RGB - one-time access setup

The plugin found a keyboard (USB $VID:$PID) whose lighting your user cannot control yet.
This will create:

  $FILE

containing:

$RULES

"uaccess" gives access to the user currently logged in at this computer, only to the lighting interface
($IFACE) of that keyboard; the typing interface is not touched. Delete the file to undo it at any time.

MSG

printf 'Install it now? [Y/n] '
read -r ANSWER || ANSWER=n
case "$ANSWER" in [nN]*) echo "Cancelled. Nothing was changed."; pause; exit 0 ;; esac

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  elif command -v pkexec >/dev/null 2>&1; then pkexec "$@"
  else echo "Neither sudo nor pkexec is available."; return 1
  fi
}

if ! {
  printf '%s\n' "$RULES" | as_root tee "$FILE" >/dev/null &&
    as_root udevadm control --reload &&
    as_root udevadm trigger --subsystem-match=hidraw --action=change
}; then
  echo
  echo "Setup did not complete (see the messages above). Nothing else was changed."
  pause; exit 1
fi

# Do not trust the commands above: check the result the way the plugin will use it.
echo
echo "Checking that $NODE is now accessible to you..."
i=0
while [ "$i" -lt 8 ]; do
  if [ -r "$NODE" ] && [ -w "$NODE" ]; then
    echo
    echo "Done: $NODE is accessible. The plugin will notice within a few seconds."
    pause; exit 0
  fi
  sleep 1
  i=$((i + 1))
done

echo
echo "The rules file was written, but $NODE is still not accessible to you."
echo "Things to try: log out and back in (the rule relies on your login session, systemd-logind),"
echo "or check that the node has the interface number $IFACE:  udevadm info -a -n $NODE"
echo "To undo: sudo rm $FILE"
pause; exit 1
