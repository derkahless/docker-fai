#!/bin/bash
#
# Burn ISO image to USB drive. Supports ISOs generated by FAI or with
# genisoimage over a Kickstart config and labeled Kickstart_CD
#
# By Ricardo Branco - ricardo.branco@smartmatic.com
#
# Version 2.3.6
#

PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
LANG=en

# Exit on error
set -e

usage ()
{
	cat >&2 <<- EOF
	Usage: ${0##*/} [OPTIONS] ISO
	Options:
	        -f	Force. Don't ask.
	        -v	Verbose mode.
		-w	Create a writable filesystem (ext2 instead of ISO-9660).
	EOF
	
	exit 1
}

error ()
{
	echo "ERROR: $@" >&2
	echo "Exiting..." >&2
	exit 1
}

# Check that we are running on a 64-bit Debian-like Linux
check_os ()
{
	[ $(uname -s) = "Linux" -a $(arch) = "x86_64" -a -f /etc/debian_version ] || \
		error "burniso.sh must be run on a 64-bit Debian-like OS"
}

# Check that these packages are installed
check_pkgs ()
{
	for pkg in "$@" parted genisoimage ; do
		dpkg-query -s $pkg >/dev/null 2>&1 || \
			error "You must install $pkg with: sudo apt-get install $pkg"
	done
}

# Make sure the ISO was generated with FAI or is labeled Kickstart_CD
check_iso ()
{
	ISOID=$(isoinfo -d -i "$1" | sed -nre 's/^Volume id: //p')
	echo $ISOID | fgrep -qe 'FAI_CD' -e 'Fully Automatic Installation CD' -e 'Kickstart_CD' || \
		error "Invalid image $1: Unexpected Volume id [$ISOID]"
}

# Return true if the ISO is hybrid
check_hybrid ()
{
	local status=$(fdisk -l "$1" 2>/dev/null | \
		awk -v file="$1" '$1 == file "1" {
			n = $2 == "*" ? $3 : $2
			if (n == 0 || n == 64 || $NF == "GPT")
				print "ok"
		}')

	[ "$status" = "ok" ]
}

# Check that the ISO is not truncated and fits in the device
check_size ()
{
	local dev_size iso_size file_size

	# Get expected size from ISO header
	iso_size=$(($(isoinfo -d -i "$1" | sed -nre 's/^Volume size is: //p') * 2048))

	file_size=$(stat -c '%s' "$1")

	[ $iso_size -eq $file_size ] || \
		error "ISO is truncated to $file_size bytes (should be $iso_size): $1"

	dev_size=$(sudo blockdev --getsize64 "$2")

	[ $iso_size -lt $dev_size ] || \
		error "ISO too large to fit on device: $1"

	if [ "$ISOID" = "Kickstart_CD" ]; then
		iso_size=$((${iso_size} * 2))
		[ $iso_size -lt $dev_size ] || \
			error "Kickstart_CD ISO too large to fit on device: $1"
	fi
}

# Print list of USB drives and make sure only one is present
get_usbdrives ()
{
	local dev serial devices

	# udevinfo is now udevadm
	udevinfo=$(which udevinfo 2>/dev/null || true)
	if [ -z "$udevinfo" ] ; then
		udevinfo="udevadm info"
	else
		udevinfo="udevinfo"
	fi

	devices=0

	# Detect all SCSI devices
	for dev in /sys/block/sd* ; do
		# Discard non-USB drives
		if ! readlink -e $dev | fgrep -q /usb ; then
			continue
		fi
		dev=${dev##*/}
		echo -n "INFO: Found USB drive: /dev/$dev"
		# Detect partitions
		PARTITIONS=$(ls /dev/$dev[0-9]* 2>/dev/null | sed 's%/dev/%%g')
		# Get serial
		serial=$($udevinfo -q property -n $dev | sed -rne 's/^ID_SERIAL=//p')
		echo " [$serial]"
		DEV=/dev/$dev
		devices=$((devices+1))
	done

	echo

	if [ $devices -gt 1 ] ; then
		error "Found more than one USB drive."
	elif [ $devices -eq 0 ] ; then
		error "No USB drives found."
	fi

	# Sometimes a USB drive is plugged-in but doesn't appear on /dev
	if [[ ! -b $DEV || -z $(sudo blockdev --getsize64 $DEV 2>/dev/null) ]] ; then
		error "Please unplug and replug USB drive: $serial"
	fi
}

# Unmount all partitions from device
umount_device ()
{
	# Unmount partitions
	for dev in $PARTITIONS ; do
		mount | grep "^/dev/$dev on" | awk '{ print $3 }' | sort -r | \
		while read dir ; do
			mount | awk '{ print $3 }' | fgrep "$dir/" | sort -r | \
			while read subdir ; do
				sudo umount -v $subdir
			done
			sudo umount -v $dir
		done
		sudo dd if=/dev/zero of=/dev/$dev bs=64K count=1 2>/dev/null
		sudo parted $DEV -s -- rm ${dev#${DEV#/dev/}} || true
	done

	if [ -z "$PARTITIONS" ] ; then
		mount | grep "^$DEV on" |  awk '{ print $3 }' | sort -r | \
		while read dir ; do
			sudo umount -v $DEV
		done
	fi

	# Erase MBR/GPT partition table
	sudo dd if=/dev/zero of=$DEV bs=512 count=64 2>/dev/null
	# Erase GPT signature at end of disk too
	sudo dd if=/dev/zero of=$DEV bs=512 count=64 seek=$(($(sudo blockdev --getsz $DEV) - 64)) 2>/dev/null

	sudo partprobe $DEV 2>/dev/null || true
}

# Format USB drive with ext2
format_device ()
{
	local label

	echo "INFO: Re-creating partition table on $DEV"

	sudo parted $DEV -s -- mklabel msdos
	sudo parted $DEV -s -- mkpart primary 1 -1
	# Set booteable flag on first partition
	sudo parted $DEV -s -- set 1 boot on
	sudo partprobe $DEV

	echo "INFO: Formatting ${DEV}1"

	# Format USB drive with ext2
	if [ "$ISOID" != "Kickstart_CD" ]; then
		label="FAI_CD"
	else
		label="Kickstart_CD"
	fi
	sudo mkfs.ext2 $verbose -m 0 -L "$label" ${DEV}1
}

# Cleanup function in case ^C is pressed
cleanup ()
{
	set +e
	if [ "$ISOID" != "Kickstart_CD" ]; then
		sudo umount $MNT_FAI/live/filesystem.dir/{boot,dev,proc,sys} 2>/dev/null
	fi
	sudo umount $MNT_ISO $MNT_FAI 2>/dev/null
	sudo rmdir $MNT_ISO $MNT_FAI 2>/dev/null
	rm -f $tmp_md5
}

# Create temporary directories and files
setup_tmp ()
{
	# Create temporary directories and file
	MNT_ISO=$(sudo mktemp -d /media/tmp.XXXXXXXXXX)
	MNT_FAI=$(sudo mktemp -d /media/tmp.XXXXXXXXXX)
	tmp_md5=$(mktemp)

	# Cleanup on interrupt...
	trap cleanup ERR HUP INT QUIT TERM
}

# Check MD5 of copied files to ensure copy integrity
check_md5 ()
{
	echo "INFO: Verifying checksums. Please wait..."

	# Prevent the kernel from verifying the files in cache
	sudo sysctl -w vm.drop_caches=3 >/dev/null

	sudo find $MNT_ISO -type f -exec md5sum {} + > $tmp_md5
	sed -i -e "s%^$MNT_ISO%$MNT_FAI%" $tmp_md5
	sudo md5sum --quiet -c $tmp_md5
	rm -f $tmp_md5
}

# Install extlinux and related files
install_extlinux ()
{
	local version
	sudo extlinux --install $MNT_FAI
	if [ -d /usr/lib/syslinux/modules/bios ]; then
		sudo cp /usr/lib/syslinux/modules/bios/*.c32 $MNT_FAI
	elif [ -d /usr/lib/syslinux ]; then
		sudo cp /usr/lib/syslinux/*.c32 $MNT_FAI
	fi
}

# Copy all files to USB drive and install Grub
copy_files ()
{
	local MBRF isobase isosum tgtsum

	# Mount filesystems
	sudo mount -r -o loop "$1" $MNT_ISO
	sudo mount ${DEV}1 $MNT_FAI

	echo "INFO: Copying files. Please wait..."
	sudo rsync $verbose -aAX $MNT_ISO/ $MNT_FAI

	check_md5

	echo "INFO: Installing bootloader. Please wait..."
	if [ "$ISOID" != "Kickstart_CD" ]; then
		echo "INFO: Installing GRUB. Please wait..."
		# Bind mount system /dev and FAI's /boot to live filesystem
		sudo mount --bind /dev $MNT_FAI/live/filesystem.dir/dev
		sudo mount --bind /sys $MNT_FAI/live/filesystem.dir/sys
		sudo mount --bind /proc $MNT_FAI/live/filesystem.dir/proc
		sudo mount --bind $MNT_FAI/boot $MNT_FAI/live/filesystem.dir/boot
		sudo chroot $MNT_FAI/live/filesystem.dir /usr/sbin/grub-install $verbose --force --no-floppy $DEV
	else
		echo "INFO: Installing extlinux. Please wait..."
		install_extlinux
		# Mark partition 1 as active
		sudo sfdisk $DEV -A 1
		# Copy mbr.bin into device's MBR
		if [ -e "/usr/share/syslinux/mbr.bin" ]; then
			MBRF="/usr/share/syslinux/mbr.bin"
		elif [ -e "/usr/lib/syslinux/mbr.bin" ]; then
			MBRF="/usr/lib/syslinux/mbr.bin"
		elif [ -e "/usr/lib/syslinux/mbr/mbr.bin" ]; then
			MBRF="/usr/lib/syslinux/mbr/mbr.bin"
		else
			error "Couln't find mbr.bin in the system. Aborting"
		fi
		sudo dd if=$MBRF of=$DEV
	fi

	echo "INFO: Syncing. Please wait..."
	sync

	if [ "$ISOID" = "Kickstart_CD" ]; then
		echo "INFO: Copying full ISO file to target's root dir"
		sudo cp -i "$1" $MNT_FAI/

		echo "INFO: Checking ISO file within target"
		isobase=$(basename "$1")
		isosum=$(md5sum "$1")
		tgtsum=$(md5sum "$MNT_FAI/$isobase")

		if [ "${isosum:0:32}" != "${tgtsum:0:32}" ]; then
			echo "ERROR: hash mismatch between [$1] and [$MNT_FAI/$isobase]"
		else
			echo "INFO: OK"
		fi

		echo "INFO: Syncing. Please wait..."
		sync
	fi

	if [ "$ISOID" != "Kickstart_CD" ]; then
		sudo umount $MNT_FAI/live/filesystem.dir/{boot,dev,proc,sys}
	fi
	sudo umount $MNT_ISO $MNT_FAI
	sudo rmdir $MNT_ISO $MNT_FAI

	echo "INFO: Done."
}

# Dump ISO to USB drive (only possible with hybrid ISO's)
dd_iso ()
{
	echo "INFO: Dumping ISO to device. Please wait..."
	sudo dd if="$1" of=$DEV

	sudo partprobe $DEV

	# Mount filesystems
	sudo mount -r -o loop "$1" $MNT_ISO
	sudo mount -r $DEV $MNT_FAI
	check_md5

	echo "INFO: Syncing. Please wait..."

	sudo umount $MNT_ISO $MNT_FAI
	sudo rmdir $MNT_ISO $MNT_FAI

	echo "INFO: Done."
}

# MAIN

while getopts "hfvw" opt ; do
	case $opt in
		f)
			force=true ;;
		v)
			verbose="-v" ;;
		w)
			writable=true ;;
		*)
			usage ;;
	esac
done
shift $((OPTIND-1))

if [ $# -ne 1 -a $# -ne 2 ] ; then
	usage
fi

check_os

check_pkgs

check_iso "$1"

if [ "$ISOID" = "Kickstart_CD" ]; then
	# We don't expect hybrid ISOs generated via kickstart
	writable=true
	# Also check that these packages are present
	check_pkgs extlinux syslinux-common
fi

# Undocumented feature:
# Only experienced users may specify a device as 2nd argument with -f option.
if [ "$force" = "true" ] ; then
	DEV=${2##*/}
	if [[ ! -b "$2" || -z $(readlink -e /sys/block/$DEV | fgrep /usb) ]] ; then
		error "Invalid USB device: $2"
	fi
	DEV=/dev/$DEV
	PARTITIONS=$(ls $DEV[0-9]* 2>/dev/null | sed 's%/dev/%%g')
else
	[ $# -gt 1 ] && usage
	get_usbdrives
fi

check_size "$1" "$DEV"

if [ "$writable" != "true" ] && ! check_hybrid "$1" ; then
	error "ISO is not hybrid (consider using -w option): $1"
fi

if [ "$force" != "true" ] ; then
	echo "WARNING: THIS WILL CAUSE DATA LOSS!"
	read -p "Do you want to continue (yes/no)? " reply	
	if [ "$reply" != "yes" ] ; then
		echo "Exiting..."
		exit
	fi
fi

umount_device

setup_tmp

if [ "$writable" = "true" ] ; then
	format_device
	copy_files "$1"
else
	dd_iso "$1"
fi
