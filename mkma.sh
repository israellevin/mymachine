#!/bin/bash

chrootdir=${1:-chroot}
mirror=${2:-http://ftp.debian.org/debian}
targetdir=${3:-"$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"}

if ! pushd "$chrootdir"; then
    echo creating tmpfs
    mkdir "$chrootdir"
    mount -t tmpfs -o size=60% none "$chrootdir" || exit 1
    pushd "$chrootdir"
fi

if [ ! -f sbin/init ]; then
    echo debootstrapping
    debootstrap --variant=minbase sid . "$mirror"
    chroot . adduser i
    chroot . addgroup wheel
    chroot . adduser i wheel
    chroot . passwd -d root
fi

# You can add more sources.
sources[0]="$mirror sid main"
packages=linux-image-686-pae
packages="$packages bash-completion bc bsdmainutils git mc moreutils poppler-utils psmisc sensord tmux unzip vim"
packages="$packages aria2 ca-certificates curl openssh-server sshfs w3m wget"
packages="$packages dhcpcd5 netbase wireless-tools wpasupplicant"
packages="$packages alsa-base alsa-utils mpc mpd mpv"
packages="$packages python3 python3-pip python3-venv"
packages="$packages xinit xserver-xorg xserver-xorg-input-kbd xserver-xorg-video-vesa"
packages="$packages x11-xserver-utils xautomation xdotool"
packages="$packages clipit feh imagemagick python-gtk2 python-imaging redshift rxvt-unicode-256color unclutter vim-gtk"
packages="$packages libwebkitgtk-3.0-dev xul-ext-adblock-plus xul-ext-firebug"
if (read -n 1 -p 'install packages? (y/N) ' q; echo; [ y = "$q" ]); then
    mkdir -p etc/apt
    echo 'APT::Get::Install-Recommends "0";' > etc/apt/apt.conf
    :> etc/apt/sources.list
    for src in "${sources[@]}"; do
        echo "deb $src" >> etc/apt/sources.list
    done
    chroot . mkdir /fake
    for bin in initctl invoke-rc.d restart start stop start-stop-daemon service; do
        chroot . ln -s /bin/true /fake/$bin
    done
    chroot . apt-get update
    PATH=/fake:$PATH chroot . apt-get -y install $packages
    rm -rf fake
fi

# You can add more overlay dirs.
overlaydirs[0]=overlay
if (read -n 1 -p 'Overlay? (y/N) ' q; echo; [ y = "$q" ]); then
    for dir in "${overlaydirs[@]}"; do
        rsync -av "../$dir/" .
    done
fi

gettarget(){
    if [ -d "$tr" ]; then
        read -n 1 -p "copy to $tr? (Y/n) " q; echo; echo
        [ n = "$q" ] || return 0
        tr=''
    else
        read -p "destination ($targetdir): " tr && [ "$tr" ] || tr="$targetdir"
    fi
    gettarget
}

if (read -n 1 -p 'copy tar? (y/N) ' q; echo; [ y = "$q" ]); then
    gettarget
    tar --one-file-system -cf - . | pv -s "$(du -sb . | awk '{print $1}')" > "$tr/mymachine.tar"
fi

exit 0
