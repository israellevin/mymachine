#!/bin/bash

mkchroot() {
    local packages="$(echo "$1" | tr ' ' ',')"
    debootstrap --variant=minbase --components=main,contrib,non-free-firmware --include="$packages" unstable . || {
        echo "Error: debootstrap failed. Ensure you have the required permissions and network access."
        exit 1
    }
    mkdir -p ./lib/modules
    cp -a /lib/modules/"$(uname -r)" ./lib/modules/
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
apt-get update
apt-get install -y $packages
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
    reset
}

mkinitramfs() {
    mkdir -p ./{proc,sys,dev,tmp,run}
    chmod 1777 ./tmp
    mknod -m 622 ./dev/console c 5 1 2>/dev/null || true
    mknod -m 666 ./dev/null c 1 3 2>/dev/null || true

    cat <<'EOF' > ./init
#!/bin/bash
persistence_path="/mnt/boot/mkma.persistence"

mount -t devtmpfs devtmpfs /dev/
_log() {
    local level="$1"
    shift
    local message="$(date) [mkma.sh init]: $*"
    echo "$message"
    echo "<$level>$message" > /dev/kmsg
}
info() { _log 6 "Info: $*"; }
error() { _log 3 "Error: $*"; }
emergency() { _log 2 "Emergency: $*"; /bin/bash; }
on_any_error() { emergency An error occurred on "'$last_command'"; }
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap 'on_any_error' EXIT

info Starting init process

info Mounting tmpfs for overlay
mkdir /overlay/
mount -t tmpfs -o size=8G tmpfs /overlay/
mkdir /overlay/lower/ /overlay/upper/ /overlay/work/ /overlay/merge/

info Copying current root as base layer
cp -a / /overlay/lower/ 2>/dev/null || true

info Searching for persistence layer
mount -t proc proc /proc
persistence_device=$(grep -oP 'persistence_device=\K[^ ]+' /proc/cmdline)
umount /proc
if [ "$persistence_device" ]; then
    info Mounting persistence device "$persistence_device"
    mount "$persistence_device" /mnt/ || error Could not mount persistence device "$persistence_device"
    if [ -f "$persistence_path" ]; then
        info Copying persistence data
        zstdcat "$persistence_path" | cpio -id --no-absolute-filenames -D /overlay/lower/
    else
        error No persistence data found on "$persistence_path"
    fi
    umount /mnt
fi

info Mounting overlayfs
mount -t overlay overlay -o lowerdir=/overlay/lower/,upperdir=/overlay/upper/,workdir=/overlay/work/ /overlay/merge/ \
    || emergency Could not mount overlayfs, aboting to shell
mount --bind /overlay/ /overlay/merge/overlay/

info Moving to new root
exec /usr/lib/klibc/bin/run-init /overlay/merge/ /lib/systemd/systemd
EOF

    chmod +x ./init
    find . -mount -print0 | pv -0 -l -s "$(find . | wc -l)" | cpio -o --null --format=newc
}

bootinitramfs() {
    local kernel_image="$1"
    local initramfs_image="$2"
    local ramdisk_size="${3:-4096}"
    local persistence_filesystem_image="${4:-./persistence.img}"

    if [ ! -f "$kernel_image" ]; then
        echo "Error: Kernel image $kernel_image not found."
        exit 1
    fi

    if [ ! -f "$initramfs_image" ]; then
        echo "Error: Initramfs image $initramfs_image not found."
        exit 1
    fi

    if [ ! -f "$persistence_filesystem_image" ]; then
        qemu-img create -f raw "$persistence_filesystem_image" 1G
        mkfs.ext4 -F "$persistence_filesystem_image"
    fi

    qemu_options=(
        -m "$ramdisk_size"
        -kernel "$kernel_image"
        -initrd "$initramfs_image"
        -append "console=tty root=/dev/ram0 init=/init persistence_device=/dev/nvme0n1"
        -netdev user,id=mynet0
        -device e1000,netdev=mynet0
        -enable-kvm
        -drive file="$persistence_filesystem_image",format=raw,if=none,id=nvme0
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

main() {
    local output_dir="$PWD"
    local chroot_dir="$1"
    shift
    local packages=( "$@" )
    [ "$packages" ] || packages=(
        dbus dbus-user-session systemd-sysv udev
        coreutils klibc-utils kmod util-linux
        bash bash-completion chafa console-setup git git-delta locales mc tmux vim
        cpio gzip tar unrar unzip zstd
        bc bsdextrautils bsdutils mawk moreutils pciutils psmisc sed ripgrep usbutils
        ca-certificates dhcpcd5 iproute2 netbase
        aria2 curl iputils-ping openssh-server w3m wget
        firmware-iwlwifi iw wpasupplicant
        docker.io docker-cli npm python3-pip python3-venv
        foot firefox wl-clipboard wmenu
        ffmpeg mpv pipewire-audio yt-dlp
    )

    if [ "$QEMU_VGA" ]; then
        packages+=(mesa-utils libgl1-mesa-dri pciutils)
    fi

    [ "$chroot_dir" ] && cd "$chroot_dir" || {
        echo "Error: Could not change to directory '$chroot_dir'."
        exit 1
    }

    [ -f ./sbin/init ] || mkchroot "${packages[@]}"
    mkapt "${packages[@]}"
    mkdwl
    mkuser
    if [ "$COMPRESSION_LEVEL" ]; then
        initramfs_file="$output_dir/initramfs.zst"
        mkinitramfs | zstd -T0 -$COMPRESSION_LEVEL --ultra > "$initramfs_file"
    else
        initramfs_file="$output_dir/initramfs"
        mkinitramfs > "$initramfs_file"
    fi
    cd "$output_dir"

    bootinitramfs /boot/vmlinuz-$(uname -r) "$initramfs_file" 8192
}

(return 0 2>/dev/null) || main "$@"
