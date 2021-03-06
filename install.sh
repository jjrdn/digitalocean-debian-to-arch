#!/bin/bash

################################################################################
### INSTRUCTIONS AT https://github.com/gh2o/digitalocean-debian-to-arch/     ###
################################################################################

run_from_file() {
	local f t
	for f in /dev/fd/*; do
		[ -h ${f} ] || continue
		[ ${f} -ef "${0}" ] && return
	done
	t=$(mktemp)
	cat >${t}
	if [ "$(head -n 1 ${t})" = '#!/bin/bash' ]; then
		chmod +x ${t}
		exec /bin/bash ${t} "$@" </dev/fd/2
	else
		rm -f ${t}
		echo "Direct execution not supported with this shell ($_)." >&2
		echo "Please try bash instead." >&2
		exit 1
	fi
}

# do not modify the two lines below
[ -h /dev/fd/0 ] && run_from_file
#!/bin/bash

########################################
### CONFIGURATION                    ###
########################################

# mirror from which to download packages
archlinux_mirror="https://mirrors.kernel.org/archlinux/"

# migrate over home directories
preserve_home_directories=true

# package to use as kernel (linux or linux-lts)
kernel_package=linux

# migrated machine architecture
target_architecture="$(uname -m)"

########################################
### END OF CONFIGURATION             ###
########################################

if [ -n "${POSIXLY_CORRECT}" ] || [ -z "${BASH_VERSION}" ]; then
	unset POSIXLY_CORRECT
	exec /bin/bash "${0}" "$@"
	exit 1
fi

set -eu
set -o pipefail
shopt -s nullglob
shopt -s dotglob

export LC_ALL=C
export LANG=C
unset LANGUAGE

declare -a repositories
repositories=(core extra)
declare -A dependencies
dependencies[pacman]=x
dependencies[coreutils]=x
declare -A pkgdircache

log() {
	echo "[$(date)]" "$@" >&2
}

mask_to_prefix() {
	local prefix=0 netmask=${1}
	for octet in ${netmask//./ }; do
		for bitmask in 128 64 32 16 8 4 2 1; do
			(( $bitmask & $octet )) && (( prefix+=1 )) || break 2
		done
	done
	echo ${prefix}
}

parse_debian_interfaces() {
	local filename="${1}"  # path to interfaces file
	local interface="${2}" # interface name
	local addrtype="${3}"  # inet or inet6
	local found=false address= prefix= gateway=
	local kw args
	while read kw args; do
		if ! ${found}; then
			if [ "${kw}" = "iface" ] && \
			   [ "${args}" = "${interface} ${addrtype} static" ]; then
				found=true
			fi
			continue
		fi
		case ${kw} in
			iface)
				break
				;;
			address)
				address="${args}"
				;;
			netmask)
				if [ "${args/.}" != "${args}" ]; then
					prefix=$(mask_to_prefix "${args}")
				else
					prefix="${args}"
				fi
				;;
			gateway)
				gateway="${args}"
				;;
		esac
	done <"${filename}"
	echo "local pdi_found=${found};"
	echo "local pdi_address='${address}';"
	echo "local pdi_prefix='${prefix}';"
	echo "local pdi_gateway='${gateway}';"
}

clean_archroot() {
	local file
	local prompted=false
	local lsfd
	while read file <&${lsfd}; do
		if [ "${file}" = "installer" ] || [ "${file}" = "packages" ]; then
			continue
		fi
		if ! $prompted; then
			log "Your /archroot directory contains a stale installation or other data."
			log "Remove it?"
			local response
			read -p '([yes] or no) ' response
			if [[ "yes" == "${response}"* ]]; then
				prompted=true
			else
				break
			fi
		fi
		rm -rf "/archroot/${file}"
	done {lsfd}< <(ls /archroot)
}

install_haveged() {
	if which haveged >/dev/null 2>&1; then
		return
	fi
	log "Creating keys for pacman will be very slow because"
	log "KVM lacks true sources of ramdomness. Install haveged"
	log "to speed it up?"
	local response
	read -p '([yes] or no) ' response
	if [[ "yes" == "${response}"* ]]; then
		apt-get -y install haveged
	fi
}

remove_version() {
	echo "${1}" | grep -o '^[A-Za-z0-9_-]*'
}

initialize_databases() {
	local repo dir pkg
	for repo in "${repositories[@]}"; do
		log "Downloading package database '${repo}' ..."
		wget "${archlinux_mirror}/${repo}/os/${target_architecture}/${repo}.db"
		log "Unpacking package database '${repo}' ..."
		mkdir ${repo}
		tar -zxf ${repo}.db -C ${repo}
	done
}

get_package_directory() {

	local req="${1}"
	local repo dir pkg

	dir="${pkgdircache[${req}]:-}"
	if [ -n "${dir}" ]; then
		echo "${dir}"
		return
	fi

	for repo in "${repositories[@]}"; do
		for dir in ${repo}/${req}-*; do
			pkg="$(get_package_value ${dir}/desc NAME)" 
			pkgdircache[${pkg}]="${dir}"
			if [ "${pkg}" = "${req}" ]; then
				echo "${dir}"
				return
			fi
		done
	done

	for repo in "${repositories[@]}"; do
		for dir in ${repo}/*; do
			while read pkg; do
				pkg=$(remove_version "${pkg}")
				[ -z "${pkgdircache[${pkg}]:-}" ] &&
					pkgdircache[${pkg}]="${dir}"
				if [ "${pkg}" = "${req}" ]; then
					echo "${dir}"
					return
				fi
			done < <(get_package_array ${dir}/depends PROVIDES)
		done
	done

	log "Package '${req}' not found."
	false

}

get_package_value() {
	local infofile=${1}
	local infokey=${2}
	get_package_array ${infofile} ${infokey} | (
		local value
		read value
		echo "${value}"
	)
}

get_package_array() {
	local infofile=${1}
	local infokey=${2}
	local line
	while read line; do
		if [ "${line}" = "%${infokey}%" ]; then
			while read line; do
				if [ -z "${line}" ]; then
					return
				fi
				echo "${line}"
			done
		fi
	done < ${infofile}
}

calculate_dependencies() {
	log "Calculating dependencies ..."
	local dirty=true
	local pkg dir dep
	while $dirty; do
		dirty=false
		for pkg in "${!dependencies[@]}"; do
			dir=$(get_package_directory $pkg)
			while read line; do
				dep=$(remove_version "${line}")
				if [ -z "${dependencies[$dep]:-}" ]; then
					dependencies[$dep]=x
					dirty=true
				fi
			done < <(get_package_array ${dir}/depends DEPENDS)
		done
	done
}

download_packages() {
	log "Downloading packages ..."
	mkdir -p /archroot/packages
	local pkg dir filename sha256 localfn
	for pkg in "${!dependencies[@]}"; do
		dir=$(get_package_directory ${pkg})
		filename=$(get_package_value ${dir}/desc FILENAME)
		sha256=$(get_package_value ${dir}/desc SHA256SUM)
		localfn=/archroot/packages/${filename}
		if [ -e "${localfn}" ] && ( echo "${sha256}  ${localfn}" | sha256sum -c ); then
			continue
		fi
		wget "${archlinux_mirror}/pool/packages/${filename}" -O "${localfn}"
		if [ -e "${localfn}" ] && ( echo "${sha256}  ${localfn}" | sha256sum -c ); then
			continue
		fi
		log "Couldn't download package '${pkg}'."
		false
	done
}

extract_packages() {
	log "Extracting packages ..."
	local dir filename
	for pkg in "${!dependencies[@]}"; do
		dir=$(get_package_directory ${pkg})
		filename=$(get_package_value ${dir}/desc FILENAME)
		xz -dc /archroot/packages/${filename} | tar -C /archroot -xf -
	done
}

mount_virtuals() {
	log "Mounting virtual filesystems ..."
	mount -t proc proc /archroot/proc
	mount -t sysfs sys /archroot/sys
	mount --bind /dev /archroot/dev
	mount -t devpts pts /archroot/dev/pts
}

prebootstrap_configuration() {
	log "Doing pre-bootstrap configuration ..."
	rmdir /archroot/var/cache/pacman/pkg
	ln -s ../../../packages /archroot/var/cache/pacman/pkg
	chroot /archroot /sbin/trust extract-compat
}

bootstrap_system() {

	local shouldbootstrap=false isbootstrapped=false
	while ! $isbootstrapped; do
		if $shouldbootstrap; then
			log "Bootstrapping system ..."
			chroot /archroot pacman-key --init
			chroot /archroot pacman-key --populate archlinux
			chroot /archroot pacman -Sy
			chroot /archroot pacman -S --force --noconfirm \
				$(chroot /archroot pacman -Sgq base | grep -Fvx linux) \
				${kernel_package} openssh kexec-tools
			isbootstrapped=true
		else
			shouldbootstrap=true
		fi
		# config overwritten by pacman
		rm -f /archroot/etc/resolv.conf.pacorig
		cp /etc/resolv.conf /archroot/etc/resolv.conf
		rm -f /archroot/etc/pacman.d/mirrorlist.pacorig
		echo "Server = ${archlinux_mirror}"'/$repo/os/$arch' \
			>> /archroot/etc/pacman.d/mirrorlist
	done

}

postbootstrap_configuration() {

	log "Doing post-bootstrap configuration ..."

	# set up fstab
	echo "LABEL=DOROOT / ext4 defaults 0 1" >> /archroot/etc/fstab

	# set up hostname
	[ -e /etc/hostname ] && cp /etc/hostname /archroot/etc/hostname

	# set up shadow
	(
		umask 077
		{
			grep    '^root:' /etc/shadow
			grep -v '^root:' /archroot/etc/shadow
		} > /archroot/etc/shadow.new
		cat /archroot/etc/shadow.new > /archroot/etc/shadow
		rm /archroot/etc/shadow.new
	)

	# set up internet network
	local eni=/etc/network/interfaces
	{
		cat <<-EOF
			[Match]
			Name=eth0

			[Network]
		EOF
		# add IPv4 addresses
		eval "$(parse_debian_interfaces ${eni} eth0 inet)"
		local v4_found=${pdi_found}
		if ${v4_found}; then
			cat <<-EOF
				Address=${pdi_address}/${pdi_prefix}
				Gateway=${pdi_gateway}
			EOF
		else
			log "Failed to determine IPv4 settings!"
		fi
		# add IPv6 addresses
		eval "$(parse_debian_interfaces ${eni} eth0 inet6)"
		local v6_found=${pdi_found}
		if ${v6_found}; then
			cat <<-EOF
				Address=${pdi_address}/${pdi_prefix}
				Gateway=${pdi_gateway}
			EOF
		fi
		# add DNS servers
		if ${v6_found}; then
			cat <<-EOF
				DNS=2001:4860:4860::8888
				DNS=2001:4860:4860::8844
			EOF
		else
			cat <<-EOF
				DNS=8.8.8.8
				DNS=8.8.4.4
			EOF
		fi
		cat <<-EOF
			DNS=209.244.0.3
		EOF
	} >/archroot/etc/systemd/network/internet.network

	# set up private network
	eval "$(parse_debian_interfaces ${eni} eth1 inet)"
	if ${pdi_found}; then
		cat >/archroot/etc/systemd/network/private.network <<-EOF
			[Match]
			Name=eth1

			[Network]
			Address=${pdi_address}/${pdi_prefix}
		EOF
	fi

	# copy over ssh keys
	cp -p /etc/ssh/ssh_*_key{,.pub} /archroot/etc/ssh/

	# optionally preserve home directories
	if ${preserve_home_directories}; then
		rm -rf /archroot/{home,root}
		cp -al /{home,root} /archroot/
	fi

	# setup machine id
	chroot /archroot systemd-machine-id-setup

	# enable services
	chroot /archroot systemctl enable systemd-networkd
	chroot /archroot systemctl enable sshd

	# install services
	local unitdir=/archroot/etc/systemd/system

	mkdir -p ${unitdir}/basic.target.wants
	ln -s ../installer-cleanup.service ${unitdir}/basic.target.wants/
	cat > ${unitdir}/installer-cleanup.service <<EOF
[Unit]
Description=Post-install cleanup
ConditionPathExists=/installer/script.sh

[Service]
Type=oneshot
ExecStart=/installer/script.sh
EOF

	mkdir -p ${unitdir}/sysinit.target.wants
	ln -s ../arch-kernel.service ${unitdir}/sysinit.target.wants
	cat > ${unitdir}/arch-kernel.service <<EOF
[Unit]
Description=Reboots into arch kernel
ConditionKernelCommandLine=!archkernel
DefaultDependencies=no
Before=local-fs-pre.target systemd-remount-fs.service

[Service]
Type=oneshot
ExecStart=/sbin/kexec /boot/vmlinuz-${kernel_package} --initrd=/boot/initramfs-${kernel_package}.img --reuse-cmdline --command-line=archkernel
EOF

}

installer_error_occurred() {
	log "Error occurred. Exiting."
}

installer_exit_cleanup() {
	log "Cleaning up ..."
	set +e
	umount /archroot/dev/pts
	umount /archroot/dev
	umount /archroot/sys
	umount /archroot/proc
}

installer_main() {

	if [ "${EUID}" -ne 0 ] || [ "${UID}" -ne 0 ]; then
		log "Script must be run as root. Exiting."
		exit 1
	fi

	if ! grep -q '^7\.' /etc/debian_version; then
		log "This script only supports Debian 7.x. Exiting."
		exit 1
	fi

	trap installer_error_occurred ERR
	trap installer_exit_cleanup EXIT

	log "Ensuring correct permissions ..."
	chmod 0700 "${script_path}"

	rm -rf /archroot/installer
	mkdir -p /archroot/installer
	cd /archroot/installer

	clean_archroot
	install_haveged

	initialize_databases
	calculate_dependencies
	download_packages
	extract_packages

	mount_virtuals
	prebootstrap_configuration
	bootstrap_system
	postbootstrap_configuration

	# prepare for transtiory_main
	mv /sbin/init /sbin/init.original
	cp "${script_path}" /sbin/init
	reboot

}

transitory_exit_occurred() {
	# not normally called
	log "Error occurred! You're on your own."
	exec /bin/bash
}

transitory_main() {

	trap transitory_exit_occurred EXIT
	if [ "${script_path}" = "/sbin/init" ]; then
		# save script
		mount -o remount,rw /
		cp "${script_path}" /archroot/installer/script.sh
		# restore init in case anything goes wrong
		rm /sbin/init
		mv /sbin/init.original /sbin/init
		# unmount other filesystems
		if ! [ -e /proc/mounts ]; then
			mount -t proc proc /proc
		fi
		local device mountpoint fstype ignored
		while IFS=" " read device mountpoint fstype ignored; do
			if [ "${device}" == "${device/\//}" ] && [ "${fstype}" != "rootfs" ]; then
				umount -l "${mountpoint}"
			fi
		done < <(tac /proc/mounts)
		# mount real root
		mkdir /archroot/realroot
		mount --bind / /archroot/realroot
		# chroot into archroot
		exec chroot /archroot /installer/script.sh
	elif [ "${script_path}" = "/installer/script.sh" ]; then
		# now in archroot
		local oldroot=/realroot/archroot/oldroot
		mkdir ${oldroot}
		# move old files into oldroot
		log "Backing up old root ..."
		local entry
		for entry in /realroot/*; do
			if [ "${entry}" != "/realroot/archroot" ]; then
				mv "${entry}" ${oldroot}
			fi
		done
		# hardlink files into realroot
		log "Populating new root ..."
		cd /
		mv ${oldroot} /realroot
		for entry in /realroot/archroot/*; do
			if [ "${entry}" != "/realroot/archroot/realroot" ]; then
				cp -al "${entry}" /realroot
			fi
		done
		# done!
		log "Rebooting ..."
		mount -t proc proc /proc
		mount -o remount,ro /realroot
		sync
		umount /proc
		reboot -f
	else
		log "Unknown state! You're own your own."
		exec /bin/bash
	fi

}

postinstall_main() {

	# remove cleanup service
	local unitdir=/etc/systemd/system
	rm -f ${unitdir}/installer-cleanup.service
	rm -f ${unitdir}/basic.target.wants/installer-cleanup.service

	# cleanup filesystem
	rm -f /var/cache/pacman/pkg
	mv /packages /var/cache/pacman/pkg
	rm -f /.INSTALL /.MTREE /.PKGINFO
	rm -rf /archroot
	rm -rf /installer

}

canonicalize_path() {
	local basename="$(basename "${1}")"
	local dirname="$(dirname "${1}")"
	(
		cd "${dirname}"
		echo "$(pwd -P)/${basename}"
	)
}

script_path="$(canonicalize_path "${0}")"
if [ $$ -eq 1 ]; then
	transitory_main "$@"
elif [ "${script_path}" = "/sbin/init" ]; then
	exec /sbin/init.original "$@"
elif [ "${script_path}" = "/installer/script.sh" ]; then
	postinstall_main "$@"
else
	installer_main "$@"
fi
exit 0 # in case junk appended

#################
# END OF SCRIPT #
#################
