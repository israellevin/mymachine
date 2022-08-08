#!/bin/bash
set -e
mirror=${1:-http://deb.devuan.org/merged}
sources=("deb $mirror unstable main")
# deb http://deb.devuan.org/merged unstable main non-free contrib
# firmware-iwlwifi
# deb http://deb.devuan.org/merged stable main non-free contrib
# deb http://deb.devuan.org/merged stable-security main non-free contrib
# deb http://deb.devuan.org/merged stable-updates main non-free contrib
packages=(linux-image-amd64
bash-completion bc bsdmainutils chafa git less mc moreutils poppler-utils psmisc pv rsync tmux unzip vim
aria2 ca-certificates curl dhcpcd5 iproute2 iw netbase openssh-server sshfs w3m wget wpasupplicant
python3 python3-pip python3-venv
xinit xserver-xorg-input-libinput xserver-xorg-video-vesa
feh imagemagick mpv parcellite redshift)
binaries=(dmenu dmenu_run monsterwm st)
overlaydirs=(overlay)
user=user
password=pass

if ! pushd chroot; then
    echo creating tmpfs
    mkdir chroot
    mount -t tmpfs -o size=60% none chroot|| exit 1
    pushd chroot
fi

if [ ! -f sbin/init ]; then
    echo debootstrapping
    debootstrap --variant=minbase unstable . "$mirror"
    chroot . useradd $user -m
    chroot . addgroup wheel
    chroot . usermod -a -G wheel $user
    chroot . passwd -d root
    chroot . sh -c "yes $password | passwd $user"
fi

echo setting apt
for src in "${sources[@]}"; do
    echo "$src"
done > etc/apt/sources.list
echo 'APT::Install-Recommends "0";' > etc/apt/apt.conf.d/10no-recommends
echo 'APT::Install-Suggests "0";' > etc/apt/apt.conf.d/10no-suggests

echo installing packages
# Installs should not try to run any services.
mkdir -p fake
for bin in initctl invoke-rc.d restart start stop start-stop-daemon service; do
    ln -fs bin/true fake/$bin
done
chroot . apt update
PATH=/fake:$PATH DEBIAN_FRONTEND=noninteractive chroot . apt -y install "${packages[@]}"
chroot . apt clean
rm -rf fake

echo copy binaries
for binary in "${binaries[@]}"; do
    binpath="$(which "$binary")"
    cp "$binpath" "./$binpath"
done

echo copy overlays
for dir in "${overlaydirs[@]}"; do
    rsync -av "../$dir/" .
done

# Cleanup before creating archive.
rm -rf --one-file-system dev sys run proc tmp mnt
mkdir dev sys run proc
mkdir -m 777 tmp mnt
echo creating archive
tar --one-file-system --exclude=./boot -cf - . | pv -s "$(du -sb . | awk '{print $1}')" > /boot/mymachine.tar

echo copying kernel
for kernel in boot/vmlinuz*; do
    cp "$kernel" /boot/"$(basename $kernel)"-mymachine
done

echo patching and copying initrd
mkdir -p initrd
pushd initrd
for initrd in ../boot/initrd*; do
    cat "$initrd" | gunzip | cpio -i
    rm -rf --one-file-system lib/modules
    cp -a ../lib/modules lib/.
    cp "$(which pv)" 'bin/.'
    cp "$(which tar)" 'bin/.'
    cp ../../initrd.scripts.local.hack scripts/local
    find . -mount | cpio -o -H newc > /boot/"$(basename "$initrd")"-mymachine
done
popd
rm -rf --one-file-system initrd
