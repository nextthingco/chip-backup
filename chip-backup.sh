#! /bin/bash

chmod 0600 id_rsa

if [ "$(uname)" == "Darwin" ]; then
    export FEL=./sunxi-fel
else
    if [[ -z "$(which sunxi-fel)" ]]; then
        echo "${FEL} not found. please enter your password to install"
        sudo apt-get update && sudo apt-get -y install sunxi-tools
    fi

    export FEL=$(which sunxi-fel)
fi

IMAGES="."

SSH="ssh -F ssh_config -i id_rsa root@192.168.81.1"

SPL=${SPL:-$IMAGES/sunxi-spl.bin}
[[ ! -f $SPL ]] && echo "ERROR: $SPL does not exist" && exit 1 

UBOOT=${UBOOT:-$IMAGES/u-boot-dtb.bin}
[[ ! -f $UBOOT ]] && echo "ERROR: $UBOOT does not exist" && exit 1 

KERNEL=${KERNEL:-$IMAGES/zImage}
[[ ! -f $KERNEL ]] && echo "ERROR: $KERNEL does not exist" && exit 1 

DTB=${DTB:-$IMAGES/sun5i-r8-chip.dtb}
[[ ! -f $DTB ]] && echo "ERROR: $DTB does not exist" && exit 1 

INITRD=${INITRD:-$IMAGES/rootfs.cpio.uboot}
[[ ! -f $INITRD ]] && echo "ERROR: $INITRD does not exist" && exit 1 

SCRIPT=${SCRIPT:-$IMAGES/uboot.script}
[[ ! -f $SCRIPT ]] && echo "ERROR: $SCRIPT does not exist" && exit 1 

TIMEOUT=30
wait_for_fel() {
  for ((i=$TIMEOUT; i>0; i--)) {
    if ${FEL} ver 2>/dev/null >/dev/null; then
      echo "OK =="
      return 0;
    fi
    echo -n ".";
    sleep 1
  }

  echo "TIMEOUT";
  return 1
}

wait_for_net() {
  for ((i=$TIMEOUT; i>0; i--)) {
    if ping -c1 -t2 192.168.81.1 2>/dev/null >/dev/null; then
      echo "OK =="
      return 0;
    fi
    echo -n ".";
    sleep 1
  }

  echo "TIMEOUT";
  return 1
}

echo -n "== waiting for CHIP in fel mode..."
wait_for_fel || exit

echo == upload the SPL to SRAM and execute it ==
${FEL} spl $SPL

sleep 1 # wait for DRAM initialization to complete

echo == upload the main u-boot binary to DRAM ==
${FEL} write 0x4a000000 $UBOOT

echo == upload the kernel ==
${FEL} write 0x42000000 $KERNEL

echo == upload the DTB file ==
${FEL} write 0x43000000 $DTB

echo == upload the boot.scr file ==
${FEL} write 0x43100000 $SCRIPT

echo == upload the initramfs file ==
${FEL} write 0x43300000 $INITRD

echo == execute the main u-boot binary ==
${FEL} exe   0x4a000000

echo -n "== waiting for network connection..."
wait_for_net || exit

echo "== executing remote commands =="
${SSH} nanddump -o -n /dev/mtd0 >mtd0.bin
${SSH} nanddump -o -n /dev/mtd1 >mtd1.bin
${SSH} nanddump /dev/mtd2 >mtd2.bin
${SSH} nanddump /dev/mtd3 >mtd3.bin

if [[ "$1" == "raw" ]]; then
    ${SSH} nanddump /dev/mtd4 >mtd4.bin
else
    ${SSH} <<EOF
    ! ubiattach -m4  && echo "ERROR: ubiattach failed" && exit
    
    [[ ! -e /dev/ubi0_0 ]] && echo "ERROR: /dev/ubi0_0 does not exist" && exit
    
    ! mount -t ubifs /dev/ubi0_0 /mnt && echo "ERROR: cannot mount /dev/ubi0_0" && exit
    
    ! cd /mnt && echo "ERROR: cannot cd into /mnt"
EOF
    
    ${SSH} \
    tar cvf - --exclude=dev --exclude=proc --exclude=sys --exclude=tmp --exclude=run --exclude=mnt --exclude=media --exclude=lost\+found -C /mnt . \
    |gzip > backup.tar.gz
    
fi

echo -n "== powering off chip..."
ssh -i ${SSH} poweroff 2>/dev/null >/dev/null
sleep 5
echo "OK =="

