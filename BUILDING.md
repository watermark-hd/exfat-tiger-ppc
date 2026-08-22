# Building from source

You need two machines for this (or one modern Mac plus a Tiger box over SSH, which is how it was actually done): Tiger's Xcode 2.5 doesn't ship `autoconf`/`automake`, so the autotools-generated `configure` script has to be produced somewhere else and copied over.

## 1. Build the CLI tools (fuse-exfat)

On a **modern Mac** (needs `autoconf`, `automake`, `pkg-config` — `brew install autoconf automake pkg-config`):

```sh
curl -L -o exfat.tar.gz https://github.com/relan/exfat/archive/refs/heads/master.tar.gz
tar xzf exfat.tar.gz
cd exfat-master
patch -p1 < ../patches/0001-tiger-macfuse-compat.patch
autoreconf -fiv
```

Copy the whole `exfat-master` directory (now containing a generated `configure` and `Makefile.in` files) to the Tiger machine.

On the **Tiger machine** (needs Xcode 2.5, and [MacFUSE Core 10.4-1.7.0](https://web.archive.org/web/20120127043005/http://macfuse.googlecode.com/files/MacFUSE-Core-10.4-1.7.0.dmg) installed):

```sh
find . -type f | xargs touch   # fix timestamps -- files will look "from the future" after transfer if Tiger's clock is behind
export FUSE2_CFLAGS="-I/usr/local/include/fuse -D__FreeBSD__=10 -D_FILE_OFFSET_BITS=64"
export FUSE2_LIBS="-L/usr/local/lib -lfuse"
./configure --prefix=/usr/local   # no pkg-config on Tiger, the FUSE2_* vars above skip needing it
make
make install   # or sudo, depending who owns /usr/local
```

The `patches/0001-tiger-macfuse-compat.patch` does two things, both needed for this specific old MacFUSE (1.7.0, year 2008) to work right — see the README's "Technical notes" section for why.

## 2. Build the menu bar app

No Xcode project, no nib file — it's three small Objective-C files, compiled directly. On the Tiger machine, with `src/` copied over:

```sh
cd src
gcc -Wall -framework Cocoa -o exFATMenu main.m AppDelegate.m
mkdir -p "exFAT Menu.app/Contents/MacOS" "exFAT Menu.app/Contents/Resources"
cp Info.plist "exFAT Menu.app/Contents/Info.plist"
cp exFATMenu "exFAT Menu.app/Contents/MacOS/exFATMenu"
cp ../icon/AppIcon.icns "exFAT Menu.app/Contents/Resources/AppIcon.icns"
printf 'APPL?xfa' > "exFAT Menu.app/Contents/PkgInfo"
```
