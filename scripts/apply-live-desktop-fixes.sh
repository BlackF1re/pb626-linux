#!/bin/sh
# Apply the desktop isolation and compatible keyboard layout to a running
# Debian PB626 without rebuilding the kernel or native client binaries.
# Run as root from a checkout of the repository.
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "Run this script as root." >&2
    exit 1
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xsession_src="$repo/display/pb626-xsession"
layout_src="$repo/display/keyboard-us.xml"
gtk_css_src="$repo/display/gtk.css"
gtk_css_dest="/home/reader/.config/gtk-3.0/gtk.css"
test -f /etc/debian_version || { echo "This live patch targets the Debian runtime." >&2; exit 1; }
test -x /usr/libexec/pb626/bin/matchbox-keyboard || {
    echo "PB626's private Matchbox Keyboard binary is missing." >&2
    exit 1
}
test -s "$xsession_src"
test -s "$layout_src"
test -s "$gtk_css_src"
id reader >/dev/null 2>&1 || { echo "The Debian reader account is missing." >&2; exit 1; }
bash -n "$xsession_src"
python3 "$repo/tests/test-matchbox-keyboard-layout.py"

backup_dir="/var/backups/pb626-desktop-fixes-$(date +%Y%m%d-%H%M%S)"
install -d -m 700 "$backup_dir"
if [ -e /usr/bin/pb626-xsession ]; then
    cp -a /usr/bin/pb626-xsession "$backup_dir/pb626-xsession"
fi
if [ -e /usr/share/pb626/matchbox-keyboard/keyboard-us.xml ]; then
    cp -a /usr/share/pb626/matchbox-keyboard/keyboard-us.xml "$backup_dir/keyboard-us.xml"
fi
if [ -e "$gtk_css_dest" ]; then
    cp -a "$gtk_css_dest" "$backup_dir/gtk.css"
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
# Debian /bin/sh is dash; PB626's xsession uses Bash wait -n.
sed '1s|^#!/bin/sh$|#!/bin/bash|' "$xsession_src" > "$tmp"
install -D -m 755 "$tmp" /usr/bin/pb626-xsession
install -D -m 644 "$layout_src" /usr/share/pb626/matchbox-keyboard/keyboard-us.xml
install -d -o reader -g reader -m 755 "$(dirname "$gtk_css_dest")"
install -m 644 "$gtk_css_src" "$gtk_css_dest"
chown reader:reader "$gtk_css_dest"

systemctl reset-failed pb626-desktop.service || :
if ! systemctl restart pb626-desktop.service; then
    systemctl --no-pager --full status pb626-desktop.service || :
    journalctl -u pb626-desktop.service -n 80 --no-pager || :
    echo "Desktop restart failed; backups are in $backup_dir" >&2
    exit 1
fi
if ! systemctl is-active --quiet pb626-desktop.service; then
    systemctl --no-pager --full status pb626-desktop.service || :
    journalctl -u pb626-desktop.service -n 80 --no-pager || :
    echo "Desktop did not remain active; backups are in $backup_dir" >&2
    exit 1
fi
echo "PB626 live desktop fixes installed. Backup: $backup_dir"
