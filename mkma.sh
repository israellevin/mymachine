#!/bin/bash

mkchroot() {
    local packages="$(echo "$packages" | tr ' ' ',')"
    debootstrap --variant=minbase --components=main,contrib,non-free,firmware --include="$packages" sid .

    mkdir -p ./lib/modules
    cp -a /lib/modules/"$(uname -r)" ./lib/modules/

    mkdir -p ./etc/apt
    cat > ./etc/apt/apt.conf <<EOF
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF
}

install_packages() {
    local packages="locales $1"

    mkdir ./fake
    for binary in initctl invoke-rc.d restart start stop start-stop-daemon service; do
        ln -s ./bin/true ./fake/$binary
    done
    chroot . <<EOF
export PATH="/fake:\$PATH"
apt-get update
apt-get -y install $packages
apt clean
EOF
    rm -rf ./fake

    echo en_US.UTF-8 UTF-8 >> ./etc/locale.gen
    chroot . locale-gen || true
}

configure_user() {
    echo auth sufficient pam_wheel.so trust >> ./etc/pam.d/su
    chroot . <<EOF
groupadd wheel
useradd --create-home --user-group --shell "\$(type -p bash)" -G wheel i
passwd -d root
passwd -d i
EOF

    chroot . su -c '
        git clone https://github.com/israellevin/dotfiles.git ~/src/dotfiles
        ~/src/dotfiles/install.sh' i
}

mkinitramfs() {
    mkdir -p ./{proc,sys,dev,tmp,run}
    chmod 1777 ./tmp
    mknod -m 622 ./dev/console c 5 1 2>/dev/null || true
    mknod -m 666 ./dev/null c 1 3 2>/dev/null || true

    cat <<EOF > ./init
#!/bin/sh
echo Running custom init...

mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev

exec /sbin/init
EOF

    chmod +x ./init
    find . -mount -print0 | pv -0 -l -s "$(find . | wc -l)" | cpio --null -o -H newc
}

bootinitramfs() {
    local kernel_image="$1"
    local initramfs_image="$2"
    local ramdisk_size="${3:-4096}"

    if [ ! -f "$kernel_image" ]; then
        echo "Error: Kernel image $kernel_image not found."
        exit 1
    fi

    if [ ! -f "$initramfs_image" ]; then
        echo "Error: Initramfs image $initramfs_image not found."
        exit 1
    fi

    qemu-system-x86_64 -m "$ramdisk_size" \
        -kernel "$kernel_image" \
        -initrd "$initramfs_image" \
        -append "console=tty root=/dev/ram0 init=/sbin/init" \
        -netdev user,id=mynet0 -device e1000,netdev=mynet0 \
        -enable-kvm
}

main() {
    local output_dir="$PWD"
    local chroot_dir="$1"
    local packages="${2:-\
systemd-sysv \
bash bash-completion bc bsdextrautils bsdutils coreutils git kmod locales mc moreutils psmisc tmux unzip udev vim \
aria2 ca-certificates curl dhcpcd5 iputils-ping iproute2 iw netbase openssh-server w3m wget wpasupplicant \
sway}"

    [ "$chroot_dir" ] && cd "$chroot_dir" || {
        echo "Error: Could not change to directory '$chroot_dir'."
        exit 1
    }

    [ -f ./sbin/init ] || mkchroot "$packages"
    install_packages "$packages"
    configure_user
    mkinitramfs > "$output_dir/initramfs.img"
    cd "$output_dir"
    bootinitramfs /boot/vmlinuz-$(uname -r) ./initramfs.img 4096
}

main "$@"
