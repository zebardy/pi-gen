#!/bin/bash -e

NOOBS_DIR="${STAGE_WORK_DIR}/${IMG_NAME}${IMG_SUFFIX}"
mkdir -p "${STAGE_WORK_DIR}"

IMG_FILE="${WORK_DIR}/export-image/${IMG_FILENAME}${IMG_SUFFIX}.img"

ensure_next_loopdev() {
	local loopdev
	loopdev="$(losetup -f)"
	loopmaj="$(echo \"$loopdev\" | sed -E 's/.*loop([0-9]+)$/\1/')"
	[[ -b "$loopdev" ]] || mknod "$loopdev" b 7 "$loopmaj"
}

ensure_loopdev_partitions(){
	LOOPDEV=$1
	PARTITIONS=$(lsblk --raw --output "MAJ:MIN" --noheadings ${LOOPDEV} | tail -n +2)
	COUNTER=1
	for i in $PARTITIONS; do
	    MAJ=$(echo $i | cut -d: -f1)
	    MIN=$(echo $i | cut -d: -f2)
	    if [ ! -e "${LOOPDEV}p${COUNTER}" ]; then mknod ${LOOPDEV}p${COUNTER} b $MAJ $MIN; fi
	    COUNTER=$((COUNTER + 1))
	done
}

unmount_image "${IMG_FILE}"

rm -rf "${NOOBS_DIR}"

echo "Creating loop device..."
cnt=0
until ensure_next_loopdev && LOOP_DEV="$(losetup --show --find --partscan "$IMG_FILE")"; do
	if [ $cnt -lt 5 ]; then
		cnt=$((cnt + 1))
		echo "Error in losetup.  Retrying..."
		sleep 5
	else
		echo "ERROR: losetup failed; exiting"
		exit 1
	fi
done

ensure_loopdev_partitions ${LOOP_DEV}

BOOT_DEV="${LOOP_DEV}p1"
ROOT_DEV="${LOOP_DEV}p2"

mkdir -p "${STAGE_WORK_DIR}/rootfs"
mkdir -p "${NOOBS_DIR}"

echo "Mounting partitions..."

mount "$ROOT_DEV" "${STAGE_WORK_DIR}/rootfs"
mount "$BOOT_DEV" "${STAGE_WORK_DIR}/rootfs/boot"

echo "Configure OS and kernel..."

ln -sv "/lib/systemd/system/apply_noobs_os_config.service" "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/apply_noobs_os_config.service"

KERNEL_VER="$(zgrep -oPm 1 "Linux version \K(.*)$" "${STAGE_WORK_DIR}/rootfs/usr/share/doc/raspberrypi-kernel/changelog.Debian.gz" | cut -f-2 -d.)"
echo "$KERNEL_VER" > "${STAGE_WORK_DIR}/kernel_version"

echo "Tar partitions..."

bsdtar --numeric-owner --format gnutar -C "${STAGE_WORK_DIR}/rootfs/boot" -cpf - . | xz -T0 > "${NOOBS_DIR}/boot.tar.xz"
umount "${STAGE_WORK_DIR}/rootfs/boot"
bsdtar --numeric-owner --format gnutar -C "${STAGE_WORK_DIR}/rootfs" --one-file-system -cpf - . | xz -T0 > "${NOOBS_DIR}/root.tar.xz"

if [ "${USE_QCOW2}" = "1" ]; then
	rm "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/apply_noobs_os_config.service"
fi

echo "Unmount image..."

unmount_image "${IMG_FILE}"
