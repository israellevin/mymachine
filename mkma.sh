#!/bin/bash

mkchroot() {
    local packages="$(echo "$@" | tr ' ' ',')"
    local variant=minbase
    local components=main,contrib,non-free,non-free-firmware
    local branch=unstable
    debootstrap --variant=$variant --components=$components --include="$packages" $branch .
    mkdir -p ./lib/modules
    cp -a --parents /lib/modules/"$(uname -r)" .
    systemd-firstboot --root . --hostname="$(hostname)" --copy
}

mkapt() {
    local packages="$@"

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
apt update
apt --fix-broken install -y  # Sometimes debootstrap leaves broken packages.
apt install -y $packages
apt clean
EOF

    rm -rf ./fake
}

mkdwl() {
    curl https://raw.githubusercontent.com/israellevin/dwl/refs/heads/mine/Dockerfile > Dockerfile
    docker build -t dwl-builder .
    rm Dockerfile
    docker run --rm --name dwl-builder -dp 80:8000 dwl-builder
    chroot . sh -c 'curl localhost | tar -xC /'
}

mkuser() {
    echo auth sufficient pam_wheel.so trust >> ./etc/pam.d/su
    if [ -w ./etc/locale.gen ]; then
        echo en_US.UTF-8 UTF-8 > ./etc/locale.gen
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
    reset
}

mkcpio() {
    local level=$1
    find . -mount -print0 | pv -0 -l -s "$(find . | wc -l)" | cpio -o --null --format=newc | zstd -T0 -$level
}

mkinitramfsinit() {
    cat <<'EOF' > ./init
#!/bin/sh
new_root_path=/root

mount -t devtmpfs devtmpfs /dev
_log() {
    level=$1
    shift
    message="$(date) [mkma.sh init]: $*"
    echo "<$level>$message" > /dev/kmsg
}
info() { _log 6 "Info: $*"; }
error() { _log 3 "Error: $*"; }
emergency() { _log 2 "Emergency: $*"; /bin/sh; }

info Starting init process

info Mounting tmpfs for new root
mkdir -p "$new_root_path"
mount -t tmpfs -o size=8G tmpfs "$new_root_path"

info Getting mkma storage
mkdir -p /proc /mnt
mount -t proc proc /proc
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        mkma_storage_device=*)
            mkma_storage_device="${arg#mkma_storage_device=}"
            ;;
        mkma_storage_path=*)
            mkma_storage_path="${arg#mkma_storage_path=}"
            ;;
    esac
done
modprobe crc32c_generic
modprobe ext4
mount "$mkma_storage_device" /mnt || emergency Could not mount mkma storage device "'$mkma_storage_device'"
[ -f "/mnt/$mkma_storage_path" ] || emergency Could not find root image at "'/mnt/$mkma_storage_path'"

info Copying root image data
cd "$new_root_path"
pv -pterab /mnt"$mkma_storage_path" | zstd -dcf | cpio -id || emergency Could not copy root image data
umount /mnt

info Moving to new root
exec run-init /root /lib/systemd/systemd || emergency Failed pivot to systemd
EOF

    chmod +x ./init
}

mkinitramfs() {
    mkdir -p ./{bin,dev,mnt,proc,sys,run,tmp}
    chmod 1777 ./tmp
    mknod -m 622 ./dev/console c 5 1 2>/dev/null || true
    mknod -m 666 ./dev/null c 1 3 2>/dev/null || true

    cp -a --parents /lib/modules/"$(uname -r)"/modules.dep .
    for required_module in ext4 pci; do
        for dependency_module in $(modprobe --show-depends $required_module | cut -d' ' -f2); do
            mkdir -p ".$(dirname "$dependency_module")"
            cp -au --parents "$dependency_module" .
        done
    done

    for binary in busybox pv zstd; do
        binary="$(type -p $binary)"
        cp -a "$binary" ./bin/.
        for library in $(ldd "$binary" 2> /dev/null | grep -o '/[^ ]*'); do
            cp -auL --parents "$library" .
        done
    done

    cd ./bin
    for applet in $(./busybox --list | grep -v busybox); do
        ln -s ./busybox "./$applet"
    done
    cd -

    mkinitramfsinit
}

bootinitramfs() {
    local kernel_image="$1"
    local initramfs_image="$2"
    local root_image="$3"
    local qemu_disk="$4"
    local ramdisk_size="$5"

    if [ ! -f "$qemu_disk" ]; then
        set -x
        qemu-img create -f raw "$qemu_disk" $ramdisk_size
        set +x
        mkfs.ext4 -F "$qemu_disk"
    fi
    mkdir ./mnt
    mount "$qemu_disk" ./mnt
    cp --parents "$root_image" ./mnt/.
    umount ./mnt
    rmdir ./mnt

    qemu_options=(
        -m "$ramdisk_size"
        -kernel "$kernel_image"
        -initrd "$initramfs_image"
        -append "console=tty root=/dev/ram0 init=/init mkma_storage_device=/dev/nvme0n1 mkma_storage_path=$root_image"
        -netdev user,id=mynet0
        -device e1000,netdev=mynet0
        -enable-kvm
        -drive file="$qemu_disk",format=raw,if=none,id=nvme0
        -device nvme,drive=nvme0,serial=deadbeef
    )

    if [ "$QEMU_VGA" ]; then
        qemu_options+=(
            -vga virtio
            -display sdl,gl=on
        )
    fi

    qemu-system-x86_64 "${qemu_options[@]}"
}

mkcd() {
    mkdir -p "$1"
    cd "$1"
}

mkma() {
    local chroot_dir="$(realpath ./chroot)"
    local initramfs_dir="$(realpath ./initramfs)"
    local root_image="$PWD/mkma.root.cpio.zst"
    local initramfs_image="$PWD/mkma.init.cpio.zst"
    local qemu_disk="$PWD/mkma.qemu.disk.raw"
    local packages=(
        dbus dbus-user-session systemd-sysv udev
        coreutils klibc-utils kmod util-linux
        bash bash-completion chafa console-setup git git-delta locales mc tmux vim
        cpio gzip tar unrar unzip zstd
        bc bsdextrautils bsdutils mawk moreutils pciutils psmisc sed ripgrep usbutils
        ca-certificates dhcpcd5 iproute2 netbase
        aria2 curl iputils-ping openssh-server w3m wget
        firmware-iwlwifi iw wpasupplicant
        docker.io docker-cli nodejs npm python3-pip python3-venv
        foot firefox wl-clipboard wmenu
        ffmpeg mpv pipewire-audio yt-dlp
    )

    if [ "$QEMU_VGA" ]; then
        packages+=(mesa-utils libgl1-mesa-dri pciutils)
    fi

    mkcd "$chroot_dir"
    [ -f ./sbin/init ] || mkchroot "${packages[@]}"
    mkapt "${packages[@]}"
    mkdwl
    mkuser
    mkcpio "$COMPRESSION_LEVEL" > "$root_image"

    mkcd "$initramfs_dir"
    [ -f ./init ] || mkinitramfs
    mkcpio "$COMPRESSION_LEVEL" > "$initramfs_image"

    echo Testing mkma on QEMU...
    bootinitramfs /boot/vmlinuz-$(uname -r) "$initramfs_image" "$root_image" "$qemu_disk" 2G

    echo kernel: /boot/vmlinuz-$(uname -r)
    echo initramfs: "$initramfs_image"
    echo parameters: "mkma_storage_device=$(df "$root_image" | grep -o '/dev/[^ ]*') mkma_storage_path=$root_image"
}

(return 0 2>/dev/null) || mkma "$@"
