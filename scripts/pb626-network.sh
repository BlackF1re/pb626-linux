#!/bin/sh
# RAM-only WPA Wi-Fi: automatically starts when /etc/pb626/wpa_supplicant.conf
# exists. Current published image uses a user-authorized disposable TEST network.
set -u
export PATH=/sbin:/bin:/usr/sbin:/usr/bin
CONF=/etc/pb626/wpa_supplicant.conf
LOG=/run/pb626-network.log
if [ ! -s "$CONF" ]; then
  echo 'pb626: no local WLAN credentials; skipping autoconnect' >> "$LOG"
  exit 0
fi
chmod 600 "$CONF" || exit 1
n=0
iface=
while [ "$n" -lt 25 ]; do
  iface=$(iw dev 2>/dev/null | awk '$1 == "Interface" {print $2;exit}')
  [ -n "$iface" ] && break
  n=$((n + 1))
  sleep 1
done
if [ -z "$iface" ]; then
  echo 'pb626: no WLAN interface after driver probe' >> "$LOG"
  exit 1
fi
echo "pb626: WLAN interface detected: $iface" >> "$LOG"
ip link set "$iface" up >> "$LOG" 2>&1 || exit 1
wpa_supplicant -B -i "$iface" -c "$CONF" -D nl80211 >> "$LOG" 2>&1 || exit 1
n=0
while [ "$n" -lt 30 ]; do
  if iw dev "$iface" link 2>/dev/null | grep -q '^Connected to '; then
    echo 'pb626: Wi-Fi associated; requesting DHCP' >> "$LOG"
    udhcpc -i "$iface" -q -n -t 5 -T 3 >> "$LOG" 2>&1
    exit $?
  fi
  n=$((n + 1))
  sleep 1
done
echo 'pb626: Wi-Fi association timed out' >> "$LOG"
exit 1
