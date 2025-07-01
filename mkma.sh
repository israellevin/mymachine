#!/bin/bash

mkchroot() {
    local packages="$(echo "$1" | tr ' ' ',')"
    debootstrap --variant=minbase --components=main,contrib,non-free,firmware --include="$packages" sid .

    mkdir -p ./lib/modules
    cp -a /lib/modules/"$(uname -r)" ./lib/modules/
}

mkapt() {
    local packages="$1"

    mkdir ./fake
    for binary in initctl invoke-rc.d restart start stop start-stop-daemon service; do
        ln -s ./bin/true ./fake/$binary
    done

    mkdir -p ./etc/apt
    cat > ./etc/apt/apt.conf <<EOF
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF

    chroot . <<EOF
export PATH="/fake:\$PATH"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y install $packages
apt clean
EOF

    rm -rf ./fake
}

mkuser() {
    echo auth sufficient pam_wheel.so trust >> ./etc/pam.d/su
    if [ -w ./etc/locale.gen ]; then
        echo "en_US.UTF-8 UTF-8" > ./etc/locale.gen
        chroot . locale-gen || true
    fi
    chroot . <<EOF
groupadd wheel
useradd --create-home --user-group --shell "\$(type -p bash)" -G wheel i
passwd -d root
passwd -d i
su -c '
    git clone https://github.com/israellevin/dotfiles.git ~/src/dotfiles
    ~/src/dotfiles/install.sh' i
EOF
}

mkinitramfs() {
    mkdir -p ./{proc,sys,dev,tmp,run}
    chmod 1777 ./tmp
    mknod -m 622 ./dev/console c 5 1 2>/dev/null || true
    mknod -m 666 ./dev/null c 1 3 2>/dev/null || true

    cat <<'EOF' > ./init
#!/bin/sh
echo [init] Starting mkma.sh init script...

echo [init] Mounting tmpfs for overlay...
mkdir /overlay
mount -t tmpfs -o size=8G tmpfs /overlay

echo [init] Mounting tmpfs for overlay...
mkdir /overlay/old_root /overlay/new_root /overlay/upper /overlay/work
date
cp -a / /overlay/old_root
date

echo [init] Mounting overlayfs...
mount -t overlay overlay -o lowerdir=/overlay/old_root,upperdir=/overlay/upper,workdir=/overlay/work /overlay/new_root
rm -rf /overlay/new_root/overlay

echo [init] Moving to new root...
exec /usr/lib/klibc/bin/run-init /overlay/new_root /lib/systemd/systemd
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
        -append "console=tty root=/dev/ram0 init=/init" \
        -netdev user,id=mynet0 -device e1000,netdev=mynet0 \
        -enable-kvm
}

main() {
    local output_dir="$PWD"
    local chroot_dir="$1"
    local packages="${2:-\
systemd-sysv \
bash bash-completion bc bsdextrautils bsdutils coreutils git klibc-utils kmod locales mc moreutils psmisc tmux unzip udev vim \
aria2 ca-certificates curl dhcpcd5 iputils-ping iproute2 iw netbase openssh-server w3m wget wpasupplicant \
sway}"

    [ "$chroot_dir" ] && cd "$chroot_dir" || {
        echo "Error: Could not change to directory '$chroot_dir'."
        exit 1
    }

    [ -f ./sbin/init ] || mkchroot "$packages"
    mkapt "$packages"
    mkuser
    mkinitramfs > "$output_dir/initramfs.img"
    cd "$output_dir"
    bootinitramfs /boot/vmlinuz-$(uname -r) ./initramfs.img 4096
}

(return 0 2>/dev/null) || main "$@"
