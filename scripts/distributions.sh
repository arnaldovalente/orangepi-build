#!/bin/bash
#
# Copyright (c) 2013-2021 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.


# Functions:

# install_common
# install_rclocal
# install_distribution_specific
# post_debootstrap_tweaks




install_common()
{
	display_alert "Applying common tweaks" "" "info"

	# install rootfs encryption related packages separate to not break packages cache
	if [[ $CRYPTROOT_ENABLE == yes ]]; then
		display_alert "Installing rootfs encryption related packages" "cryptsetup" "info"
		chroot "${SDCARD}" /bin/bash -c "apt-get -y -qq --no-install-recommends install cryptsetup" \
		>> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1
		if [[ $CRYPTROOT_SSH_UNLOCK == yes ]]; then
			display_alert "Installing rootfs encryption related packages" "dropbear-initramfs" "info"
			chroot "${SDCARD}" /bin/bash -c "apt-get -y -qq --no-install-recommends install dropbear-initramfs cryptsetup-initramfs" \
			>> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1
		fi

	fi

	# add dummy fstab entry to make mkinitramfs happy
	echo "/dev/mmcblk0p1 / $ROOTFS_TYPE defaults 0 1" >> "${SDCARD}"/etc/fstab
	# required for initramfs-tools-core on Stretch since it ignores the / fstab entry
	echo "/dev/mmcblk0p2 /usr $ROOTFS_TYPE defaults 0 2" >> "${SDCARD}"/etc/fstab

	# adjust initramfs dropbear configuration
	# needs to be done before kernel installation, else it won't be in the initrd image
	if [[ $CRYPTROOT_ENABLE == yes && $CRYPTROOT_SSH_UNLOCK == yes ]]; then
		# Set the port of the dropbear ssh daemon in the initramfs to a different one if configured
		# this avoids the typical 'host key changed warning' - `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`
		[[ -f "${SDCARD}"/etc/dropbear-initramfs/config ]] && \
		sed -i 's/^#DROPBEAR_OPTIONS=/DROPBEAR_OPTIONS="-p '"${CRYPTROOT_SSH_UNLOCK_PORT}"'"/' \
		"${SDCARD}"/etc/dropbear-initramfs/config

		# setup dropbear authorized_keys, either provided by userpatches or generated
		if [[ -f $USERPATCHES_PATH/dropbear_authorized_keys ]]; then
			cp "$USERPATCHES_PATH"/dropbear_authorized_keys "${SDCARD}"/etc/dropbear-initramfs/authorized_keys
		else
			# generate a default ssh key for login on dropbear in initramfs
			# this key should be changed by the user on first login
			display_alert "Generating a new SSH key pair for dropbear (initramfs)" "" ""
			ssh-keygen -t ecdsa -f "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa \
			-N '' -O force-command=cryptroot-unlock -C 'AUTOGENERATED_BY_ARMBIAN_BUILD'  >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1

			# /usr/share/initramfs-tools/hooks/dropbear will automatically add 'id_ecdsa.pub' to authorized_keys file
			# during mkinitramfs of update-initramfs
			#cat "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa.pub > "${SDCARD}"/etc/dropbear-initramfs/authorized_keys
			# The version of the Linux kernel
			CRYPTROOT_SSH_UNLOCK_KEY_NAME="${BOARD^}_${REVISION}_${DISTRIBUTION,}_${RELEASE}_${SELECTED_CONFIGURATION}_linux"$(grab_version "$LINUXSOURCEDIR")"".key
			# copy dropbear ssh key to image output dir for convenience
			cp "${SDCARD}"/etc/dropbear-initramfs/id_ecdsa "${DEST}/images/${CRYPTROOT_SSH_UNLOCK_KEY_NAME}"
			display_alert "SSH private key for dropbear (initramfs) has been copied to:" \
			"$DEST/images/$CRYPTROOT_SSH_UNLOCK_KEY_NAME" "info"
		fi
	fi

	# create modules file
	local modules=MODULES_${BRANCH^^}
	if [[ -n "${!modules}" ]]; then
		tr ' ' '\n' <<< "${!modules}" > "${SDCARD}"/etc/modules
	elif [[ -n "${MODULES}" ]]; then
		tr ' ' '\n' <<< "${MODULES}" > "${SDCARD}"/etc/modules
	fi

	# create blacklist files
	local blacklist=MODULES_BLACKLIST_${BRANCH^^}
	if [[ -n "${!blacklist}" ]]; then
		tr ' ' '\n' <<< "${!blacklist}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	elif [[ -n "${MODULES_BLACKLIST}" ]]; then
		tr ' ' '\n' <<< "${MODULES_BLACKLIST}" | sed -e 's/^/blacklist /' > "${SDCARD}/etc/modprobe.d/blacklist-${BOARD}.conf"
	fi

	# configure MIN / MAX speed for cpufrequtils
	cat <<-EOF > "${SDCARD}"/etc/default/cpufrequtils
	ENABLE=true
	MIN_SPEED=$CPUMIN
	MAX_SPEED=$CPUMAX
	GOVERNOR=$GOVERNOR
	EOF

	# remove default interfaces file if present
	# before installing board support package
	rm -f "${SDCARD}"/etc/network/interfaces

	# disable selinux by default
	mkdir -p "${SDCARD}"/selinux
	[[ -f "${SDCARD}"/etc/selinux/config ]] && sed "s/^SELINUX=.*/SELINUX=disabled/" -i "${SDCARD}"/etc/selinux/config

	# remove Ubuntu's legal text
	[[ -f "${SDCARD}"/etc/legal ]] && rm "${SDCARD}"/etc/legal

	# Prevent loading paralel printer port drivers which we don't need here.
	# Suppress boot error if kernel modules are absent
	if [[ -f "${SDCARD}"/etc/modules-load.d/cups-filters.conf ]]; then
		sed "s/^lp/#lp/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^ppdev/#ppdev/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
		sed "s/^parport_pc/#parport_pc/" -i "${SDCARD}"/etc/modules-load.d/cups-filters.conf
	fi

	# console fix due to Debian bug
	sed -e 's/CHARMAP=".*"/CHARMAP="'$CONSOLE_CHAR'"/g' -i "${SDCARD}"/etc/default/console-setup

	# add the /dev/urandom path to the rng config file
	echo "HRNGDEVICE=/dev/urandom" >> "${SDCARD}"/etc/default/rng-tools

	# ping needs privileged action to be able to create raw network socket
	# this is working properly but not with (at least) Debian Buster
	chroot "${SDCARD}" /bin/bash -c "chmod u+s /bin/ping"

	# change time zone data
	echo "${TZDATA}" > "${SDCARD}"/etc/timezone
	chroot "${SDCARD}" /bin/bash -c "dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1"

	# set root password
	chroot "${SDCARD}" /bin/bash -c "(echo $ROOTPWD;echo $ROOTPWD;) | passwd root >/dev/null 2>&1"

	# enable automated login to console(s)
	#mkdir -p "${SDCARD}"/etc/systemd/system/getty@.service.d/
	#mkdir -p "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/
	#cat <<-EOF > "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/override.conf
	#[Service]
	#ExecStartPre=/bin/sh -c 'exec /bin/sleep 10'
	#ExecStart=
	#ExecStart=-/sbin/agetty --noissue --autologin root %I \$TERM
	#Type=idle
	#EOF
	#cp "${SDCARD}"/etc/systemd/system/serial-getty@.service.d/override.conf "${SDCARD}"/etc/systemd/system/getty@.service.d/override.conf

	# force change root password at first login
	#chroot "${SDCARD}" /bin/bash -c "chage -d 0 root"

	# change console welcome text
	echo -e "${VENDOR} ${REVISION} ${RELEASE^} \\l \n" > "${SDCARD}"/etc/issue
	echo "${VENDOR} ${REVISION} ${RELEASE^}" > "${SDCARD}"/etc/issue.net
	sed -i "s/^PRETTY_NAME=.*/PRETTY_NAME=\"${VENDOR} $REVISION "${RELEASE^}"\"/" "${SDCARD}"/etc/os-release

	# enable few bash aliases enabled in Ubuntu by default to make it even
	sed "s/#alias ll='ls -l'/alias ll='ls -l'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias la='ls -A'/alias la='ls -A'/" -i "${SDCARD}"/etc/skel/.bashrc
	sed "s/#alias l='ls -CF'/alias l='ls -CF'/" -i "${SDCARD}"/etc/skel/.bashrc
	# root user is already there. Copy bashrc there as well
	cp "${SDCARD}"/etc/skel/.bashrc "${SDCARD}"/root

	# display welcome message at first root login
	touch "${SDCARD}"/root/.not_logged_in_yet

	if [[ ${DESKTOP_AUTOLOGIN} != no ]]; then
		# set desktop autologin
		touch "${SDCARD}"/root/.desktop_autologin
	fi

	# NOTE: this needs to be executed before family_tweaks
	local bootscript_src=${BOOTSCRIPT%%:*}
	local bootscript_dst=${BOOTSCRIPT##*:}

	# create extlinux config file
	if [[ $SRC_EXTLINUX == yes ]]; then
		mkdir -p $SDCARD/boot/extlinux
		cat <<-EOF > "$SDCARD/boot/extlinux/extlinux.conf"
		label ${VENDOR}
		  kernel /boot/$NAME_KERNEL
		  initrd /boot/$NAME_INITRD
	EOF
		if [[ -n $BOOT_FDT_FILE ]]; then
			if [[ $BOOT_FDT_FILE != "none" ]]; then
				echo "  fdt /boot/dtb/$BOOT_FDT_FILE" >> "$SDCARD/boot/extlinux/extlinux.conf"
			fi
		else
			echo "  fdtdir /boot/dtb/" >> "$SDCARD/boot/extlinux/extlinux.conf"
		fi
	else

		if [[ "${BOOTCONFIG}" != "none" ]]; then
			if [ -f "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" ]; then
				cp "${USERPATCHES_PATH}/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			else
				cp "${EXTER}/config/bootscripts/${bootscript_src}" "${SDCARD}/boot/${bootscript_dst}"
			fi
		fi

		if [[ -n $BOOTENV_FILE ]]; then
			if [[ -f $USERPATCHES_PATH/bootenv/$BOOTENV_FILE ]]; then
				cp "$USERPATCHES_PATH/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/orangepiEnv.txt
			elif [[ -f $EXTER/config/bootenv/$BOOTENV_FILE ]]; then
				cp "${EXTER}/config/bootenv/${BOOTENV_FILE}" "${SDCARD}"/boot/orangepiEnv.txt
			fi
		fi

		# TODO: modify $bootscript_dst or orangepiEnv.txt to make NFS boot universal
		# instead of copying sunxi-specific template
		if [[ $ROOTFS_TYPE == nfs ]]; then
			display_alert "Copying NFS boot script template"
			if [[ -f $USERPATCHES_PATH/nfs-boot.cmd ]]; then
				cp "$USERPATCHES_PATH"/nfs-boot.cmd "${SDCARD}"/boot/boot.cmd
			else
				cp "${EXTER}"/config/templates/nfs-boot.cmd.template "${SDCARD}"/boot/boot.cmd
			fi
		fi

		[[ -n $OVERLAY_PREFIX && -f "${SDCARD}"/boot/orangepiEnv.txt && $BRANCH =~ current|next ]] && \
			echo "overlay_prefix=$OVERLAY_PREFIX" >> "${SDCARD}"/boot/orangepiEnv.txt

		[[ -n $DEFAULT_OVERLAYS && -f "${SDCARD}"/boot/orangepiEnv.txt && $BRANCH =~ current|next ]] && \
			echo "overlays=${DEFAULT_OVERLAYS//,/ }" >> "${SDCARD}"/boot/orangepiEnv.txt

		[[ -n $BOOT_FDT_FILE && -f "${SDCARD}"/boot/orangepiEnv.txt ]] && \
			echo "fdtfile=${BOOT_FDT_FILE}" >> "${SDCARD}/boot/orangepiEnv.txt"

	fi

	# initial date for fake-hwclock
	date -u '+%Y-%m-%d %H:%M:%S' > "${SDCARD}"/etc/fake-hwclock.data

	echo "${HOST}" > "${SDCARD}"/etc/hostname

	# set hostname in hosts file
	cat <<-EOF > "${SDCARD}"/etc/hosts
	127.0.0.1   localhost
	127.0.1.1   $HOST
	::1         localhost $HOST ip6-localhost ip6-loopback
	fe00::0     ip6-localnet
	ff00::0     ip6-mcastprefix
	ff02::1     ip6-allnodes
	ff02::2     ip6-allrouters
	EOF

	cd $SRC

	# Prepare and export caching-related params common to all apt calls below, to maximize apt-cacher-ng usage
	export APT_EXTRA_DIST_PARAMS=""
	[[ $NO_APT_CACHER != yes ]] && APT_EXTRA_DIST_PARAMS="-o Acquire::http::Proxy=\"http://${APT_PROXY_ADDR:-localhost:3142}\" -o Acquire::http::Proxy::localhost=\"DIRECT\""

	display_alert "Cleaning" "package lists"
	chroot "${SDCARD}" /bin/bash -c "apt-get clean"

	display_alert "Updating" "package lists"
	chroot "${SDCARD}" /bin/bash -c "apt-get ${APT_EXTRA_DIST_PARAMS} update" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1

	display_alert "Temporarily disabling" "initramfs-tools hook for kernel"
	chroot "${SDCARD}" /bin/bash -c "chmod -v -x /etc/kernel/postinst.d/initramfs-tools" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1

	# install family packages
	if [[ -n ${PACKAGE_LIST_FAMILY} ]]; then
		display_alert "Installing PACKAGE_LIST_FAMILY packages" "${PACKAGE_LIST_FAMILY}"
		chroot "${SDCARD}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive  apt-get ${APT_EXTRA_DIST_PARAMS} -yqq --no-install-recommends install $PACKAGE_LIST_FAMILY" >> "${DEST}"/${LOG_SUBPATH}/install.log
	fi

	# install board packages
	if [[ -n ${PACKAGE_LIST_BOARD} ]]; then
		display_alert "Installing PACKAGE_LIST_BOARD packages" "${PACKAGE_LIST_BOARD}"
		chroot "${SDCARD}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive  apt-get ${APT_EXTRA_DIST_PARAMS} -yqq --no-install-recommends install $PACKAGE_LIST_BOARD" >> "${DEST}"/${LOG_SUBPATH}/install.log || { display_alert "Failed to install PACKAGE_LIST_BOARD" "${PACKAGE_LIST_BOARD}" "err"; exit 2; } 
	fi

	# remove family packages
	if [[ -n ${PACKAGE_LIST_FAMILY_REMOVE} ]]; then
		display_alert "Removing PACKAGE_LIST_FAMILY_REMOVE packages" "${PACKAGE_LIST_FAMILY_REMOVE}"
		chroot "${SDCARD}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive  apt-get ${APT_EXTRA_DIST_PARAMS} -yqq remove --auto-remove $PACKAGE_LIST_FAMILY_REMOVE" >> "${DEST}"/${LOG_SUBPATH}/install.log
	fi

	# remove board packages
	if [[ -n ${PACKAGE_LIST_BOARD_REMOVE} ]]; then
		display_alert "Removing PACKAGE_LIST_BOARD_REMOVE packages" "${PACKAGE_LIST_BOARD_REMOVE}"
		for PKG_REMOVE in ${PACKAGE_LIST_BOARD_REMOVE}; do
			chroot "${SDCARD}" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get ${APT_EXTRA_DIST_PARAMS} -yqq remove --auto-remove ${PKG_REMOVE}" >> "${DEST}"/${LOG_SUBPATH}/install.log
		done
	fi

	# install u-boot
	# @TODO: add install_bootloader() extension method, refactor into u-boot extension
	[[ "${BOOTCONFIG}" != "none" ]] && {
		if [[ "${REPOSITORY_INSTALL}" != *u-boot* ]]; then
			UBOOT_VER=$(dpkg --info "${DEB_STORAGE}/u-boot/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb" | grep Descr | awk '{print $(NF)}')
			install_deb_chroot "${DEB_STORAGE}/u-boot/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb"
		else
			UBOOT_VER=$(dpkg --info "${DEB_ORANGEPI}/u-boot/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb" | grep Descr | awk '{print $(NF)}')
			install_deb_chroot "${DEB_ORANGEPI}/u-boot/${CHOSEN_UBOOT}_${REVISION}_${ARCH}.deb" "orangepi"
		fi
	}

	call_extension_method "pre_install_kernel_debs"  << 'PRE_INSTALL_KERNEL_DEBS'
*called before installing the Armbian-built kernel deb packages*
It is not too late to `unset KERNELSOURCE` here and avoid kernel install.
PRE_INSTALL_KERNEL_DEBS

	# install kernel
	[[ -n $KERNELSOURCE ]] && {
		if [[ "${REPOSITORY_INSTALL}" != *kernel* ]]; then
			VER=$(dpkg --info "${DEB_STORAGE}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb" | awk -F"-" '/Source:/{print $2}')

			install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb"
			if [[ -f ${DEB_STORAGE}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb ]]; then
				install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb"
			fi
			if [[ $INSTALL_HEADERS == yes ]]; then
				install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KERNEL/image/headers}_${REVISION}_${ARCH}.deb"
			fi
		else
			VER=$(dpkg --info "${DEB_ORANGEPI}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb" | grep Descr | awk '{print $(NF)}')
			VER="${VER/-$LINUXFAMILY/}"

			install_deb_chroot "${DEB_ORANGEPI}/${CHOSEN_KERNEL}_${REVISION}_${ARCH}.deb" "orangepi"

			if [[ -f ${DEB_ORANGEPI}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb ]]; then
				install_deb_chroot "${DEB_ORANGEPI}/${CHOSEN_KERNEL/image/dtb}_${REVISION}_${ARCH}.deb" "orangepi"
			fi

			if [[ $INSTALL_HEADERS == yes ]]; then
				install_deb_chroot "${DEB_ORANGEPI}/${CHOSEN_KERNEL/image/headers}_${REVISION}_${ARCH}.deb" "orangepi"
			fi
		fi
	}

	call_extension_method "post_install_kernel_debs" << 'POST_INSTALL_KERNEL_DEBS'
*allow config to do more with the installed kernel/headers*
Called after packages, u-boot, kernel and headers installed in the chroot, but before the BSP is installed.
If `KERNELSOURCE` is (still?) unset after this, Armbian-built firmware will not be installed.
POST_INSTALL_KERNEL_DEBS

	# install board support packages
	if [[ "${REPOSITORY_INSTALL}" != *bsp* ]]; then
		install_deb_chroot "${DEB_STORAGE}/$RELEASE/${BSP_CLI_PACKAGE_FULLNAME}.deb" | tee "${DEST}"/${LOG_SUBPATH}/install.log 2>&1
	else
		install_deb_chroot "${DEB_ORANGEPI}/$RELEASE/${CHOSEN_ROOTFS}_${BSP_CLI_PACKAGE_FULLNAME}.deb" "orangepi"
	fi

	# install orangepi-desktop
	if [[ "${REPOSITORY_INSTALL}" != *orangepi-desktop* ]]; then
		if [[ $BUILD_DESKTOP == yes ]]; then
			install_deb_chroot "${DEB_STORAGE}/${RELEASE}/${CHOSEN_DESKTOP}_${REVISION}_all.deb"
			install_deb_chroot "${DEB_STORAGE}/${RELEASE}/${BSP_DESKTOP_PACKAGE_FULLNAME}.deb"
			# install display manager and PACKAGE_LIST_DESKTOP_FULL packages if enabled per board
			desktop_postinstall
		fi
	else
		if [[ $BUILD_DESKTOP == yes ]]; then
			install_deb_chroot "${CHOSEN_DESKTOP}" "orangepi"
			# install display manager and PACKAGE_LIST_DESKTOP_FULL packages if enabled per board
			desktop_postinstall
		fi
	fi

	# install orangepi-firmware
	if [[ "${REPOSITORY_INSTALL}" != *orangepi-firmware* ]]; then
		if [[ -f ${DEB_STORAGE}/orangepi-firmware_${REVISION}_all.deb ]]; then
			install_deb_chroot "${DEB_STORAGE}/orangepi-firmware_${REVISION}_all.deb"
		fi
	else
		if [[ -f ${DEB_STORAGE}/orangepi-firmware_${REVISION}_all.deb ]]; then
			install_deb_chroot "${DEB_ORANGEPI}/orangepi-firmware_${REVISION}_all.deb" "orangepi"
		fi
	fi

	# install orangepi-config
	if [[ "${PACKAGE_LIST_RM}" != *orangepi-config* ]]; then
		if [[ "${REPOSITORY_INSTALL}" != *orangepi-config* ]]; then
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "${DEB_STORAGE}/orangepi-config_${REVISION}_all.deb"
			fi
		else
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "${DEB_ORANGEPI}/orangepi-config_${REVISION}_all.deb" "orangepi"
			fi
		fi
	fi

	# install orangepi-zsh
	if [[ "${PACKAGE_LIST_RM}" != *orangepi-zsh* ]]; then
		if [[ "${REPOSITORY_INSTALL}" != *orangepi-zsh* ]]; then
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "${DEB_STORAGE}/orangepi-zsh_${REVISION}_all.deb"
			fi
		else
			if [[ $BUILD_MINIMAL != yes ]]; then
				install_deb_chroot "orangepi-zsh" "remote"
			fi
		fi
	fi

	# install kernel sources
	if [[ -f ${DEB_STORAGE}/${CHOSEN_KSRC}_${REVISION}_all.deb && $INSTALL_KSRC == yes ]]; then
		install_deb_chroot "${DEB_STORAGE}/${CHOSEN_KSRC}_${REVISION}_all.deb"
	elif [[ $INSTALL_KSRC == yes ]]; then
		display_alert "Please set BUILD_KSRC=yes to generate the kernel source package" "" "wrn"
	fi

	# install wireguard tools
	if [[ $WIREGUARD == yes ]]; then
		chroot "${SDCARD}" /bin/bash -c "apt-get -y -qq install wireguard-tools --no-install-recommends" >> "${DEST}"/debug/install.log 2>&1
	fi

	# freeze orangepi packages
	if [[ $BSPFREEZE == yes ]]; then
		display_alert "Freezing Orange Pi packages" "$BOARD" "info"
		chroot "${SDCARD}" /bin/bash -c "apt-mark hold ${CHOSEN_KERNEL} ${CHOSEN_KERNEL/image/headers} \
		linux-u-boot-${BOARD}-${BRANCH} ${CHOSEN_KERNEL/image/dtb}" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1
	fi

	# add orangepi user
	chroot "${SDCARD}" /bin/bash -c "adduser --quiet --disabled-password --shell /bin/bash --home /home/${OPI_USERNAME} --gecos ${OPI_USERNAME} ${OPI_USERNAME}"
	chroot "${SDCARD}" /bin/bash -c "(echo ${OPI_PWD};echo ${OPI_PWD};) | passwd "${OPI_USERNAME}" >/dev/null 2>&1"
	for additionalgroup in sudo netdev audio video disk tty users games dialout plugdev input bluetooth systemd-journal ssh; do
	        chroot "${SDCARD}" /bin/bash -c "usermod -aG ${additionalgroup} ${OPI_USERNAME} 2>/dev/null"
	done

	# fix for gksu in Xenial
	touch ${SDCARD}/home/${OPI_USERNAME}/.Xauthority
	chroot "${SDCARD}" /bin/bash -c "chown ${OPI_USERNAME}:${OPI_USERNAME} /home/${OPI_USERNAME}/.Xauthority"
	# set up profile sync daemon on desktop systems
	chroot "${SDCARD}" /bin/bash -c "which psd >/dev/null 2>&1"
	if [ $? -eq 0 ]; then
		echo -e "${OPI_USERNAME} ALL=(ALL) NOPASSWD: /usr/bin/psd-overlay-helper" >> ${SDCARD}/etc/sudoers
		touch ${SDCARD}/home/${OPI_USERNAME}/.activate_psd
		chroot "${SDCARD}" /bin/bash -c "chown $OPI_USERNAME:$OPI_USERNAME /home/${OPI_USERNAME}/.activate_psd"
	fi

	# remove deb files
	rm -f "${SDCARD}"/root/*.deb

	# copy boot splash images
	cp "${EXTER}"/packages/blobs/splash/orangepi-u-boot.bmp "${SDCARD}"/boot/boot.bmp

	# copy audio.wav and mute.wav
	mkdir -p "${SDCARD}"/usr/share/sounds/alsa/
	cp "${EXTER}"/packages/blobs/audio_wav/audio.wav "${SDCARD}"/usr/share/sounds/alsa/
	cp "${EXTER}"/packages/blobs/audio_wav/mute.wav "${SDCARD}"/usr/share/sounds/alsa/

	# copy watchdog test programm
	cp "${EXTER}"/packages/blobs/watchdog/watchdog_test_${ARCH} "${SDCARD}"/usr/local/bin/watchdog_test

	# execute $LINUXFAMILY-specific tweaks
	[[ $(type -t family_tweaks) == function ]] && family_tweaks

	call_extension_method "post_family_tweaks" << 'FAMILY_TWEAKS'
*customize the tweaks made by $LINUXFAMILY-specific family_tweaks*
It is run after packages are installed in the rootfs, but before enabling additional services.
It allows implementors access to the rootfs (`${SDCARD}`) in its pristine state after packages are installed.
FAMILY_TWEAKS

	# enable additional services
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable orangepi-firstrun.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable orangepi-firstrun-config.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable orangepi-zram-config.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable orangepi-hardware-optimize.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable orangepi-ramlog.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable orangepi-resize-filesystem.service >/dev/null 2>&1"
	chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable orangepi-hardware-monitor.service >/dev/null 2>&1"

	# copy "first run automated config, optional user configured"
 	cp ${EXTER}/packages/bsp/orangepi_first_run.txt.template "${SDCARD}"/boot/orangepi_first_run.txt.template

	## switch to beta repository at this stage if building nightly images
	#[[ $IMAGE_TYPE == nightly ]] \
	#&& echo "deb http://beta.orangepi.com $RELEASE main ${RELEASE}-utils ${RELEASE}-desktop" \
	#> "${SDCARD}"/etc/apt/sources.list.d/orangepi.list

	# Cosmetic fix [FAILED] Failed to start Set console font and keymap at first boot
	[[ -f "${SDCARD}"/etc/console-setup/cached_setup_font.sh ]] \
	&& sed -i "s/^printf '.*/printf '\\\033\%\%G'/g" "${SDCARD}"/etc/console-setup/cached_setup_font.sh
	[[ -f "${SDCARD}"/etc/console-setup/cached_setup_terminal.sh ]] \
	&& sed -i "s/^printf '.*/printf '\\\033\%\%G'/g" "${SDCARD}"/etc/console-setup/cached_setup_terminal.sh
	[[ -f "${SDCARD}"/etc/console-setup/cached_setup_keyboard.sh ]] \
	&& sed -i "s/-u/-x'/g" "${SDCARD}"/etc/console-setup/cached_setup_keyboard.sh

	# fix for https://bugs.launchpad.net/ubuntu/+source/blueman/+bug/1542723
	chroot "${SDCARD}" /bin/bash -c "chown root:messagebus /usr/lib/dbus-1.0/dbus-daemon-launch-helper"
	chroot "${SDCARD}" /bin/bash -c "chmod u+s /usr/lib/dbus-1.0/dbus-daemon-launch-helper"

	# disable samba NetBIOS over IP name service requests since it hangs when no network is present at boot
	chroot "${SDCARD}" /bin/bash -c "systemctl --quiet disable nmbd 2> /dev/null"

	# disable low-level kernel messages for non betas
	if [[ -z $BETA ]]; then
		sed -i "s/^#kernel.printk*/kernel.printk/" "${SDCARD}"/etc/sysctl.conf
	fi

	# disable repeated messages due to xconsole not being installed.
	[[ -f "${SDCARD}"/etc/rsyslog.d/50-default.conf ]] && \
	sed '/daemon\.\*\;mail.*/,/xconsole/ s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.d/50-default.conf

	# disable deprecated parameter
	sed '/.*$KLogPermitNonKernelFacility.*/,// s/.*/#&/' -i "${SDCARD}"/etc/rsyslog.conf

	# enable getty on multiple serial consoles
	# and adjust the speed if it is defined and different than 115200
	#
	# example: SERIALCON="ttyS0:15000000,ttyGS1"
	#
	ifs=$IFS
	for i in $(echo "${SERIALCON:-'ttyS0'}" | sed "s/,/ /g")
	do
		IFS=':' read -r -a array <<< "$i"
		[[ "${array[0]}" == "tty1" ]] && continue # Don't enable tty1 as serial console.
		display_alert "Enabling serial console" "${array[0]}" "info"
		# add serial console to secure tty list
		[ -z "$(grep -w '^${array[0]}' "${SDCARD}"/etc/securetty 2> /dev/null)" ] && \
		echo "${array[0]}" >>  "${SDCARD}"/etc/securetty
		if [[ ${array[1]} != "115200" && -n ${array[1]} ]]; then
			# make a copy, fix speed and enable
			cp "${SDCARD}"/lib/systemd/system/serial-getty@.service \
			"${SDCARD}/lib/systemd/system/serial-getty@${array[0]}.service"
			sed -i "s/--keep-baud 115200/--keep-baud ${array[1]},115200/" \
			"${SDCARD}/lib/systemd/system/serial-getty@${array[0]}.service"
		fi
		chroot "${SDCARD}" /bin/bash -c "systemctl daemon-reload" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1
		chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload enable serial-getty@${array[0]}.service" \
		>> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1
		if [[ "${array[0]}" == "ttyGS0" && $LINUXFAMILY == sun8i && $BRANCH == legacy ]]; then
			mkdir -p "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d
			cat <<-EOF > "${SDCARD}"/etc/systemd/system/serial-getty@ttyGS0.service.d/10-switch-role.conf
			[Service]
			ExecStartPre=-/bin/sh -c "echo 2 > /sys/bus/platform/devices/sunxi_usb_udc/otg_role"
			EOF
		fi
	done
	IFS=$ifs

	[[ $LINUXFAMILY == sun*i ]] && mkdir -p "${SDCARD}"/boot/overlay-user

	# to prevent creating swap file on NFS (needs specific kernel options)
	# and f2fs/btrfs (not recommended or needs specific kernel options)
	[[ $ROOTFS_TYPE != ext4 ]] && touch "${SDCARD}"/var/swap

	# install initial asound.state if defined
	mkdir -p "${SDCARD}"/var/lib/alsa/
	[[ -n $ASOUND_STATE ]] && cp "${EXTER}/packages/blobs/asound.state/${ASOUND_STATE}" "${SDCARD}"/var/lib/alsa/asound.state

	# save initial orangepi-release state
	cp "${SDCARD}"/etc/orangepi-release "${SDCARD}"/etc/orangepi-image-release

	# DNS fix. package resolvconf is not available everywhere
	if [ -d /etc/resolvconf/resolv.conf.d ] && [ -n "$NAMESERVER" ]; then
		echo "nameserver $NAMESERVER" > "${SDCARD}"/etc/resolvconf/resolv.conf.d/head
	fi

	# permit root login via SSH for the first boot
	sed -i 's/#\?PermitRootLogin .*/PermitRootLogin yes/' "${SDCARD}"/etc/ssh/sshd_config

	# enable PubkeyAuthentication
	sed -i 's/#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' "${SDCARD}"/etc/ssh/sshd_config

	if [ -f "${SDCARD}"/etc/NetworkManager/NetworkManager.conf ]; then
		# configure network manager
		sed "s/managed=\(.*\)/managed=true/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf

		# remove network manager defaults to handle eth by default
		rm -f "${SDCARD}"/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf

		# most likely we don't need to wait for nm to get online
		chroot "${SDCARD}" /bin/bash -c "systemctl disable NetworkManager-wait-online.service" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1

		# Just regular DNS and maintain /etc/resolv.conf as a file
		sed "/dns/d" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf
		sed "s/\[main\]/\[main\]\ndns=default\nrc-manager=file/g" -i "${SDCARD}"/etc/NetworkManager/NetworkManager.conf
		if [[ -n $NM_IGNORE_DEVICES ]]; then
			mkdir -p "${SDCARD}"/etc/NetworkManager/conf.d/
			cat <<-EOF > "${SDCARD}"/etc/NetworkManager/conf.d/10-ignore-interfaces.conf
			[keyfile]
			unmanaged-devices=$NM_IGNORE_DEVICES
			EOF
		fi

	elif [ -d "${SDCARD}"/etc/systemd/network ]; then
		# configure networkd
		rm "${SDCARD}"/etc/resolv.conf
		ln -s /run/systemd/resolve/resolv.conf "${SDCARD}"/etc/resolv.conf

		# enable services
		chroot "${SDCARD}" /bin/bash -c "systemctl enable systemd-networkd.service systemd-resolved.service" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1

		if  [ -e /etc/systemd/timesyncd.conf ]; then
			chroot "${SDCARD}" /bin/bash -c "systemctl enable systemd-timesyncd.service" >> "${DEST}"/${LOG_SUBPATH}/install.log 2>&1
		fi
		umask 022
		cat > "${SDCARD}"/etc/systemd/network/eth0.network <<- __EOF__
		[Match]
		Name=eth0

		[Network]
		#MACAddress=
		DHCP=ipv4
		LinkLocalAddressing=ipv4
		#Address=192.168.1.100/24
		#Gateway=192.168.1.1
		#DNS=192.168.1.1
		#Domains=example.com
		NTP=0.pool.ntp.org 1.pool.ntp.org
		__EOF__

	fi

	# avahi daemon defaults if exists
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service ]] && \
	cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/sftp-ssh.service "${SDCARD}"/etc/avahi/services/
	[[ -f "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service ]] && \
	cp "${SDCARD}"/usr/share/doc/avahi-daemon/examples/ssh.service "${SDCARD}"/etc/avahi/services/

	# nsswitch settings for sane DNS behavior: remove resolve, assure libnss-myhostname support
	sed "s/hosts\:.*/hosts:          files mymachines dns myhostname/g" -i "${SDCARD}"/etc/nsswitch.conf

	# build logo in any case
	boot_logo

	# disable MOTD for first boot - we want as clean 1st run as possible
	chmod -x "${SDCARD}"/etc/update-motd.d/*

}

install_rclocal()
{

	if [[ $BURN_IMAGE == yes ]]; then

		cat <<-EOF > "${SDCARD}"/etc/rc.local
		#!/bin/sh -e
		#
		# rc.local
		#
		# This script is executed at the end of each multiuser runlevel.
		# Make sure that the script will "exit 0" on success or any other
		# value on error.
		#
		# In order to enable or disable this script just change the execution
		# bits.
		#
		# By default this script does nothing.

		burn_to_emmc

		exit 0
		EOF

	else

		cat <<-EOF > "${SDCARD}"/etc/rc.local
		#!/bin/sh -e
		#
		# rc.local
		#
		# This script is executed at the end of each multiuser runlevel.
		# Make sure that the script will "exit 0" on success or any other
		# value on error.
		#
		# In order to enable or disable this script just change the execution
		# bits.
		#
		# By default this script does nothing.

		exit 0
		EOF

	fi
	chmod +x "${SDCARD}"/etc/rc.local

}

install_distribution_specific()
{

	display_alert "Applying distribution specific tweaks for" "$RELEASE" "info"

	case $RELEASE in

	xenial)

			# remove legal info from Ubuntu
			[[ -f "${SDCARD}"/etc/legal ]] && rm "${SDCARD}"/etc/legal

			# ureadahead needs kernel tracing options that AFAIK are present only in mainline. disable
			chroot "${SDCARD}" /bin/bash -c \
			"systemctl --no-reload mask ondemand.service ureadahead.service >/dev/null 2>&1"
			chroot "${SDCARD}" /bin/bash -c \
			"systemctl --no-reload mask setserial.service etc-setserial.service >/dev/null 2>&1"

		;;

	stretch|buster|sid)

			# remove doubled uname from motd
			[[ -f "${SDCARD}"/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname
			# rc.local is not existing but one might need it
			install_rclocal

		;;

	bullseye)

			# remove doubled uname from motd
			[[ -f "${SDCARD}"/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname
			# rc.local is not existing but one might need it
			install_rclocal
			# fix missing versioning
			[[ $(grep -L "VERSION_ID=" "${SDCARD}"/etc/os-release) ]] && echo 'VERSION_ID="11"' >> "${SDCARD}"/etc/os-release
			[[ $(grep -L "VERSION=" "${SDCARD}"/etc/os-release) ]] && echo 'VERSION="11 (bullseye)"' >> "${SDCARD}"/etc/os-release


		;;
	
	bookworm)

			# remove doubled uname from motd
			[[ -f "${SDCARD}"/etc/update-motd.d/10-uname ]] && rm "${SDCARD}"/etc/update-motd.d/10-uname
			# rc.local is not existing but one might need it
			install_rclocal
			# fix missing versioning
			[[ $(grep -L "VERSION_ID=" "${SDCARD}"/etc/os-release) ]] && echo 'VERSION_ID="12"' >> "${SDCARD}"/etc/os-release
			[[ $(grep -L "VERSION=" "${SDCARD}"/etc/os-release) ]] && echo 'VERSION="11 (bookworm)"' >> "${SDCARD}"/etc/os-release

			# remove security updates repository since it does not exists yet
			sed '/security/ d' -i "${SDCARD}"/etc/apt/sources.list

		;;

	bionic|focal|hirsute|impish|jammy)

			# by using default lz4 initrd compression leads to corruption, go back to proven method
			sed -i "s/^COMPRESS=.*/COMPRESS=gzip/" "${SDCARD}"/etc/initramfs-tools/initramfs.conf

			# cleanup motd services and related files
			chroot "${SDCARD}" /bin/bash -c "systemctl disable  motd-news.service >/dev/null 2>&1"
			chroot "${SDCARD}" /bin/bash -c "systemctl disable  motd-news.timer >/dev/null 2>&1"

			rm -f "${SDCARD}"/etc/update-motd.d/{10-uname,10-help-text,50-motd-news,80-esm,80-livepatch,90-updates-available,91-release-upgrade,95-hwe-eol}

			# remove motd news from motd.ubuntu.com
			[[ -f "${SDCARD}"/etc/default/motd-news ]] && sed -i "s/^ENABLED=.*/ENABLED=0/" "${SDCARD}"/etc/default/motd-news

			# rc.local is not existing but one might need it
			install_rclocal

			if [ -d "${SDCARD}"/etc/NetworkManager ]; then
				local RENDERER=NetworkManager
			else
				local RENDERER=networkd
			fi

			# Basic Netplan config. Let NetworkManager/networkd manage all devices on this system
			[[ -d "${SDCARD}"/etc/netplan ]] && cat <<-EOF > "${SDCARD}"/etc/netplan/orangepi-default.yaml
			network:
			  version: 2
			  renderer: $RENDERER
			EOF

			# DNS fix
			if [ -n "$NAMESERVER" ]; then
				sed -i "s/#DNS=.*/DNS=$NAMESERVER/g" "${SDCARD}"/etc/systemd/resolved.conf
			fi

			# Journal service adjustements
			sed -i "s/#Storage=.*/Storage=volatile/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#Compress=.*/Compress=yes/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#RateLimitIntervalSec=.*/RateLimitIntervalSec=30s/g" "${SDCARD}"/etc/systemd/journald.conf
			sed -i "s/#RateLimitBurst=.*/RateLimitBurst=10000/g" "${SDCARD}"/etc/systemd/journald.conf

			# Chrony temporal fix https://bugs.launchpad.net/ubuntu/+source/chrony/+bug/1878005
			sed -i '/DAEMON_OPTS=/s/"-F -1"/"-F 0"/' "${SDCARD}"/etc/default/chrony

			# disable conflicting services
			chroot "${SDCARD}" /bin/bash -c "systemctl --no-reload mask ondemand.service >/dev/null 2>&1"

		;;

	esac

	# use list modules INITRAMFS
	if [ -f "${EXTER}"/config/modules/"${MODULES_INITRD}" ]; then
		display_alert "Use file list modules INITRAMFS" "${MODULES_INITRD}"
		sed -i "s/^MODULES=.*/MODULES=list/" "${SDCARD}"/etc/initramfs-tools/initramfs.conf
		cat "${EXTER}"/config/modules/"${MODULES_INITRD}" >> "${SDCARD}"/etc/initramfs-tools/modules
	fi
}




post_debootstrap_tweaks()
{

	# remove service start blockers and QEMU binary
	rm -f "${SDCARD}"/sbin/initctl "${SDCARD}"/sbin/start-stop-daemon
	chroot "${SDCARD}" /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/initctl"
	chroot "${SDCARD}" /bin/bash -c "dpkg-divert --quiet --local --rename --remove /sbin/start-stop-daemon"
	rm -f "${SDCARD}"/usr/sbin/policy-rc.d "${SDCARD}/usr/bin/${QEMU_BINARY}"

	call_extension_method "post_post_debootstrap_tweaks" "config_post_debootstrap_tweaks" << 'POST_POST_DEBOOTSTRAP_TWEAKS'
*run after removing diversions and qemu with chroot unmounted*
Last chance to touch the `${SDCARD}` filesystem before it is copied to the final media.
It is too late to run any chrooted commands, since the supporting filesystems are already unmounted.
POST_POST_DEBOOTSTRAP_TWEAKS

}
