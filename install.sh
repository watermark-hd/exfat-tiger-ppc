#!/bin/sh
# Installs the exFAT command line tools into /usr/local/sbin.
# Run this from inside the extracted release folder: ./install.sh
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/bin"

if [ ! -d "$BIN" ]; then
	echo "Can't find bin/ next to this script. Run it from inside the extracted folder." >&2
	exit 1
fi

sudo mkdir -p /usr/local/sbin

for f in mount.exfat-fuse exfatfsck mkexfatfs exfatlabel dumpexfat exfatattrib; do
	sudo cp "$BIN/$f" /usr/local/sbin/
	sudo chmod 755 /usr/local/sbin/$f
done

sudo ln -sf mount.exfat-fuse /usr/local/sbin/mount.exfat
sudo ln -sf exfatfsck /usr/local/sbin/fsck.exfat
sudo ln -sf mkexfatfs /usr/local/sbin/mkfs.exfat

echo "Installed. Make sure MacFUSE Core 10.4-1.7.0 is installed too (see README),"
echo "then copy exFAT Menu.app wherever you like and open it."
