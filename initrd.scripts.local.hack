# Hacked version of initrd script which unpacks an archive into tmpfs and uses it as root.
# Local filesystem mounting			-*- shell-script -*-

local_top()
{
	if [ "${local_top_used}" != "yes" ]; then
		[ "${quiet?}" != "y" ] && log_begin_msg "Running /scripts/local-top"
		run_scripts /scripts/local-top
		[ "$quiet" != "y" ] && log_end_msg
	fi
	local_top_used=yes

	# Start time for measuring elapsed time in local_device_setup
	if [ -z "${local_top_time}" ]; then
		local_top_time="$(cat /proc/uptime)"
		local_top_time="${local_top_time%%[. ]*}"
		local_top_time=$((local_top_time + 1)) # round up
		export local_top_time
	fi
}

local_block()
{
	[ "${quiet?}" != "y" ] && log_begin_msg "Running /scripts/local-block"
	run_scripts /scripts/local-block "$@"
	[ "$quiet" != "y" ] && log_end_msg
}

local_premount()
{
	if [ "${local_premount_used}" != "yes" ]; then
		[ "${quiet?}" != "y" ] && log_begin_msg "Running /scripts/local-premount"
		run_scripts /scripts/local-premount
		[ "$quiet" != "y" ] && log_end_msg
	fi
	local_premount_used=yes
}

local_bottom()
{
	if [ "${local_premount_used}" = "yes" ] || [ "${local_top_used}" = "yes" ]; then
		[ "${quiet?}" != "y" ] && log_begin_msg "Running /scripts/local-bottom"
		run_scripts /scripts/local-bottom
		[ "$quiet" != "y" ] && log_end_msg
	fi
	local_premount_used=no
	local_top_used=no
	unset local_top_time
}

# $1=device ID to mount
# $2=optionname (for root and etc)
# $3=panic if device is missing (true or false, default: true)
# Sets $DEV to the resolved device node
local_device_setup()
{
	local dev_id="$1"
	local name="$2"
	local may_panic="${3:-true}"
	local real_dev
	local time_elapsed
	local count

	wait_for_udev 10

	# Load ubi with the correct MTD partition and return since fstype
	# doesn't work with a char device like ubi.
	if [ -n "$UBIMTD" ]; then
		modprobe ubi "mtd=$UBIMTD"
		DEV="${dev_id}"
		return
	fi

	# Don't wait for a device that doesn't have a corresponding
	# device in /dev and isn't resolvable by blkid (e.g. mtd0)
	if [ "${dev_id#/dev}" = "${dev_id}" ] &&
	   [ "${dev_id#*=}" = "${dev_id}" ]; then
		DEV="${dev_id}"
		return
	fi

	# If the root device hasn't shown up yet, give it a little while
	# to allow for asynchronous device discovery (e.g. USB).  We
	# also need to keep invoking the local-block scripts in case
	# there are devices stacked on top of those.
	if ! real_dev=$(resolve_device "${dev_id}") ||
	   ! get_fstype "${real_dev}" >/dev/null; then
		log_begin_msg "Waiting for ${name}"

		# Timeout is max(30, rootdelay) seconds (approximately)
		slumber=30
		if [ "${ROOTDELAY:-0}" -gt $slumber ]; then
			slumber=$ROOTDELAY
		fi

		while true; do
			sleep 1
			time_elapsed="$(cat /proc/uptime)"
			time_elapsed="${time_elapsed%%[. ]*}"
			time_elapsed=$((time_elapsed - local_top_time))

			local_block "${dev_id}"

			# If mdadm's local-block script counts the
			# number of times it is run, make sure to
			# run it the expected number of times.
			while true; do
				if [ -f /run/count.mdadm.initrd ]; then
					count="$(cat /run/count.mdadm.initrd)"
				elif [ -n "${count}" ]; then
					# mdadm script deleted it; put it back
					count=$((count + 1))
					echo "${count}" >/run/count.mdadm.initrd
				else
					break
				fi
				if [ ${count} -ge ${time_elapsed} ]; then
					break;
				fi
				/scripts/local-block/mdadm "${dev_id}"
			done

			if real_dev=$(resolve_device "${dev_id}") &&
			   get_fstype "${real_dev}" >/dev/null; then
				wait_for_udev 10
				log_end_msg 0
				break
			fi
			if [ ${time_elapsed} -ge "${slumber}" ]; then
				log_end_msg 1 || true
				break
			fi
		done
	fi

	# We've given up, but we'll let the user fix matters if they can
	while ! real_dev=$(resolve_device "${dev_id}") ||
	      ! get_fstype "${real_dev}" >/dev/null; do
		if ! $may_panic; then
			echo "Gave up waiting for ${name}"
			return 1
		fi
		echo "Gave up waiting for ${name} device.  Common problems:"
		echo " - Boot args (cat /proc/cmdline)"
		echo "   - Check rootdelay= (did the system wait long enough?)"
		if [ "${name}" = root ]; then
			echo "   - Check root= (did the system wait for the right device?)"
		fi
		echo " - Missing modules (cat /proc/modules; ls /dev)"
		panic "ALERT!  ${dev_id} does not exist.  Dropping to a shell!"
	done

	DEV="${real_dev}"
}

local_mount_root()
{
	local_top
	if [ -z "${ROOT}" ]; then
		panic "No root device specified. Boot arguments must include a root= parameter."
	fi
	local_device_setup "${ROOT}" "root file system"
	ROOT="${DEV}"

	# Get the root filesystem type if not set
	if [ -z "${ROOTFSTYPE}" ] || [ "${ROOTFSTYPE}" = auto ]; then
		FSTYPE=$(get_fstype "${ROOT}")
	else
		FSTYPE=${ROOTFSTYPE}
	fi

	local_premount

	if [ "${readonly?}" = "y" ]; then
		roflag=-r
	else
		roflag=-w
	fi

	checkfs "${ROOT}" root "${FSTYPE}"

	# HACK:
	# Instead of mounting the device as root, mount temporarily extract an archive into a tmpfs that will be our root.
	# shellcheck disable=SC2086
	mkdir -p /mnt
	if ! mount ${roflag} ${FSTYPE:+-t "${FSTYPE}"} ${ROOTFLAGS} "${ROOT}" /mnt"; then
		panic "Failed to mount ${ROOT} as  file system."
	fi
	echo "deploying rymachine from $FSTYPE in $ROOT"
	mount -t tmpfs -o size=75% none ${rootmnt}
	cd ${rootmnt}
	pv /mnt/boot/mymachine.tar | tar x
	umount /mnt
}

local_mount_fs()
{
	read_fstab_entry "$1"

	local_device_setup "$MNT_FSNAME" "$1 file system"
	MNT_FSNAME="${DEV}"

	local_premount

	if [ "${readonly}" = "y" ]; then
		roflag=-r
	else
		roflag=-w
	fi

	if [ "$MNT_PASS" != 0 ]; then
		checkfs "$MNT_FSNAME" "$MNT_DIR" "${MNT_TYPE}"
	fi

	# Mount filesystem
	if ! mount ${roflag} -t "${MNT_TYPE}" -o "${MNT_OPTS}" "$MNT_FSNAME" "${rootmnt}${MNT_DIR}"; then
		panic "Failed to mount ${MNT_FSNAME} as $MNT_DIR file system."
	fi
}

mountroot()
{
	local_mount_root
}

mount_top()
{
	# Note, also called directly in case it's overridden.
	local_top
}

mount_premount()
{
	# Note, also called directly in case it's overridden.
	local_premount
}

mount_bottom()
{
	# Note, also called directly in case it's overridden.
	local_bottom
}
