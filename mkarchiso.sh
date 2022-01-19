#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -e -u

# Control the environment
umask 0022
export LC_ALL="C"
[[ -v SOURCE_DATE_EPOCH ]] || printf -v SOURCE_DATE_EPOCH '%(%s)T' -1
export SOURCE_DATE_EPOCH

# Set application name from the script's file name
app_name="${0##*/}"

# Define global variables. All of them will be overwritten later
pkg_list=()
bootstrap_pkg_list=()
quiet=""
work_dir=""
out_dir=""
gpg_key=""
gpg_sender=""
iso_name=""
iso_label=""
iso_publisher=""
iso_application=""
iso_version=""
install_dir=""
arch=""
pacman_conf=""
packages=""
bootstrap_packages=""
pacstrap_dir=""
buildmodes=()
bootmodes=()
airootfs_image_type=""
airootfs_image_tool_options=()
cert_list=()
sign_netboot_artifacts=""
declare -A file_permissions=()
# adapted from GRUB_EARLY_INITRD_LINUX_STOCK in https://git.savannah.gnu.org/cgit/grub.git/tree/util/grub-mkconfig.in
readonly ucodes=('intel-uc.img' 'intel-ucode.img' 'amd-uc.img' 'amd-ucode.img' 'early_ucode.cpio' 'microcode.cpio')


# Show an INFO message
# $1: message string
_msg_info() {
    local _msg="${1}"
    [[ "${quiet}" == "y" ]] || printf '[%s] INFO: %s\n' "${app_name}" "${_msg}"
}

# Show a WARNING message
# $1: message string
_msg_warning() {
    local _msg="${1}"
    printf '[%s] WARNING: %s\n' "${app_name}" "${_msg}" >&2
}

# Show an ERROR message then exit with status
# $1: message string
# $2: exit code number (with 0 does not exit)
_msg_error() {
    local _msg="${1}"
    local _error=${2}
    printf '[%s] ERROR: %s\n' "${app_name}" "${_msg}" >&2
    if (( _error > 0 )); then
        exit "${_error}"
    fi
}

# Show help usage, with an exit status.
# $1: exit status number.
_usage() {
    IFS='' read -r -d '' usagetext <<ENDUSAGETEXT || true
usage: ${app_name} [options] <profile_dir>
  options:
     -A <application> Set an application name for the ISO
                      Default: '${iso_application}'
     -C <file>        pacman configuration file.
                      Default: '${pacman_conf}'
     -D <install_dir> Set an install_dir. All files will by located here.
                      Default: '${install_dir}'
                      NOTE: Max 8 characters, use only [a-z0-9]
     -L <label>       Set the ISO volume label
                      Default: '${iso_label}'
     -P <publisher>   Set the ISO publisher
                      Default: '${iso_publisher}'
     -c [cert ..]     Provide certificates for codesigning of netboot artifacts
                      Multiple files are provided as quoted, space delimited list.
                      The first file is considered as the signing certificate,
                      the second as the key.
     -g <gpg_key>     Set the PGP key ID to be used for signing the rootfs image.
                      Passed to gpg as the value for --default-key
     -G <mbox>        Set the PGP signer (must include an email address)
                      Passed to gpg as the value for --sender
     -h               This message
     -m [mode ..]     Build mode(s) to use (valid modes are: 'bootstrap', 'iso' and 'netboot').
                      Multiple build modes are provided as quoted, space delimited list.
     -o <out_dir>     Set the output directory
                      Default: '${out_dir}'
     -p [package ..]  Package(s) to install.
                      Multiple packages are provided as quoted, space delimited list.
     -v               Enable verbose output
     -w <work_dir>    Set the working directory
                      Default: '${work_dir}'

  profile_dir:        Directory of the archiso profile to build
ENDUSAGETEXT
    printf '%s' "${usagetext}"
    exit "${1}"
}

# Shows configuration options.
_show_config() {
    local build_date
    printf -v build_date '%(%FT%R%z)T' "${SOURCE_DATE_EPOCH}"
    _msg_info "${app_name} configuration settings"
    _msg_info "             Architecture:   ${arch}"
    _msg_info "        Working directory:   ${work_dir}"
    _msg_info "   Installation directory:   ${install_dir}"
    _msg_info "               Build date:   ${build_date}"
    _msg_info "         Output directory:   ${out_dir}"
    _msg_info "       Current build mode:   ${buildmode}"
    _msg_info "              Build modes:   ${buildmodes[*]}"
    _msg_info "                  GPG key:   ${gpg_key:-None}"
    _msg_info "               GPG signer:   ${gpg_sender:-None}"
    _msg_info "Code signing certificates:   ${cert_list[*]:-None}"
    _msg_info "                  Profile:   ${profile}"
    _msg_info "Pacman configuration file:   ${pacman_conf}"
    _msg_info "          Image file name:   ${image_name:-None}"
    _msg_info "         ISO volume label:   ${iso_label}"
    _msg_info "            ISO publisher:   ${iso_publisher}"
    _msg_info "          ISO application:   ${iso_application}"
    _msg_info "               Boot modes:   ${bootmodes[*]:-None}"
    _msg_info "            Packages File:   ${buildmode_packages}"
    _msg_info "                 Packages:   ${buildmode_pkg_list[*]}"
}

# Cleanup airootfs
_cleanup_pacstrap_dir() {
    _msg_info "Cleaning up in pacstrap location..."

    # Delete all files in /boot
    [[ -d "${pacstrap_dir}/boot" ]] && find "${pacstrap_dir}/boot" -mindepth 1 -delete
    # Delete pacman database sync cache files (*.tar.gz)
    [[ -d "${pacstrap_dir}/var/lib/pacman" ]] && find "${pacstrap_dir}/var/lib/pacman" -maxdepth 1 -type f -delete
    # Delete pacman database sync cache
    [[ -d "${pacstrap_dir}/var/lib/pacman/sync" ]] && find "${pacstrap_dir}/var/lib/pacman/sync" -delete
    # Delete pacman package cache
    [[ -d "${pacstrap_dir}/var/cache/pacman/pkg" ]] && find "${pacstrap_dir}/var/cache/pacman/pkg" -type f -delete
    # Delete all log files, keeps empty dirs.
    [[ -d "${pacstrap_dir}/var/log" ]] && find "${pacstrap_dir}/var/log" -type f -delete
    # Delete all temporary files and dirs
    [[ -d "${pacstrap_dir}/var/tmp" ]] && find "${pacstrap_dir}/var/tmp" -mindepth 1 -delete
    # Delete package pacman related files.
    find "${work_dir}" \( -name '*.pacnew' -o -name '*.pacsave' -o -name '*.pacorig' \) -delete
    # Create an empty /etc/machine-id
    rm -f -- "${pacstrap_dir}/etc/machine-id"
    printf '' > "${pacstrap_dir}/etc/machine-id"

    _msg_info "Done!"
}

# Create a squashfs image and place it in the ISO 9660 file system.
# $@: options to pass to mksquashfs
_run_mksquashfs() {
    local mksquashfs_options=() image_path="${isofs_dir}/${install_dir}/${arch}/airootfs.sfs"
    rm -f -- "${image_path}"
    [[ ! "${quiet}" == "y" ]] || mksquashfs_options+=('-no-progress' '-quiet')
    mksquashfs "$@" "${image_path}" -noappend "${airootfs_image_tool_options[@]}" "${mksquashfs_options[@]}"
}

# Create an ext4 image containing the root file system and pack it inside a squashfs image.
# Save the squashfs image on the ISO 9660 file system.
_mkairootfs_ext4+squashfs() {
    local ext4_hash_seed mkfs_ext4_options=()
    [[ -e "${pacstrap_dir}" ]] || _msg_error "The path '${pacstrap_dir}' does not exist" 1

    _msg_info "Creating ext4 image of 32 GiB and copying '${pacstrap_dir}/' to it..."

    ext4_hash_seed="$(uuidgen --sha1 --namespace 93a870ff-8565-4cf3-a67b-f47299271a96 \
        --name "${SOURCE_DATE_EPOCH} ext4 hash seed")"
    mkfs_ext4_options=(
        '-d' "${pacstrap_dir}"
        '-O' '^has_journal,^resize_inode'
        '-E' "lazy_itable_init=0,root_owner=0:0,hash_seed=${ext4_hash_seed}"
        '-m' '0'
        '-F'
        '-U' 'clear'
    )
    [[ ! "${quiet}" == "y" ]] || mkfs_ext4_options+=('-q')
    rm -f -- "${pacstrap_dir}.img"
    E2FSPROGS_FAKE_TIME="${SOURCE_DATE_EPOCH}" mkfs.ext4 "${mkfs_ext4_options[@]}" -- "${pacstrap_dir}.img" 32G
    tune2fs -c 0 -i 0 -- "${pacstrap_dir}.img" > /dev/null
    _msg_info "Done!"

    install -d -m 0755 -- "${isofs_dir}/${install_dir}/${arch}"
    _msg_info "Creating SquashFS image, this may take some time..."
    _run_mksquashfs "${pacstrap_dir}.img"
    _msg_info "Done!"
    rm -- "${pacstrap_dir}.img"
}

# Create a squashfs image containing the root file system and saves it on the ISO 9660 file system.
_mkairootfs_squashfs() {
[[ -e ${profile}/chroot.sh ]] && ${profile}/chroot.sh
    [[ -e "${pacstrap_dir}" ]] || _msg_error "The path '${pacstrap_dir}' does not exist" 1

    install -d -m 0755 -- "${isofs_dir}/${install_dir}/${arch}"
    _msg_info "Creating SquashFS image, this may take some time..."
    _run_mksquashfs "${pacstrap_dir}"
}

# Create an EROFS image containing the root file system and saves it on the ISO 9660 file system.
_mkairootfs_erofs() {
    local fsuuid mkfs_erofs_options=()
    [[ -e "${pacstrap_dir}" ]] || _msg_error "The path '${pacstrap_dir}' does not exist" 1

    install -d -m 0755 -- "${isofs_dir}/${install_dir}/${arch}"
    local image_path="${isofs_dir}/${install_dir}/${arch}/airootfs.erofs"
    rm -f -- "${image_path}"
    [[ ! "${quiet}" == "y" ]] || mkfs_erofs_options+=('--quiet')
    # Generate reproducible file system UUID from SOURCE_DATE_EPOCH
    fsuuid="$(uuidgen --sha1 --namespace 93a870ff-8565-4cf3-a67b-f47299271a96 --name "${SOURCE_DATE_EPOCH}")"
    mkfs_erofs_options+=('-U' "${fsuuid}" "${airootfs_image_tool_options[@]}")
    _msg_info "Creating EROFS image, this may take some time..."
    mkfs.erofs "${mkfs_erofs_options[@]}" -- "${image_path}" "${pacstrap_dir}"
    _msg_info "Done!"
}

# Create checksum file for the rootfs image.
_mkchecksum() {
    _msg_info "Creating checksum file for self-test..."
    cd -- "${isofs_dir}/${install_dir}/${arch}"
    if [[ -e "${isofs_dir}/${install_dir}/${arch}/airootfs.sfs" ]]; then
        sha512sum airootfs.sfs > airootfs.sha512
    elif [[ -e "${isofs_dir}/${install_dir}/${arch}/airootfs.erofs" ]]; then
        sha512sum airootfs.erofs > airootfs.sha512
    fi
    cd -- "${OLDPWD}"
    _msg_info "Done!"
}

# GPG sign the root file system image.
_mksignature() {
    local airootfs_image_filename gpg_options=()
    _msg_info "Signing rootfs image..."
    if [[ -e "${isofs_dir}/${install_dir}/${arch}/airootfs.sfs" ]]; then
        airootfs_image_filename="${isofs_dir}/${install_dir}/${arch}/airootfs.sfs"
    elif [[ -e "${isofs_dir}/${install_dir}/${arch}/airootfs.erofs" ]]; then
        airootfs_image_filename="${isofs_dir}/${install_dir}/${arch}/airootfs.erofs"
    fi
    rm -f -- "${airootfs_image_filename}.sig"
    # Add gpg sender option if the value is provided
    [[ -z "${gpg_sender}" ]] || gpg_options+=('--sender' "${gpg_sender}")
    # always use the .sig file extension, as that is what mkinitcpio-archiso's hooks expect
    gpg --batch --no-armor --no-include-key-block --output "${airootfs_image_filename}.sig" --detach-sign \
        --default-key "${gpg_key}" "${gpg_options[@]}" "${airootfs_image_filename}"
    _msg_info "Done!"
}

# Helper function to run functions only one time.
# $1: function name
_run_once() {
    if [[ ! -e "${work_dir}/${run_once_mode}.${1}" ]]; then
        "$1"
        touch "${work_dir}/${run_once_mode}.${1}"
    fi
}

# Set up custom pacman.conf with custom cache and pacman hook directories.
_make_pacman_conf() {
    local _cache_dirs _system_cache_dirs _profile_cache_dirs
    _system_cache_dirs="$(pacman-conf CacheDir| tr '\n' ' ')"
    _profile_cache_dirs="$(pacman-conf --config "${pacman_conf}" CacheDir| tr '\n' ' ')"

    # Only use the profile's CacheDir, if it is not the default and not the same as the system cache dir.
    if [[ "${_profile_cache_dirs}" != "/var/cache/pacman/pkg" ]] && \
        [[ "${_system_cache_dirs}" != "${_profile_cache_dirs}" ]]; then
        _cache_dirs="${_profile_cache_dirs}"
    else
        _cache_dirs="${_system_cache_dirs}"
    fi

    _msg_info "Copying custom pacman.conf to work directory..."
    _msg_info "Using pacman CacheDir: ${_cache_dirs}"
    # take the profile pacman.conf and strip all settings that would break in chroot when using pacman -r
    # append CacheDir and HookDir to [options] section
    # HookDir is *always* set to the airootfs' override directory
    # see `man 8 pacman` for further info
    pacman-conf --config "${pacman_conf}" | \
        sed "/CacheDir/d;/DBPath/d;/HookDir/d;/LogFile/d;/RootDir/d;/\[options\]/a CacheDir = ${_cache_dirs}
        /\[options\]/a HookDir = ${pacstrap_dir}/etc/pacman.d/hooks/" > "${work_dir}/${buildmode}.pacman.conf"
}

# Prepare working directory and copy custom root file system files.
_make_custom_airootfs() {
    local passwd=()
    local filename permissions

    install -d -m 0755 -o 0 -g 0 -- "${pacstrap_dir}"

    if [[ -d "${profile}/airootfs" ]]; then
        _msg_info "Copying custom airootfs files..."
        cp -af --no-preserve=ownership,mode -- "${profile}/airootfs/." "${pacstrap_dir}"
        # Set ownership and mode for files and directories
        for filename in "${!file_permissions[@]}"; do
            IFS=':' read -ra permissions <<< "${file_permissions["${filename}"]}"
            # Prevent file path traversal outside of $pacstrap_dir
            if [[ "$(realpath -q -- "${pacstrap_dir}${filename}")" != "${pacstrap_dir}"* ]]; then
                _msg_error "Failed to set permissions on '${pacstrap_dir}${filename}'. Outside of valid path." 1
            # Warn if the file does not exist
            elif [[ ! -e "${pacstrap_dir}${filename}" ]]; then
                _msg_warning "Cannot change permissions of '${pacstrap_dir}${filename}'. The file or directory does not exist."
            else
                if [[ "${filename: -1}" == "/" ]]; then
                    chown -fhR -- "${permissions[0]}:${permissions[1]}" "${pacstrap_dir}${filename}"
                    chmod -fR -- "${permissions[2]}" "${pacstrap_dir}${filename}"
                else
                    chown -fh -- "${permissions[0]}:${permissions[1]}" "${pacstrap_dir}${filename}"
                    chmod -f -- "${permissions[2]}" "${pacstrap_dir}${filename}"
                fi
            fi
        done
        _msg_info "Done!"
    fi
}

# Install desired packages to the root file system
_make_packages() {
    _msg_info "Installing packages to '${pacstrap_dir}/'..."

    if [[ -n "${gpg_key}" ]]; then
        exec {ARCHISO_GNUPG_FD}<>"${work_dir}/pubkey.gpg"
        export ARCHISO_GNUPG_FD
    fi

    # Unset TMPDIR to work around https://bugs.archlinux.org/task/70580
    if [[ "${quiet}" = "y" ]]; then
        env -u TMPDIR pacstrap -C "${work_dir}/${buildmode}.pacman.conf" -c -G -M -- "${pacstrap_dir}" "${buildmode_pkg_list[@]}" &> /dev/null
    else
        env -u TMPDIR pacstrap -C "${work_dir}/${buildmode}.pacman.conf" -c -G -M -- "${pacstrap_dir}" "${buildmode_pkg_list[@]}"
    fi

    if [[ -n "${gpg_key}" ]]; then
        exec {ARCHISO_GNUPG_FD}<&-
        unset ARCHISO_GNUPG_FD
    fi

    _msg_info "Done! Packages installed successfully."
}

# Customize installation.
_make_customize_airootfs() {
    local passwd=()

    if [[ -e "${profile}/airootfs/etc/passwd" ]]; then
        _msg_info "Copying /etc/skel/* to user homes..."
        while IFS=':' read -a passwd -r; do
            # Only operate on UIDs in range 1000–59999
            (( passwd[2] >= 1000 && passwd[2] < 60000 )) || continue
            # Skip invalid home directories
            [[ "${passwd[5]}" == '/' ]] && continue
            [[ -z "${passwd[5]}" ]] && continue
            # Prevent path traversal outside of $pacstrap_dir
            if [[ "$(realpath -q -- "${pacstrap_dir}${passwd[5]}")" == "${pacstrap_dir}"* ]]; then
                if [[ ! -d "${pacstrap_dir}${passwd[5]}" ]]; then
                    install -d -m 0750 -o "${passwd[2]}" -g "${passwd[3]}" -- "${pacstrap_dir}${passwd[5]}"
                fi
                cp -dnRT --preserve=mode,timestamps,links -- "${pacstrap_dir}/etc/skel/." "${pacstrap_dir}${passwd[5]}"
                chmod -f 0750 -- "${pacstrap_dir}${passwd[5]}"
                chown -hR -- "${passwd[2]}:${passwd[3]}" "${pacstrap_dir}${passwd[5]}"
            else
                _msg_error "Failed to set permissions on '${pacstrap_dir}${passwd[5]}'. Outside of valid path." 1
            fi
        done < "${profile}/airootfs/etc/passwd"
        _msg_info "Done!"
    fi

    if [[ -e "${pacstrap_dir}/root/customize_airootfs.sh" ]]; then
        _msg_info "Running customize_airootfs.sh in '${pacstrap_dir}' chroot..."
        _msg_warning "customize_airootfs.sh is deprecated! Support for it will be removed in a future archiso version."
        chmod -f -- +x "${pacstrap_dir}/root/customize_airootfs.sh"
        # Unset TMPDIR to work around https://bugs.archlinux.org/task/70580
        eval -- env -u TMPDIR arch-chroot "${pacstrap_dir}" "/root/customize_airootfs.sh"
        rm -- "${pacstrap_dir}/root/customize_airootfs.sh"
        _msg_info "Done! customize_airootfs.sh run successfully."
    fi
}

# Set up boot loaders
_make_bootmodes() {
    local bootmode
    for bootmode in "${bootmodes[@]}"; do
        _run_once "_make_bootmode_${bootmode}"
    done
}

# Copy kernel and initramfs to ISO 9660
_make_boot_on_iso9660() {
    local ucode_image
    _msg_info "Preparing kernel and initramfs for the ISO 9660 file system..."
    install -d -m 0755 -- "${isofs_dir}/${install_dir}/boot/${arch}"
    install -m 0644 -- "${pacstrap_dir}/boot/initramfs-"*".img" "${isofs_dir}/${install_dir}/boot/${arch}/"
    install -m 0644 -- "${pacstrap_dir}/boot/vmlinuz-"* "${isofs_dir}/${install_dir}/boot/${arch}/"

    for ucode_image in "${ucodes[@]}"; do
        if [[ -e "${pacstrap_dir}/boot/${ucode_image}" ]]; then
            install -m 0644 -- "${pacstrap_dir}/boot/${ucode_image}" "${isofs_dir}/${install_dir}/boot/"
            if [[ -e "${pacstrap_dir}/usr/share/licenses/${ucode_image%.*}/" ]]; then
                install -d -m 0755 -- "${isofs_dir}/${install_dir}/boot/licenses/${ucode_image%.*}/"
                install -m 0644 -- "${pacstrap_dir}/usr/share/licenses/${ucode_image%.*}/"* \
                    "${isofs_dir}/${install_dir}/boot/licenses/${ucode_image%.*}/"
            fi
        fi
    done
    _msg_info "Done!"
}

# Prepare syslinux for booting from MBR (isohybrid)
_make_bootmode_bios.syslinux.mbr() {
    _msg_info "Setting up SYSLINUX for BIOS booting from a disk..."
    install -d -m 0755 -- "${isofs_dir}/syslinux"
    for _cfg in "${profile}/syslinux/"*.cfg; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g;
             s|%ARCH%|${arch}|g" \
             "${_cfg}" > "${isofs_dir}/syslinux/${_cfg##*/}"
    done
    if [[ -e "${profile}/syslinux/splash.png" ]]; then
        install -m 0644 -- "${profile}/syslinux/splash.png" "${isofs_dir}/syslinux/"
    fi
    install -m 0644 -- "${pacstrap_dir}/usr/lib/syslinux/bios/"*.c32 "${isofs_dir}/syslinux/"
    install -m 0644 -- "${pacstrap_dir}/usr/lib/syslinux/bios/lpxelinux.0" "${isofs_dir}/syslinux/"
    install -m 0644 -- "${pacstrap_dir}/usr/lib/syslinux/bios/memdisk" "${isofs_dir}/syslinux/"

    _run_once _make_boot_on_iso9660

    if [[ -e "${isofs_dir}/syslinux/hdt.c32" ]]; then
        install -d -m 0755 -- "${isofs_dir}/syslinux/hdt"
        if [[ -e "${pacstrap_dir}/usr/share/hwdata/pci.ids" ]]; then
            gzip -cn9 "${pacstrap_dir}/usr/share/hwdata/pci.ids" > \
                "${isofs_dir}/syslinux/hdt/pciids.gz"
        fi
        find "${pacstrap_dir}/usr/lib/modules" -name 'modules.alias' -print -exec gzip -cn9 '{}' ';' -quit > \
            "${isofs_dir}/syslinux/hdt/modalias.gz"
    fi

    # Add other aditional/extra files to ${install_dir}/boot/
    if [[ -e "${pacstrap_dir}/boot/memtest86+/memtest.bin" ]]; then
        # rename for PXE: https://wiki.archlinux.org/title/Syslinux#Using_memtest
        install -m 0644 -- "${pacstrap_dir}/boot/memtest86+/memtest.bin" "${isofs_dir}/${install_dir}/boot/memtest"
        install -d -m 0755 -- "${isofs_dir}/${install_dir}/boot/licenses/memtest86+/"
        install -m 0644 -- "${pacstrap_dir}/usr/share/licenses/common/GPL2/license.txt" \
            "${isofs_dir}/${install_dir}/boot/licenses/memtest86+/"
    fi
    _msg_info "Done! SYSLINUX set up for BIOS booting from a disk successfully."
}

# Prepare syslinux for El-Torito booting
_make_bootmode_bios.syslinux.eltorito() {
    _msg_info "Setting up SYSLINUX for BIOS booting from an optical disc..."
    install -d -m 0755 -- "${isofs_dir}/syslinux"
    install -m 0644 -- "${pacstrap_dir}/usr/lib/syslinux/bios/isolinux.bin" "${isofs_dir}/syslinux/"
    install -m 0644 -- "${pacstrap_dir}/usr/lib/syslinux/bios/isohdpfx.bin" "${isofs_dir}/syslinux/"

    # ISOLINUX and SYSLINUX installation is shared
    _run_once _make_bootmode_bios.syslinux.mbr

    _msg_info "Done! SYSLINUX set up for BIOS booting from an optical disc successfully."
}

# Copy kernel and initramfs to FAT image
_make_boot_on_fat() {
    local ucode_image all_ucode_images=()
    _msg_info "Preparing kernel and initramfs for the FAT file system..."
    mmd -i "${work_dir}/efiboot.img" \
        "::/${install_dir}" "::/${install_dir}/boot" "::/${install_dir}/boot/${arch}"
    mcopy -i "${work_dir}/efiboot.img" "${pacstrap_dir}/boot/vmlinuz-"* \
        "${pacstrap_dir}/boot/initramfs-"*".img" "::/${install_dir}/boot/${arch}/"
    for ucode_image in "${ucodes[@]}"; do
        if [[ -e "${pacstrap_dir}/boot/${ucode_image}" ]]; then
            all_ucode_images+=("${pacstrap_dir}/boot/${ucode_image}")
        fi
    done
    if (( ${#all_ucode_images[@]} )); then
        mcopy -i "${work_dir}/efiboot.img" "${all_ucode_images[@]}" "::/${install_dir}/boot/"
    fi
    _msg_info "Done!"
}

# Create a FAT image (efiboot.img) which will serve as the EFI system partition
# $1: image size in bytes
_make_efibootimg() {
    local imgsize="0"

    # Convert from bytes to KiB and round up to the next full MiB with an additional MiB for reserved sectors.
    imgsize="$(awk 'function ceil(x){return int(x)+(x>int(x))}
            function byte_to_kib(x){return x/1024}
            function mib_to_kib(x){return x*1024}
            END {print mib_to_kib(ceil((byte_to_kib($1)+1024)/1024))}' <<< "${1}"
    )"
    # The FAT image must be created with mkfs.fat not mformat, as some systems have issues with mformat made images:
    # https://lists.gnu.org/archive/html/grub-devel/2019-04/msg00099.html
    rm -f -- "${work_dir}/efiboot.img"
    _msg_info "Creating FAT image of size: ${imgsize} KiB..."
    if [[ "${quiet}" == "y" ]]; then
        # mkfs.fat does not have a -q/--quiet option, so redirect stdout to /dev/null instead
        # https://github.com/dosfstools/dosfstools/issues/103
        mkfs.fat -C -n ARCHISO_EFI "${work_dir}/efiboot.img" "${imgsize}" > /dev/null
    else
        mkfs.fat -C -n ARCHISO_EFI "${work_dir}/efiboot.img" "${imgsize}"
    fi

    # Create the default/fallback boot path in which a boot loaders will be placed later.
    mmd -i "${work_dir}/efiboot.img" ::/EFI ::/EFI/BOOT
}

# Prepare system-boot for booting when written to a disk (isohybrid)
_make_bootmode_uefi-x64.systemd-boot.esp() {
    local _file efiboot_imgsize
    local _available_ucodes=()
    _msg_info "Setting up systemd-boot for UEFI booting..."

    for _file in "${ucodes[@]}"; do
        if [[ -e "${pacstrap_dir}/boot/${_file}" ]]; then
            _available_ucodes+=("${pacstrap_dir}/boot/${_file}")
        fi
    done
    # Calculate the required FAT image size in bytes
    efiboot_imgsize="$(du -bc \
        "${pacstrap_dir}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
        "${pacstrap_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" \
        "${profile}/efiboot/" \
        "${pacstrap_dir}/boot/vmlinuz-"* \
        "${pacstrap_dir}/boot/initramfs-"*".img" \
        "${_available_ucodes[@]}" \
        2>/dev/null | awk 'END { print $1 }')"
    # Create a FAT image for the EFI system partition
    _make_efibootimg "$efiboot_imgsize"

    # Copy systemd-boot EFI binary to the default/fallback boot path
    mcopy -i "${work_dir}/efiboot.img" \
        "${pacstrap_dir}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" ::/EFI/BOOT/BOOTx64.EFI

    # Copy systemd-boot configuration files
    mmd -i "${work_dir}/efiboot.img" ::/loader ::/loader/entries
    mcopy -i "${work_dir}/efiboot.img" "${profile}/efiboot/loader/loader.conf" ::/loader/
    for _conf in "${profile}/efiboot/loader/entries/"*".conf"; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g;
             s|%ARCH%|${arch}|g" \
            "${_conf}" | mcopy -i "${work_dir}/efiboot.img" - "::/loader/entries/${_conf##*/}"
    done

    # shellx64.efi is picked up automatically when on /
    if [[ -e "${pacstrap_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" ]]; then
        mcopy -i "${work_dir}/efiboot.img" \
            "${pacstrap_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" ::/shellx64.efi
    fi

    # Copy kernel and initramfs to FAT image.
    # systemd-boot can only access files from the EFI system partition it was launched from.
    _make_boot_on_fat

    _msg_info "Done! systemd-boot set up for UEFI booting successfully."
}

# Prepare system-boot for El Torito booting
_make_bootmode_uefi-x64.systemd-boot.eltorito() {
    # El Torito UEFI boot requires an image containing the EFI system partition.
    # uefi-x64.systemd-boot.eltorito has the same requirements as uefi-x64.systemd-boot.esp
    _run_once _make_bootmode_uefi-x64.systemd-boot.esp

    # Additionally set up system-boot in ISO 9660. This allows creating a medium for the live environment by using
    # manual partitioning and simply copying the ISO 9660 file system contents.
    # This is not related to El Torito booting and no firmware uses these files.
    _msg_info "Preparing an /EFI directory for the ISO 9660 file system..."
    install -d -m 0755 -- "${isofs_dir}/EFI/BOOT"

    # Copy systemd-boot EFI binary to the default/fallback boot path
    install -m 0644 -- "${pacstrap_dir}/usr/lib/systemd/boot/efi/systemd-bootx64.efi" \
        "${isofs_dir}/EFI/BOOT/BOOTx64.EFI"

    # Copy systemd-boot configuration files
    install -d -m 0755 -- "${isofs_dir}/loader/entries"
    install -m 0644 -- "${profile}/efiboot/loader/loader.conf" "${isofs_dir}/loader/"
    for _conf in "${profile}/efiboot/loader/entries/"*".conf"; do
        sed "s|%ARCHISO_LABEL%|${iso_label}|g;
             s|%INSTALL_DIR%|${install_dir}|g;
             s|%ARCH%|${arch}|g" \
            "${_conf}" > "${isofs_dir}/loader/entries/${_conf##*/}"
    done

    # edk2-shell based UEFI shell
    # shellx64.efi is picked up automatically when on /
    if [[ -e "${pacstrap_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" ]]; then
        install -m 0644 -- "${pacstrap_dir}/usr/share/edk2-shell/x64/Shell_Full.efi" "${isofs_dir}/shellx64.efi"
    fi

    _msg_info "Done!"
}

_validate_requirements_bootmode_bios.syslinux.mbr() {
    # bios.syslinux.mbr requires bios.syslinux.eltorito
    # shellcheck disable=SC2076
    if [[ ! " ${bootmodes[*]} " =~ ' bios.syslinux.eltorito ' ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Using 'bios.syslinux.mbr' boot mode without 'bios.syslinux.eltorito' is not supported." 0
    fi

    # Check if the syslinux package is in the package list
    # shellcheck disable=SC2076
    if [[ ! " ${pkg_list[*]} " =~ ' syslinux ' ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': The 'syslinux' package is missing from the package list!" 0
    fi

    # Check if syslinux configuration files exist
    if [[ ! -d "${profile}/syslinux" ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': The '${profile}/syslinux' directory is missing!" 0
    else
        local cfgfile
        for cfgfile in "${profile}/syslinux/"*'.cfg'; do
            if [[ -e "${cfgfile}" ]]; then
                break
            else
                (( validation_error=validation_error+1 ))
                _msg_error "Validating '${bootmode}': No configuration file found in '${profile}/syslinux/'!" 0
            fi
        done
    fi

    # Check for optional packages
    # shellcheck disable=SC2076
    if [[ ! " ${pkg_list[*]} " =~ ' memtest86+ ' ]]; then
        _msg_info "Validating '${bootmode}': 'memtest86+' is not in the package list. Memmory testing will not be available from syslinux."
    fi
}

_validate_requirements_bootmode_bios.syslinux.eltorito() {
    # bios.syslinux.eltorito has the exact same requirements as bios.syslinux.mbr
    _validate_requirements_bootmode_bios.syslinux.mbr
}

_validate_requirements_bootmode_uefi-x64.systemd-boot.esp() {
    # Check if mkfs.fat is available
    if ! command -v mkfs.fat &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': mkfs.fat is not available on this host. Install 'dosfstools'!" 0
    fi

    # Check if mmd and mcopy are available
    if ! { command -v mmd &> /dev/null && command -v mcopy &> /dev/null; }; then
        _msg_error "Validating '${bootmode}': mmd and/or mcopy are not available on this host. Install 'mtools'!" 0
    fi

    # Check if systemd-boot configuration files exist
    if [[ ! -d "${profile}/efiboot/loader/entries" ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${bootmode}': The '${profile}/efiboot/loader/entries' directory is missing!" 0
    else
        if [[ ! -e "${profile}/efiboot/loader/loader.conf" ]]; then
            (( validation_error=validation_error+1 ))
            _msg_error "Validating '${bootmode}': File '${profile}/efiboot/loader/loader.conf' not found!" 0
        fi
        local conffile
        for conffile in "${profile}/efiboot/loader/entries/"*'.conf'; do
            if [[ -e "${conffile}" ]]; then
                break
            else
                (( validation_error=validation_error+1 ))
                _msg_error "Validating '${bootmode}': No configuration file found in '${profile}/efiboot/loader/entries/'!" 0
            fi
        done
    fi

    # Check for optional packages
    # shellcheck disable=SC2076
    if [[ ! " ${pkg_list[*]} " =~ ' edk2-shell ' ]]; then
        _msg_info "'edk2-shell' is not in the package list. The ISO will not contain a bootable UEFI shell."
    fi
}

_validate_requirements_bootmode_uefi-x64.systemd-boot.eltorito() {
    # uefi-x64.systemd-boot.eltorito has the exact same requirements as uefi-x64.systemd-boot.esp
    _validate_requirements_bootmode_uefi-x64.systemd-boot.esp
}

# Build airootfs filesystem image
_prepare_airootfs_image() {
    _run_once "_mkairootfs_${airootfs_image_type}"
    _mkchecksum
    if [[ -n "${gpg_key}" ]]; then
        _mksignature
    fi
}

# export build artifacts for netboot
_export_netboot_artifacts() {
    _msg_info "Exporting netboot artifacts..."
    install -d -m 0755 "${out_dir}"
    cp -a -- "${isofs_dir}/${install_dir}/" "${out_dir}/"
    _msg_info "Done!"
    du -hs -- "${out_dir}/${install_dir}"
}

# sign build artifacts for netboot
_sign_netboot_artifacts() {
    local _file _dir
    local _files_to_sign=()
    _msg_info "Signing netboot artifacts..."
    _dir="${isofs_dir}/${install_dir}/boot/"
    for _file in "${ucodes[@]}"; do
        if [[ -e "${_dir}${_file}" ]]; then
            _files_to_sign+=("${_dir}${_file}")
        fi
    done
    for _file in "${_files_to_sign[@]}" "${_dir}${arch}/vmlinuz-"* "${_dir}${arch}/initramfs-"*.img; do
        openssl cms \
            -sign \
            -binary \
            -noattr \
            -in "${_file}" \
            -signer "${cert_list[0]}" \
            -inkey "${cert_list[1]}" \
            -outform DER \
            -out "${_file}".ipxe.sig
    done
    _msg_info "Done!"
}

_validate_requirements_airootfs_image_type_squashfs() {
    if ! command -v mksquashfs &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${airootfs_image_type}': mksquashfs is not available on this host. Install 'squashfs-tools'!" 0
    fi
}

_validate_requirements_airootfs_image_type_ext4+squashfs() {
    if ! { command -v mkfs.ext4 &> /dev/null && command -v tune2fs &> /dev/null; }; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${airootfs_image_type}': mkfs.ext4 and/or tune2fs is not available on this host. Install 'e2fsprogs'!" 0
    fi
    _validate_requirements_airootfs_image_type_squashfs
}

_validate_requirements_airootfs_image_type_erofs() {
    if ! command -v mkfs.erofs &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating '${airootfs_image_type}': mkfs.erofs is not available on this host. Install 'erofs-utils'!" 0
    fi
}

_validate_common_requirements_buildmode_all() {
    if ! command -v pacman &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating build mode '${_buildmode}': pacman is not available on this host. Install 'pacman'!" 0
    fi
    if ! command -v find &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating build mode '${_buildmode}': find is not available on this host. Install 'findutils'!" 0
    fi
    if ! command -v gzip &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating build mode '${_buildmode}': gzip is not available on this host. Install 'gzip'!" 0
    fi
}

_validate_requirements_buildmode_bootstrap() {
    local bootstrap_pkg_list_from_file=()

    # Check if packages for the bootstrap image are specified
    if [[ -e "${bootstrap_packages}" ]]; then
        mapfile -t bootstrap_pkg_list_from_file < \
            <(sed '/^[[:blank:]]*#.*/d;s/#.*//;/^[[:blank:]]*$/d' "${bootstrap_packages}")
        bootstrap_pkg_list+=("${bootstrap_pkg_list_from_file[@]}")
        if (( ${#bootstrap_pkg_list_from_file[@]} < 1 )); then
            (( validation_error=validation_error+1 ))
            _msg_error "No package specified in '${bootstrap_packages}'." 0
        fi
    else
        (( validation_error=validation_error+1 ))
        _msg_error "Bootstrap packages file '${bootstrap_packages}' does not exist." 0
    fi

    _validate_common_requirements_buildmode_all
    if ! command -v bsdtar &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating build mode '${_buildmode}': bsdtar is not available on this host. Install 'libarchive'!" 0
    fi
}

_validate_common_requirements_buildmode_iso_netboot() {
    local bootmode
    local pkg_list_from_file=()

    # Check if the package list file exists and read packages from it
    if [[ -e "${packages}" ]]; then
        mapfile -t pkg_list_from_file < <(sed '/^[[:blank:]]*#.*/d;s/#.*//;/^[[:blank:]]*$/d' "${packages}")
        pkg_list+=("${pkg_list_from_file[@]}")
        if (( ${#pkg_list_from_file[@]} < 1 )); then
            (( validation_error=validation_error+1 ))
            _msg_error "No package specified in '${packages}'." 0
        fi
    else
        (( validation_error=validation_error+1 ))
        _msg_error "Packages file '${packages}' does not exist." 0
    fi

    # Check if the specified airootfs_image_type is supported
    if typeset -f "_mkairootfs_${airootfs_image_type}" &> /dev/null; then
        if typeset -f "_validate_requirements_airootfs_image_type_${airootfs_image_type}" &> /dev/null; then
            "_validate_requirements_airootfs_image_type_${airootfs_image_type}"
        else
            _msg_warning "Function '_validate_requirements_airootfs_image_type_${airootfs_image_type}' does not exist. Validating the requirements of '${airootfs_image_type}' airootfs image type will not be possible."
        fi
    else
        (( validation_error=validation_error+1 ))
        _msg_error "Unsupported image type: '${airootfs_image_type}'" 0
    fi
}

_validate_requirements_buildmode_iso() {
    _validate_common_requirements_buildmode_iso_netboot
    _validate_common_requirements_buildmode_all
    # Check if the specified bootmodes are supported
    if (( ${#bootmodes[@]} < 1 )); then
        (( validation_error=validation_error+1 ))
        _msg_error "No boot modes specified in '${profile}/profiledef.sh'." 0
    fi
    for bootmode in "${bootmodes[@]}"; do
        if typeset -f "_make_bootmode_${bootmode}" &> /dev/null; then
            if typeset -f "_validate_requirements_bootmode_${bootmode}" &> /dev/null; then
                "_validate_requirements_bootmode_${bootmode}"
            else
                _msg_warning "Function '_validate_requirements_bootmode_${bootmode}' does not exist. Validating the requirements of '${bootmode}' boot mode will not be possible."
            fi
        else
            (( validation_error=validation_error+1 ))
            _msg_error "${bootmode} is not a valid boot mode!" 0
        fi
    done

    if ! command -v awk &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating build mode '${_buildmode}': awk is not available on this host. Install 'awk'!" 0
    fi
}

_validate_requirements_buildmode_netboot() {
    local _override_cert_list=()

    if [[ "${sign_netboot_artifacts}" == "y" ]]; then
        # Check if the certificate files exist
        for _cert in "${cert_list[@]}"; do
            if [[ -e "${_cert}" ]]; then
                _override_cert_list+=("$(realpath -- "${_cert}")")
            else
                (( validation_error=validation_error+1 ))
                _msg_error "File '${_cert}' does not exist." 0
            fi
        done
        cert_list=("${_override_cert_list[@]}")
        # Check if there are at least two certificate files
        if (( ${#cert_list[@]} < 2 )); then
            (( validation_error=validation_error+1 ))
            _msg_error "Two certificates are required for codesigning, but '${cert_list[*]}' is provided." 0
        fi
    fi
    _validate_common_requirements_buildmode_iso_netboot
    _validate_common_requirements_buildmode_all
    if ! command -v openssl &> /dev/null; then
        (( validation_error=validation_error+1 ))
        _msg_error "Validating build mode '${_buildmode}': openssl is not available on this host. Install 'openssl'!" 0
    fi
}

# SYSLINUX El Torito
_add_xorrisofs_options_bios.syslinux.eltorito() {
    xorrisofs_options+=(
        # El Torito boot image for x86 BIOS
        '-eltorito-boot' 'syslinux/isolinux.bin'
        # El Torito boot catalog file
        '-eltorito-catalog' 'syslinux/boot.cat'
        # Required options to boot with ISOLINUX
        '-no-emul-boot' '-boot-load-size' '4' '-boot-info-table'
    )
}

# SYSLINUX MBR (isohybrid)
_add_xorrisofs_options_bios.syslinux.mbr() {
    xorrisofs_options+=(
        # SYSLINUX MBR bootstrap code; does not work without "-eltorito-boot syslinux/isolinux.bin"
        '-isohybrid-mbr' "${isofs_dir}/syslinux/isohdpfx.bin"
        # When GPT is used, create an additional partition in the MBR (besides 0xEE) for sectors 0–1 (MBR
        # bootstrap code area) and mark it as bootable
        # May allow booting on some systems
        # https://wiki.archlinux.org/title/Partitioning#Tricking_old_BIOS_into_booting_from_GPT
        '--mbr-force-bootable'
        # Move the first partition away from the start of the ISO to match the expectations of partition editors
        # May allow booting on some systems
        # https://dev.lovelyhq.com/libburnia/libisoburn/src/branch/master/doc/partition_offset.wiki
        '-partition_offset' '16'
    )
}

# systemd-boot in an attached EFI system partition
_add_xorrisofs_options_uefi-x64.systemd-boot.esp() {
    # Move the first partition away from the start of the ISO, otherwise the GPT will not be valid and ISO 9660
    # partition will not be mountable
    # shellcheck disable=SC2076
    [[ " ${xorrisofs_options[*]} " =~ ' -partition_offset ' ]] || xorrisofs_options+=('-partition_offset' '16')
    # Attach efiboot.img as a second partition and set its partition type to "EFI system partition"
    xorrisofs_options+=('-append_partition' '2' 'C12A7328-F81F-11D2-BA4B-00A0C93EC93B' "${work_dir}/efiboot.img")
    # Ensure GPT is used as some systems do not support UEFI booting without it
    # shellcheck disable=SC2076
    if [[ " ${bootmodes[*]} " =~ ' bios.syslinux.mbr ' ]]; then
        # A valid GPT prevents BIOS booting on some systems, instead use an invalid GPT (without a protective MBR).
        # The attached partition will have the EFI system partition type code in MBR, but in the invalid GPT it will
        # have a Microsoft basic partition type code.
        if [[ ! " ${bootmodes[*]} " =~ ' uefi-x64.systemd-boot.eltorito ' ]]; then
            # If '-isohybrid-gpt-basdat' is specified before '-e', then the appended EFI system partition will have the
            # EFI system partition type ID/GUID in both MBR and GPT. If '-isohybrid-gpt-basdat' is specified after '-e',
            # the appended EFI system partition will have the Microsoft basic data type GUID in GPT.
            if [[ ! " ${xorrisofs_options[*]} " =~ ' -isohybrid-gpt-basdat ' ]]; then
                xorrisofs_options+=('-isohybrid-gpt-basdat')
            fi
        fi
    else
        # Use valid GPT if BIOS booting support will not be required
        xorrisofs_options+=('-appended_part_as_gpt')
    fi
}

# systemd-boot via El Torito
_add_xorrisofs_options_uefi-x64.systemd-boot.eltorito() {
    # shellcheck disable=SC2076
    if [[ " ${bootmodes[*]} " =~ ' uefi-x64.systemd-boot.esp ' ]]; then
        # systemd-boot in an attached EFI system partition via El Torito
        xorrisofs_options+=(
            # Start a new El Torito boot entry for UEFI
            '-eltorito-alt-boot'
            # Set the second partition as the El Torito UEFI boot image
            '-e' '--interval:appended_partition_2:all::'
            # Boot image is not emulating floppy or hard disk; required for all known boot loaders
            '-no-emul-boot'
        )
        # A valid GPT prevents BIOS booting on some systems, use an invalid GPT instead.
        if [[ " ${bootmodes[*]} " =~ ' bios.syslinux.mbr ' ]]; then
            # If '-isohybrid-gpt-basdat' is specified before '-e', then the appended EFI system partition will have the
            # EFI system partition type ID/GUID in both MBR and GPT. If '-isohybrid-gpt-basdat' is specified after '-e',
            # the appended EFI system partition will have the Microsoft basic data type GUID in GPT.
            if [[ ! " ${xorrisofs_options[*]} " =~ ' -isohybrid-gpt-basdat ' ]]; then
                xorrisofs_options+=('-isohybrid-gpt-basdat')
            fi
        fi
    else
        # The ISO will not contain a GPT partition table, so to be able to reference efiboot.img, place it as a
        # file inside the ISO 9660 file system
        install -d -m 0755 -- "${isofs_dir}/EFI/archiso"
        cp -a -- "${work_dir}/efiboot.img" "${isofs_dir}/EFI/archiso/efiboot.img"
        # systemd-boot in an embedded efiboot.img via El Torito
        xorrisofs_options+=(
            # Start a new El Torito boot entry for UEFI
            '-eltorito-alt-boot'
            # Set efiboot.img as the El Torito UEFI boot image
            '-e' 'EFI/archiso/efiboot.img'
            # Boot image is not emulating floppy or hard disk; required for all known boot loaders
            '-no-emul-boot'
        )
    fi
    # Specify where to save the El Torito boot catalog file in case it is not already set by bios.syslinux.eltorito
    # shellcheck disable=SC2076
    [[ " ${bootmodes[*]} " =~ ' bios.' ]] || xorrisofs_options+=('-eltorito-catalog' 'EFI/boot.cat')
}

# Build bootstrap image
_build_bootstrap_image() {
    local _bootstrap_parent
    _bootstrap_parent="$(dirname -- "${pacstrap_dir}")"

    [[ -d "${out_dir}" ]] || install -d -- "${out_dir}"

    cd -- "${_bootstrap_parent}"

    _msg_info "Creating bootstrap image..."
    bsdtar -cf - "root.${arch}" | gzip -cn9 > "${out_dir}/${image_name}"
    _msg_info "Done!"
    du -h -- "${out_dir}/${image_name}"
    cd -- "${OLDPWD}"
}

# Build ISO
_build_iso_image() {
    local xorriso_options=() xorrisofs_options=()
    local bootmode

    [[ -d "${out_dir}" ]] || install -d -- "${out_dir}"

    if [[ "${quiet}" == "y" ]]; then
        # The when xorriso is run in mkisofs compatibility mode (xorrisofs), the mkisofs option -quiet is interpreted
        # too late (e.g. messages about SOURCE_DATE_EPOCH still get shown).
        # Instead use native xorriso option to silence the output.
        xorriso_options=('-report_about' 'SORRY' "${xorriso_options[@]}")
    fi

    # Add required xorrisofs options for each boot mode
    for bootmode in "${bootmodes[@]}"; do
        typeset -f "_add_xorrisofs_options_${bootmode}" &> /dev/null && "_add_xorrisofs_options_${bootmode}"
    done

    rm -f -- "${out_dir}/${image_name}"
    _msg_info "Creating ISO image..."
    xorriso "${xorriso_options[@]}" -as mkisofs \
            -iso-level 3 \
            -full-iso9660-filenames \
            -joliet \
            -joliet-long \
            -rational-rock \
            -volid "${iso_label}" \
            -appid "${iso_application}" \
            -publisher "${iso_publisher}" \
            -preparer "prepared by ${app_name}" \
            "${xorrisofs_options[@]}" \
            -output "${out_dir}/${image_name}" \
            "${isofs_dir}/"
    _msg_info "Done!"
    du -h -- "${out_dir}/${image_name}"
}

# Read profile's values from profiledef.sh
_read_profile() {
    if [[ -z "${profile}" ]]; then
        _msg_error "No profile specified!" 1
    fi
    if [[ ! -d "${profile}" ]]; then
        _msg_error "Profile '${profile}' does not exist!" 1
    elif [[ ! -e "${profile}/profiledef.sh" ]]; then
        _msg_error "Profile '${profile}' is missing 'profiledef.sh'!" 1
    else
        cd -- "${profile}"

        # Source profile's variables
        # shellcheck source=configs/releng/profiledef.sh
        . "${profile}/profiledef.sh"

        # Resolve paths of files that are expected to reside in the profile's directory
        [[ -n "$packages" ]] || packages="${profile}/packages.${arch}"
        packages="$(realpath -- "${packages}")"
        pacman_conf="$(realpath -- "${pacman_conf}")"

        # Resolve paths of files that may reside in the profile's directory
        if [[ -z "$bootstrap_packages" ]] && [[ -e "${profile}/bootstrap_packages.${arch}" ]]; then
            bootstrap_packages="${profile}/bootstrap_packages.${arch}"
            bootstrap_packages="$(realpath -- "${bootstrap_packages}")"
            pacman_conf="$(realpath -- "${pacman_conf}")"
        fi

        cd -- "${OLDPWD}"
    fi
}

# Validate set options
_validate_options() {
    local validation_error=0 _buildmode

    _msg_info "Validating options..."

    # Check if pacman configuration file exists
    if [[ ! -e "${pacman_conf}" ]]; then
        (( validation_error=validation_error+1 ))
        _msg_error "File '${pacman_conf}' does not exist." 0
    fi

    # Check if the specified buildmodes are supported
    for _buildmode in "${buildmodes[@]}"; do
        if typeset -f "_build_buildmode_${_buildmode}" &> /dev/null; then
            if typeset -f "_validate_requirements_buildmode_${_buildmode}" &> /dev/null; then
                "_validate_requirements_buildmode_${_buildmode}"
            else
                _msg_warning "Function '_validate_requirements_buildmode_${_buildmode}' does not exist. Validating the requirements of '${_buildmode}' build mode will not be possible."
            fi
        else
            (( validation_error=validation_error+1 ))
            _msg_error "${_buildmode} is not a valid build mode!" 0
        fi
    done

    if (( validation_error )); then
        _msg_error "${validation_error} errors were encountered while validating the profile. Aborting." 1
    fi
    _msg_info "Done!"
}

# Set defaults and, if present, overrides from mkarchiso command line option parameters
_set_overrides() {
    # Set variables that have command line overrides
    [[ ! -v override_buildmodes ]] || buildmodes=("${override_buildmodes[@]}")
    if (( ${#buildmodes[@]} < 1 )); then
        buildmodes+=('iso')
    fi
    if [[ -v override_work_dir ]]; then
        work_dir="$override_work_dir"
    elif [[ -z "$work_dir" ]]; then
        work_dir='./work'
    fi
    work_dir="$(realpath -- "$work_dir")"
    if [[ -v override_out_dir ]]; then
        out_dir="$override_out_dir"
    elif [[ -z "$out_dir" ]]; then
        out_dir='./out'
    fi
    out_dir="$(realpath -- "$out_dir")"
    if [[ -v override_pacman_conf ]]; then
        pacman_conf="$override_pacman_conf"
    elif [[ -z "$pacman_conf" ]]; then
        pacman_conf="/etc/pacman.conf"
    fi
    pacman_conf="$(realpath -- "$pacman_conf")"
    [[ ! -v override_pkg_list ]] || pkg_list+=("${override_pkg_list[@]}")
    # TODO: allow overriding bootstrap_pkg_list
    if [[ -v override_iso_label ]]; then
        iso_label="$override_iso_label"
    elif [[ -z "$iso_label" ]]; then
        iso_label="${app_name^^}"
    fi
    if [[ -v override_iso_publisher ]]; then
        iso_publisher="$override_iso_publisher"
    elif [[ -z "$iso_publisher" ]]; then
        iso_publisher="${app_name}"
    fi
    if [[ -v override_iso_application ]]; then
        iso_application="$override_iso_application"
    elif [[ -z "$iso_application" ]]; then
        iso_application="${app_name} iso"
    fi
    if [[ -v override_install_dir ]]; then
        install_dir="$override_install_dir"
    elif [[ -z "$install_dir" ]]; then
        install_dir="${app_name}"
    fi
    [[ ! -v override_gpg_key ]] || gpg_key="$override_gpg_key"
    [[ ! -v override_gpg_sender ]] || gpg_sender="$override_gpg_sender"
    if [[ -v override_cert_list ]]; then
        sign_netboot_artifacts="y"
    fi
    [[ ! -v override_cert_list ]] || cert_list+=("${override_cert_list[@]}")
    if [[ -v override_quiet ]]; then
        quiet="$override_quiet"
    elif [[ -z "$quiet" ]]; then
        quiet="y"
    fi

    # Set variables that do not have overrides
    [[ -n "$arch" ]] || arch="$(uname -m)"
    [[ -n "$airootfs_image_type" ]] || airootfs_image_type="squashfs"
    [[ -n "$iso_name" ]] || iso_name="${app_name}"
}

_export_gpg_publickey() {
    rm -f -- "${work_dir}/pubkey.gpg"
    gpg --batch --no-armor --output "${work_dir}/pubkey.gpg" --export "${gpg_key}"
}

_make_version() {
    local _os_release

    _msg_info "Creating version files..."
    # Write version file to system installation dir
    rm -f -- "${pacstrap_dir}/version"
    printf '%s\n' "${iso_version}" > "${pacstrap_dir}/version"

    if [[ "${buildmode}" == @("iso"|"netboot") ]]; then
        install -d -m 0755 -- "${isofs_dir}/${install_dir}"
        # Write version file to ISO 9660
        printf '%s\n' "${iso_version}" > "${isofs_dir}/${install_dir}/version"
        # Write grubenv with version information to ISO 9660
        printf '%.1024s' "$(printf '# GRUB Environment Block\nNAME=%s\nVERSION=%s\n%s' \
            "${iso_name}" "${iso_version}" "$(printf '%0.1s' "#"{1..1024})")" \
            > "${isofs_dir}/${install_dir}/grubenv"
    fi

    # Append IMAGE_ID & IMAGE_VERSION to os-release
    _os_release="$(realpath -- "${pacstrap_dir}/etc/os-release")"
    if [[ ! -e "${pacstrap_dir}/etc/os-release" && -e "${pacstrap_dir}/usr/lib/os-release" ]]; then
        _os_release="$(realpath -- "${pacstrap_dir}/usr/lib/os-release")"
    fi
    if [[ "${_os_release}" != "${pacstrap_dir}"* ]]; then
        _msg_warning "os-release file '${_os_release}' is outside of valid path."
    else
        [[ ! -e "${_os_release}" ]] || sed -i '/^IMAGE_ID=/d;/^IMAGE_VERSION=/d' "${_os_release}"
        printf 'IMAGE_ID=%s\nIMAGE_VERSION=%s\n' "${iso_name}" "${iso_version}" >> "${_os_release}"
    fi
    _msg_info "Done!"
}

_make_pkglist() {
    _msg_info "Creating a list of installed packages on live-enviroment..."
    case "${buildmode}" in
        "bootstrap")
            pacman -Q --sysroot "${pacstrap_dir}" > "${pacstrap_dir}/pkglist.${arch}.txt"
            ;;
        "iso"|"netboot")
            install -d -m 0755 -- "${isofs_dir}/${install_dir}"
            pacman -Q --sysroot "${pacstrap_dir}" > "${isofs_dir}/${install_dir}/pkglist.${arch}.txt"
            ;;
    esac
    _msg_info "Done!"
}

# build the base for an ISO and/or a netboot target
_build_iso_base() {
    local run_once_mode="base"
    local buildmode_packages="${packages}"
    # Set the package list to use
    local buildmode_pkg_list=("${pkg_list[@]}")
    # Set up essential directory paths
    pacstrap_dir="${work_dir}/${arch}/airootfs"
    isofs_dir="${work_dir}/iso"

    # Create working directory
    [[ -d "${work_dir}" ]] || install -d -- "${work_dir}"
    # Write build date to file or if the file exists, read it from there
    if [[ -e "${work_dir}/build_date" ]]; then
        SOURCE_DATE_EPOCH="$(<"${work_dir}/build_date")"
    else
        printf '%s\n' "$SOURCE_DATE_EPOCH" > "${work_dir}/build_date"
    fi

    [[ "${quiet}" == "y" ]] || _show_config
    _run_once _make_pacman_conf
    [[ -z "${gpg_key}" ]] || _run_once _export_gpg_publickey
    _run_once _make_custom_airootfs
    _run_once _make_packages
    _run_once _make_version
    _run_once _make_customize_airootfs
    _run_once _make_pkglist
    if [[ "${buildmode}" == 'netboot' ]]; then
        _run_once _make_boot_on_iso9660
    else
        _make_bootmodes
    fi
    _run_once _cleanup_pacstrap_dir
    _run_once _prepare_airootfs_image
}

# Build the bootstrap buildmode
_build_buildmode_bootstrap() {
    local image_name="${iso_name}-bootstrap-${iso_version}-${arch}.tar.gz"
    local run_once_mode="${buildmode}"
    local buildmode_packages="${bootstrap_packages}"
    # Set the package list to use
    local buildmode_pkg_list=("${bootstrap_pkg_list[@]}")

    # Set up essential directory paths
    pacstrap_dir="${work_dir}/${arch}/bootstrap/root.${arch}"
    [[ -d "${work_dir}" ]] || install -d -- "${work_dir}"
    install -d -m 0755 -o 0 -g 0 -- "${pacstrap_dir}"

    [[ "${quiet}" == "y" ]] || _show_config
    _run_once _make_pacman_conf
    _run_once _make_packages
    _run_once _make_version
    _run_once _make_pkglist
    _run_once _cleanup_pacstrap_dir
    _run_once _build_bootstrap_image
}

# Build the netboot buildmode
_build_buildmode_netboot() {
    local run_once_mode="${buildmode}"

    _build_iso_base
    if [[ -v cert_list ]]; then
        _run_once _sign_netboot_artifacts
    fi
    _run_once _export_netboot_artifacts
}

# Build the ISO buildmode
_build_buildmode_iso() {
    local image_name="ctlos_xfce_2.2.1_20220109.iso"
    local run_once_mode="${buildmode}"
    _build_iso_base
    _run_once _build_iso_image
}

# build all buildmodes
_build() {
    local buildmode
    local run_once_mode="build"

    for buildmode in "${buildmodes[@]}"; do
        _run_once "_build_buildmode_${buildmode}"
    done
}

while getopts 'c:p:C:L:P:A:D:w:m:o:g:G:vh?' arg; do
    case "${arg}" in
        p) read -r -a override_pkg_list <<< "${OPTARG}" ;;
        C) override_pacman_conf="${OPTARG}" ;;
        L) override_iso_label="${OPTARG}" ;;
        P) override_iso_publisher="${OPTARG}" ;;
        A) override_iso_application="${OPTARG}" ;;
        D) override_install_dir="${OPTARG}" ;;
        c) read -r -a override_cert_list <<< "${OPTARG}" ;;
        w) override_work_dir="${OPTARG}" ;;
        m) read -r -a override_buildmodes <<< "${OPTARG}" ;;
        o) override_out_dir="${OPTARG}" ;;
        g) override_gpg_key="${OPTARG}" ;;
        G) override_gpg_sender="${OPTARG}" ;;
        v) override_quiet="n" ;;
        h|?) _usage 0 ;;
        *)
            _msg_error "Invalid argument '${arg}'" 0
            _usage 1
            ;;
    esac
done

shift $((OPTIND - 1))

if (( $# < 1 )); then
    _msg_error "No profile specified" 0
    _usage 1
fi

if (( EUID != 0 )); then
    _msg_error "${app_name} must be run as root." 1
fi

# get the absolute path representation of the first non-option argument
profile="$(realpath -- "${1}")"

_read_profile
_set_overrides
_validate_options
_build

# vim:ts=4:sw=4:et:
