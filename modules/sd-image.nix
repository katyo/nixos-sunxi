# This module creates a bootable SD card image containing the given NixOS
# configuration. The generated image is MBR partitioned, with a FAT
# /boot/firmware partition, and ext4 root partition. The generated image
# is sized to fit its contents, and a boot script automatically resizes
# the root partition to fit the device on the first boot.
#
# The firmware partition is built with expectation to hold the Raspberry
# Pi firmware and bootloader, and be removed and replaced with a firmware
# build for the target SoC for other board families.
#
# The derivation for the SD image will be placed in
# config.system.build.sdImage

{ config, lib, pkgs, ... }:

with lib;

let
  rootfsImage = pkgs.callPackage <nixpkgs/nixos/lib/make-ext4-fs.nix> ({
    inherit (config.sdImage) storePaths;
    compressImage = true;
    populateImageCommands = config.sdImage.populateRootCommands;
    volumeLabel = "NIXOS_SD";
  } // optionalAttrs (config.sdImage.rootPartitionUUID != null) {
    uuid = config.sdImage.rootPartitionUUID;
  });

  hasFirmwarePartition = with config.sdImage;
    firmwarePartition && firmwarePartitionSize > 0;

  compressedImageExtension = with config.sdImage;
    if compressImage then
      (if compressImageMethod == "zstd" then ".zst"
       else ".${compressImageMethod}") else "";

  compressLevelCmdLineArg = with config.sdImage;
    lib.optionalString (compressImageLevel != null)
      "-${toString compressImageLevel}";
in
{
  imports = [
    (mkRemovedOptionModule [ "sdImage" "bootPartitionID" ] "The FAT partition for SD image now only holds the Raspberry Pi firmware files. Use firmwarePartitionID to configure that partition's ID.")
    (mkRemovedOptionModule [ "sdImage" "bootSize" ] "The boot files for SD image have been moved to the main ext4 partition. The FAT partition now only holds the Raspberry Pi firmware files. Changing its size may not be required.")
    <nixpkgs/nixos/modules/profiles/all-hardware.nix>
  ];

  options.sdImage = {
    imageName = mkOption {
      default = "${config.sdImage.imageBaseName}-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.img";
      description = ''
        Name of the generated image file.
      '';
    };

    imageBaseName = mkOption {
      default = "nixos-sd-image";
      description = ''
        Prefix of the name of the generated image file.
      '';
    };

    storePaths = mkOption {
      type = with types; listOf package;
      example = literalExpression "[ pkgs.stdenv ]";
      description = ''
        Derivations to be included in the Nix store in the generated SD image.
      '';
    };

    ubootPackage = mkOption {
      type = types.nullOr types.package;
      description = ''
        U-Boot package to use bootloader binary from.
      '';
    };

    ubootBinary = mkOption {
      type = types.str;
      default = "u-boot-*.bin";
      example = "u-boot-sunxi-with-spl.bin";
      description = ''
        U-Boot binary image name or pattern.
      '';
    };

    ubootOffset = mkOption {
      type = types.ints.unsigned;
      default = 8;
      description = ''
        U-Boot binary offset in kibibytes (1024 bytes).
      '';
    };

    partitionsOffset = mkOption {
      type = types.ints.unsigned;
      default = 8;
      description = ''
        Gap in front of the partitions, in mebibytes (1024×1024 bytes).
        Can be increased to make more space for boards requiring to dd u-boot
        SPL before actual partitions.

        Unless you are building your own images pre-configured with an
        installed U-Boot, you can instead opt to delete the existing `FIRMWARE`
        partition, which is used **only** for the Raspberry Pi family of
        hardware.
      '';
    };

    firmwarePartition = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enables firmware partition on SD card for specific use cases,
        particularly for Raspberry Pi.
      '';
    };

    firmwarePartitionID = mkOption {
      type = types.str;
      default = "0x2178694e";
      description = ''
        Volume ID for the /boot/firmware partition on the SD card. This value
        must be a 32-bit hexadecimal number.
      '';
    };

    firmwarePartitionName = mkOption {
      type = types.str;
      default = "FIRMWARE";
      description = ''
        Name of the filesystem which holds the boot firmware.
      '';
    };

    rootPartitionUUID = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "14e19a7b-0ae0-484d-9d54-43bd6fdc20c7";
      description = ''
        UUID for the filesystem on the main NixOS partition on the SD card.
      '';
    };

    firmwarePartitionSize = mkOption {
      type = types.ints.unsigned;
      # As of 2019-08-18 the Raspberry pi firmware + u-boot takes ~18MiB
      default = 30;
      description = ''
        Size of the /boot/firmware partition, in megabytes.
      '';
    };

    populateFirmwareCommands = mkOption {
      example = literalExpression "'' cp \${pkgs.myBootLoader}/u-boot.bin firmware/ ''";
      description = ''
        Shell commands to populate the ./firmware directory.
        All files in that directory are copied to the
        /boot/firmware partition on the SD image.
      '';
    };

    populateRootCommands = mkOption {
      example = literalExpression "''\${config.boot.loader.generic-extlinux-compatible.populateCmd} -c \${config.system.build.toplevel} -d ./files/boot''";
      description = ''
        Shell commands to populate the ./files directory.
        All files in that directory are copied to the
        root (/) partition on the SD image. Use this to
        populate the ./files/boot (/boot) directory.
      '';
    };

    postBuildCommands = mkOption {
      example = literalExpression "'' dd if=\${pkgs.myBootLoader}/SPL of=$img bs=1024 seek=1 conv=notrunc ''";
      default = "";
      description = ''
        Shell commands to run after the image is built.
        Can be used for boards requiring to dd u-boot SPL before actual partitions.
      '';
    };

    compressImage = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether the SD image should be compressed using
        <command>zstd</command> or <command>xz</command>.
      '';
    };

    compressImageMethod = mkOption {
      type = types.strMatching "^zstd|xz|lzma$";
      default = "zstd";
      description = ''
        The program which will be used to compress SD image.
      '';
    };

    compressImageLevel = mkOption {
      type = types.nullOr (types.ints.between 0 9);
      default = null;
      description = ''
        Image compression level to override default.
      '';
    };

    expandOnBoot = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether to configure the sd image to expand it's partition on boot.
      '';
    };
  };

  config = {
    fileSystems = {
      "/boot/firmware" = {
        device = "/dev/disk/by-label/${config.sdImage.firmwarePartitionName}";
        fsType = "vfat";
        # Alternatively, this could be removed from the configuration.
        # The filesystem is not needed at runtime, it could be treated
        # as an opaque blob instead of a discrete FAT32 filesystem.
        options = [ "nofail" "noauto" ];
      };
      "/" = {
        device = "/dev/disk/by-label/NIXOS_SD";
        fsType = "ext4";
      };
    };

    sdImage.storePaths = [ config.system.build.toplevel ];

    system.build.sdImage = pkgs.callPackage ({
      stdenv, dosfstools, e2fsprogs,
      mtools, libfaketime, util-linux, zstd, xz
    }: stdenv.mkDerivation {
      name = config.sdImage.imageName;

      nativeBuildInputs = [ dosfstools e2fsprogs mtools libfaketime util-linux zstd xz ];

      buildCommand = ''
        mkdir -p $out/nix-support $out/sd-image
        export img=$out/sd-image/${config.sdImage.imageName}

        echo "${pkgs.stdenv.buildPlatform.system}" > $out/nix-support/system
        echo "file sd-image $img${compressedImageExtension}" >> $out/nix-support/hydra-build-products

        echo "Decompressing rootfs image"
        zstd -d --no-progress "${rootfsImage}" -o ./root-fs.img

        blockSize=512
        partitionsOffset=${toString config.sdImage.partitionsOffset}

        ${if hasFirmwarePartition then ''
        firmwarePartitionNumber=1
        firmwarePartitionOffset=$partitionsOffset
        firmwarePartitionSizeBlocks=$((${toString config.sdImage.firmwarePartitionSize} * 1024 * 1024 / blockSize))
        firmwarePartitionSize=$((firmwarePartitionSizeBlocks * blockSize))
        rootPartitionNumber=2
        rootPartitionOffset=$((firmwarePartitionOffset + firmwarePartitionSize))
        '' else ''
        rootPartitionNumber=1
        rootPartitionOffset=$partitionsOffset
        ''}

        # Create the image file sized to fit /boot/firmware and /, plus slack for the gap.
        rootPartitionSizeBlocks=$(du -B $blockSize --apparent-size ./root-fs.img | awk '{ print $1 }')
        rootPartitionSize=$((rootPartitionSizeBlocks * blockSize))

        imageSize=$((rootPartitionOffset + rootPartitionSize))
        truncate -s $imageSize $img

        # type=b is 'W95 FAT32', type=83 is 'Linux'.
        # The "bootable" partition is where u-boot will look file for the bootloader
        # information (dtbs, extlinux.conf file).
        sfdisk $img <<EOF
            label: dos
            label-id: ${config.sdImage.firmwarePartitionID}

            ${lib.optionalString hasFirmwarePartition ''
            start=$firmwarePartitionOffset, size=$firmwarePartitionSizeBlocks, type=b
            ''}
            start=$rootPartitionOffset, type=83, bootable
        EOF

        # Copy the rootfs into the SD image
        eval $(partx $img -o START,SECTORS --nr $rootPartitionNumber --pairs)
        dd conv=notrunc if=./root-fs.img of=$img seek=$START count=$SECTORS

        ${lib.optionalString hasFirmwarePartition ''
        # Create a FAT32 /boot/firmware partition of suitable size into firmware_part.img
        eval $(partx $img -o START,SECTORS --nr $firmwarePartitionNumber --pairs)
        truncate -s $((SECTORS * blockSize)) firmware_part.img
        faketime "1970-01-01 00:00:00" mkfs.vfat -i ${config.sdImage.firmwarePartitionID} -n ${config.sdImage.firmwarePartitionName} firmware_part.img

        # Populate the files intended for /boot/firmware
        mkdir firmware
        ${config.sdImage.populateFirmwareCommands}

        # Copy the populated /boot/firmware into the SD image
        (cd firmware; mcopy -psvm -i ../firmware_part.img ./* ::)
        # Verify the FAT partition before copying it.
        fsck.vfat -vn firmware_part.img
        dd conv=notrunc if=firmware_part.img of=$img seek=$START count=$SECTORS
        ''}

        ${lib.optionalString (config.sdImage.ubootPackage != null) ''
        # Install U-Boot binary image
        dd if=${config.sdImage.ubootPackage}/${config.sdImage.ubootBinary} of=$img bs=1024 seek=${toString config.sdImage.ubootOffset} conv=notrunc
        ''}

        ${config.sdImage.postBuildCommands}

        ${lib.optionalString config.sdImage.compressImage
          (if config.sdImage.compressImage == "zstd" then ''
            zstd -T$NIX_BUILD_CORES ${compressLevelCmdLineArg} --rm $img
          '' else ''
            xz -T$NIX_BUILD_CORES -F${config.sdImage.compressImageMethod} ${compressLevelCmdLineArg} $img
          '')}
      '';
    }) {};

    boot.postBootCommands = lib.mkIf config.sdImage.expandOnBoot ''
      # On the first boot do some maintenance tasks
      if [ -f /nix-path-registration ]; then
        set -euo pipefail
        set -x
        # Figure out device names for the boot device and root filesystem.
        rootPart=$(${pkgs.util-linux}/bin/findmnt -n -o SOURCE /)
        bootDevice=$(lsblk -npo PKNAME $rootPart)
        partNum=$(lsblk -npo MAJ:MIN $rootPart | ${pkgs.gawk}/bin/awk -F: '{print $2}')

        # Resize the root partition and the filesystem to fit the disk
        echo ",+," | sfdisk -N$partNum --no-reread $bootDevice
        ${pkgs.parted}/bin/partprobe
        ${pkgs.e2fsprogs}/bin/resize2fs $rootPart

        # Register the contents of the initial Nix store
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration

        # nixos-rebuild also requires a "system" profile and an /etc/NIXOS tag.
        touch /etc/NIXOS
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

        # Prevents this from running on later boots.
        rm -f /nix-path-registration
      fi
    '';
  };
}
