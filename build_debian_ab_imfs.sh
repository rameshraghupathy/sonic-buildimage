
# setup the platform hooks and install platform pkgs into the fsroot
setup_ab_imfs_platform_pkgs() {
    # Hack to workaround "dpkg: unrecoverable fatal error, aborting"
    # "unknown system group '_chrony' in statoverride file" error for
    # linux-image-*unsigned*.deb which was causing KLMs not getting packaged
    # into "initrd.img"
    sudo chroot $FILESYSTEM_ROOT sed -i '/_chrony/d' /var/lib/dpkg/statoverride 2>/dev/null || true

    if [[ "$ONIE_IMAGE_AB_PARTITION" == "y" ]]; then
        if [ -r ./platform/$TARGET_MACHINE/files/platform_hooks ]; then
            echo "Copying Platform hooks"
            sudo mkdir -p $FILESYSTEM_ROOT/platform-hooks/
            sudo cp -r ./platform/$TARGET_MACHINE/files/platform_hooks/* $FILESYSTEM_ROOT/platform-hooks/

            # For NO_SHIM builds, omit installer_checks.hook so ONIE partitions
            # 1 and 2 are preserved.
            # rc.local already guards with [ -f /hooks/installer_checks.hook ]
            # so absence is safe.
            if [ "$NO_SHIM" = "y" ]; then
                echo "Removing installer_checks hook"
                sudo rm -f $FILESYSTEM_ROOT/platform-hooks/installer_checks.hook
            fi
        fi
    fi

    if [[ "$SONIC_IMMUTABLE_FS" == "y" ]]; then
        # immutable filesystem uses openssl to check the signature validity of the FS pkgs
        # include openssl in initramfs when we are building it.
        sudo cp files/initramfs-tools/update-initramfs.conf $FILESYSTEM_ROOT/etc/initramfs-tools/update-initramfs.conf
        sudo cp files/initramfs-tools/openssl $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/openssl
        sudo chmod +x $FILESYSTEM_ROOT/etc/initramfs-tools/hooks/openssl

        hw_sku=$PLATFORM_HW_SKU
        echo "Immutable FS setting on. Checking for $hw_sku specific platform debian packages"
        if [ ! -z $hw_sku ] && [ -d $FILESYSTEM_ROOT/$PLATFORM_DIR/$hw_sku ] ; then
            # create a file to indicate this image has been built with required HW sku packages.hw_sku
            echo "$hw_sku" > $FILESYSTEM_ROOT/$PLATFORM_DIR/immutable_fs_hw_sku.txt
            echo "Building HW SKU specific image for $hw_sku"
            if [ -f $FILESYSTEM_ROOT/$PLATFORM_DIR/common/Packages.gz ]; then
                sudo mv $FILESYSTEM_ROOT/etc/apt/sources.list $FILESYSTEM_ROOT/etc/apt/sources.list.rc-local
                sudo echo "deb [trusted=yes] file:///platform/common /" > sonic_debian_extension.list
                sudo mv sonic_debian_extension.list $FILESYSTEM_ROOT/etc/apt/sources.list.d/
                sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get update

                # install each of the platform packages
                for i in $(ls $FILESYSTEM_ROOT/$PLATFORM_DIR/$hw_sku/);
                do sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -o DPkg::Path=/opt/cisco/bin:/opt/cisco/tools/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin -y install /$PLATFORM_DIR/$hw_sku/$i
                done

                # Cleanup & Restore
                sudo rm -f $FILESYSTEM_ROOT/etc/apt/sources.list.d/sonic_debian_extension.list
                sudo mv $FILESYSTEM_ROOT/etc/apt/sources.list.rc-local $FILESYSTEM_ROOT/etc/apt/sources.list
            else
                LANG=C chroot $FILESYSTEM_ROOT dpkg -i $PLATFORM_DIR/$hw_sku/*.deb
            fi
            # after platform debs installations, we require a check and fix any linux broken dependencies
            sudo dpkg --root=$FILESYSTEM_ROOT -i $debs_path/linux-image-${LINUX_KERNEL_VERSION}-*_${CONFIGURED_ARCH}.deb || \
            sudo LANG=C DEBIAN_FRONTEND=noninteractive chroot $FILESYSTEM_ROOT apt-get -y install -f
            echo "Installed $hw_sku platform packages"
        else
            echo "Failed to find HW_SKU directory: $FILESYSTEM_ROOT/$PLATFORM_DIR/$hw_sku"
            die "Failed to find the right HW sku directory"
        fi
        sudo find $FILESYSTEM_ROOT/$PLATFORM_DIR -type f -name "*.deb" -delete
    fi
}

# generate and setup the certs required for file signature verification
generate_and_setup_ab_imfs_certs() {
    if [ "$SONIC_IMMUTABLE_FS" = "y" ]; then
        if [[ $SECURE_UPGRADE_MODE == "prod" ]]; then
        . /sonic-signing/get_certs.conf
        # copy the ca cert needed in initrd for IMFS verification
        sudo mkdir -p $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/certs
        sudo cp ${CERT_FILES[0]} $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/certs/ca_certfile

        # make both certs available in rootfs as well
        sudo mkdir -p $FILESYSTEM_ROOT/platform-hooks/certs
        # d_certfile is the detached signature cert
        sudo cp ${CERT_FILES[0]} $FILESYSTEM_ROOT/platform-hooks/certs/d_certfile
        # a_certfile is the attached signature cert
        sudo cp ${CERT_FILES[1]} $FILESYSTEM_ROOT/platform-hooks/certs/a_certfile

        # put the pubkey in initrd for IMFS verification
        SHA512_PRIV_KEY=sha512_priv.key
        SHA512_PUB_KEY=sha512_pub.key
        openssl genrsa -out $SHA512_PRIV_KEY 2048
        openssl rsa -in $SHA512_PRIV_KEY -pubout -out $SHA512_PUB_KEY
        sudo cp $SHA512_PUB_KEY $FILESYSTEM_ROOT/etc/initramfs-tools/scripts/
        fi
    fi
}


# include the platform specific drivers into initRd and build it
generate_initrd_ab_imfs() {
    if [[ "$SONIC_IMMUTABLE_FS" == "y" ]]; then
        # Immutable FS: bake ACPI into initrd at build time (existing behavior)
        echo "Immutable FS setting on. Building $PLATFORM_HW_SKU specific initrd"
        hw_sku=$PLATFORM_HW_SKU
        onie_platform=$PLATFORM_HW_SKU
        if [ -r ./platform/$TARGET_MACHINE/platform.conf ]; then
            . platform/$TARGET_MACHINE/platform.conf
        else
            echo "Failed to find platform specific platform.conf file at platform/$TARGET_MACHINE/platform.conf"
            exit 1
        fi

        if [ ! -z $hw_sku ] && [ -d $FILESYSTEM_ROOT/$PLATFORM_DIR/$hw_sku ] ; then
            INITRD=$FILESYSTEM_ROOT/boot/initrd.img-${LINUX_KERNEL_VERSION}-${CONFIGURED_ARCH}
            echo "Building new initRD with $FILESYSTEM_ROOT/$PLATFORM_DIR/acpi/$ACPI_CPIO"
            sudo cat $FILESYSTEM_ROOT/$PLATFORM_DIR/acpi/$ACPI_CPIO ${INITRD} > initrd.new
            sudo cp initrd.new ${INITRD}
            if [[ $SECURE_UPGRADE_MODE == "prod" ]]; then
                sudo -E $sonic_su_prod_detached_signing_tool $SECURE_UPGRADE_PROD_DETACHED_TOOL_ARGS ${INITRD}
                sha512_list+=(${INITRD})
            fi
        fi
    elif [[ "$NO_SHIM" == "y" ]]; then
        # NO_SHIM: ACPI is loaded separately via GRUB initrdefi multi-file.
        # Just sign the base initrd as-is (no ACPI prepend).
        echo "NO_SHIM: signing base initrd (ACPI handled via GRUB multi-file initrdefi)"
        INITRD=$FILESYSTEM_ROOT/boot/initrd.img-${LINUX_KERNEL_VERSION}-${CONFIGURED_ARCH}
        if [[ $SECURE_UPGRADE_MODE == "prod" ]]; then
            sudo -E $sonic_su_prod_detached_signing_tool $SECURE_UPGRADE_PROD_DETACHED_TOOL_ARGS ${INITRD}
            sha512_list+=(${INITRD})
        fi
    fi
}

# setup ab_imfs custome directories and custom grubfiles
setup_ab_imfs_custom_dirs() {
    if [[ "$ONIE_IMAGE_AB_PARTITION" == "y" ]]; then
        echo "A/B partitioning logic is enabled"
        sudo mkdir $FILESYSTEM_ROOT/image-a
        sudo mkdir $FILESYSTEM_ROOT/image-b
        sudo mkdir $FILESYSTEM_ROOT/data-a
        sudo mkdir $FILESYSTEM_ROOT/data-b

        echo "Setting up prebuilt grub config"
        sudo mkdir -p $FILESYSTEM_ROOT/grub

        # Select grub config based on NO_SHIM flag
        if [ "$NO_SHIM" = "y" ]; then
            sudo cp platform/$TARGET_MACHINE/files/grub/platform_sonic_grub_noshim.cfg $FILESYSTEM_ROOT/grub/platform_sonic_grub.cfg
        else
            sudo cp platform/$TARGET_MACHINE/files/grub/platform_sonic_grub.cfg $FILESYSTEM_ROOT/grub/
        fi

        sudo cp platform/$TARGET_MACHINE/files/grub/platform_efi_a_grub.cfg $FILESYSTEM_ROOT/grub/
        sudo cp platform/$TARGET_MACHINE/files/grub/platform_efi_b_grub.cfg $FILESYSTEM_ROOT/grub/

        #if we are not building immutable FS, include the SIM grub as well
        if [[ "$SONIC_IMMUTABLE_FS" == "n" ]];  then
            sudo cp platform/$TARGET_MACHINE/files/grub/platform_sim_grub.cfg $FILESYSTEM_ROOT/grub/
        fi
        #
        # Note: Creation of detached signatures for all grub cfg files is done
        # in build_debian.sh little bit after control returns from here.
        #
    fi
}


# generate SHA files for all the filesystem blobs
generate_ab_imfs_shafiles() {
    if [ "$ONIE_IMAGE_AB_PARTITION" == "y" ]; then
        if [ "$SONIC_IMMUTABLE_FS" = "y" ]; then
            for f in ${sha512_list[@]}; do
                echo "Generating sha512 for ${f}..."
                sudo openssl dgst -sha512 -sign "$SHA512_PRIV_KEY" -out ${f}.sha512 ${f}
            done
        fi
        pushd $FILESYSTEM_ROOT && sudo zip -n .gz $OLDPWD/$INSTALLER_PAYLOAD -r grub/; popd
    fi
}

# package all the required pieces and sign them
package_filesystem_for_ab_imfs() {
    ## Compress docker files
    pushd $FILESYSTEM_ROOT && sudo tar -cf $OLDPWD/dockerfs.tar -C ${DOCKERFS_PATH}var/lib/docker .; popd

    FSSQUASH_SIGFILE=${FILESYSTEM_SQUASHFS}.signature
    DOCKERFS_SIGFILE=dockerfs.tar.signature
    sudo -E $sonic_su_prod_detached_signing_tool $SECURE_UPGRADE_PROD_DETACHED_TOOL_ARGS $FILESYSTEM_SQUASHFS
    sudo -E $sonic_su_prod_detached_signing_tool $SECURE_UPGRADE_PROD_DETACHED_TOOL_ARGS dockerfs.tar

    ## Compress docker files
    pushd $FILESYSTEM_ROOT && sudo tar -cf $OLDPWD/dockerfs.tar -C ${DOCKERFS_PATH}var/lib/docker .; popd

    FSSQUASH_SHA512=${FILESYSTEM_SQUASHFS}.sha512
    DOCKERFS_SHA512=dockerfs.tar.sha512
    echo "Generating sha512 for ${FILESYSTEM_SQUASHFS}..."
    sudo openssl dgst -sha512 -sign "$SHA512_PRIV_KEY" -out ${FSSQUASH_SHA512} ${FILESYSTEM_SQUASHFS}
    echo "Generating sha512 for dockerfs.tar..."
    sudo openssl dgst -sha512 -sign "$SHA512_PRIV_KEY" -out ${DOCKERFS_SHA512} dockerfs.tar
    rm -f $SHA512_PRIV_KEY

    ## Compress the files now
    sudo tar -I pigz -cf $FILESYSTEM_DOCKERFS dockerfs.tar
    pushd $FILESYSTEM_ROOT && sudo zip -n .gz $OLDPWD/$INSTALLER_PAYLOAD -r boot/; popd

    ## Zip all of the pieces together along with the required keys
    sudo zip -g -n .squashfs:.gz $INSTALLER_PAYLOAD $FILESYSTEM_SQUASHFS $FILESYSTEM_DOCKERFS $FSSQUASH_SIGFILE $DOCKERFS_SIGFILE \
    $FSSQUASH_SHA512 $DOCKERFS_SHA512
}
