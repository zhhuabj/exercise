#!/bin/bash 
# 
# 该脚本将创建raw格式的虚机镜像，使用debootstrap创建根文件系统，安装grub到根分区，同时也安装了EFI启动分区。可从注释获取更详细解释。
# truncate -s 5G my.img
# myloop=$(losetup --find --show my.img)
# ./build_qemu_image_efi_raw.sh $myloop demo           #create chroot
# ./build_qemu_image_efi_raw.sh $myloop demo chroot/   #not create chroot
# 

DISK=$1
BOOTLABEL=$2
ROOTDIR=$3
 
if [ -z "$DISK" -o -z "$BOOTLABEL" ]; then
  echo "Syntax: $0 <image|disk> <root-label> [<chroot-dir>]"
  exit 1
fi
 
if [ "$UID" != "0" ]; then
  echo "Must be root."
  exit 1
fi
 
# Exit on errors
set -xe
 
# 安装依赖包
apt-get install -y --force-yes \
  debootstrap \
  gdisk \
  rsync \
  grub-efi-amd64-bin \
  e2fsprogs
 
# 制作根文件分区，安装grub，创建登录用户
if [ -z "$ROOTDIR" ]; then
  ROOTDIR=chroot/
  
  # Bootstrap minimal system
  debootstrap --variant=minbase xenial chroot
 
  # Install kernel and grub
  for d in dev sys proc; do mount --bind /$d chroot/$d; done

  DEBIAN_FRONTEND=noninteractive chroot chroot apt-get install linux-image-generic grub-pc -y --force-yes

  # Add one user non-interactively
  chroot chroot userdel -r -f hua > /dev/null 2>&1
  #chroot chroot useradd -g users -G root -s /bin/bash -d /home/hua -m hua
  chroot chroot adduser --disabled-password --gecos "" hua
  echo "hua:password" | chpasswd -R chroot
  echo 'hua ALL=(ALL) NOPASSWD: ALL' >> chroot/etc/sudoers
  mkdir -p "chroot/home/hua/.ssh"
  cat /home/hua/.ssh/{id_*.pub,authorized_keys} 2>/dev/null | sort -u > "chroot/home/hua/.ssh/authorized_keys"
  # root user
  echo "root:password" | chpasswd -R "chroot"
  mkdir -p "chroot/root/.ssh"
  cat /home/hua/.ssh/{id_*.pub,authorized_keys} 2>/dev/null | sort -u > "chroot/root/.ssh/authorized_keys"

  umount chroot/{dev,proc,sys}
fi
 
# 创建一个GPT磁盘，并分三个区：
# 1M BIOS Boot Partition
# 100M EFI Partition
# ROOT Partition
if [ ! -b "${DISK}" ]; then
  truncate --size 5G $DISK
fi
# Create partition layout
#sgdisk --clear \
#  --new 1::+1M --typecode=1:ef02 --change-name=1:'BIOS boot partition' \
#  --new 2::+100M --typecode=2:ef00 --change-name=2:'EFI System' \
#  --new 3::-0 --typecode=3:8300 --change-name=3:'Linux root filesystem' \
#  $DISK 
gdisk ${DISK} << EOF
o
y
n
1

+1M
ef02
n
2

+100M
ef00
n
3


8300
p
w
y
EOF
 
# 对GPT磁盘作一些设置
# 1, 将根分区格式化为ext4格式，同时将EFI分区格式化为fat32格式
# 2, 将我们制作的根文件系统拷贝到根分区
# 3, 在根分区中安装grub (因为用的是GPT，所以安装GRUB时也要安装ext2与part_gpt模块)
# 4, 更新grub
LOOPDEV=$(losetup --find --show $DISK)
partprobe ${LOOPDEV}
 
# Create filesystems
mkfs.fat -F32 ${LOOPDEV}p2
mkfs.ext4 -F -L "${BOOTLABEL}" ${LOOPDEV}p3
 
# Mount OS partition, copy chroot, install grub
MOUNTDIR=$(mktemp -d -t demoXXXXXX)
mount ${LOOPDEV}p3 ${MOUNTDIR}
 
rsync -a ${ROOTDIR}/ ${MOUNTDIR}/
 
for d in dev sys proc; do mount --bind /$d ${MOUNTDIR}/$d; done
chroot ${MOUNTDIR}/ grub-install --modules="ext2 part_gpt" ${LOOPDEV}
chroot ${MOUNTDIR}/ update-grub
 
umount $MOUNTDIR/{dev,proc,sys,}
rmdir $MOUNTDIR
 
# 安装EFI分区(/boot/efi type vfat)
# 1, 使用grub-mkimage命令根据本机的/usr/lib/grub/x86_64-efi模块(本机需安装grub-efi-amd64-bin)生成efi模块(/boot/efi/EFI/BOOT/bootx64.efi)
# 2, 生成/boot/efi/EFI/BOOT/grub.cfg, 它会根据配置文件再加载根分区上的grub.cfg (/boot/grub/grub.cfg)
MOUNTDIR=$(mktemp -d -t demoXXXXXX)
mount ${LOOPDEV}p2 $MOUNTDIR
 
mkdir -p ${MOUNTDIR}/EFI/BOOT
grub-mkimage \
  -d /usr/lib/grub/x86_64-efi \
  -o ${MOUNTDIR}/EFI/BOOT/bootx64.efi \
  -p /efi/boot \
  -O x86_64-efi \
    fat iso9660 part_gpt part_msdos normal boot linux configfile loopback chain efifwsetup efi_gop \
    efi_uga ls search search_label search_fs_uuid search_fs_file gfxterm gfxterm_background \
    gfxterm_menu test all_video loadenv exfat ext2 ntfs btrfs hfsplus udf
 
# Create grub config
cat <<GRUBCFG > ${MOUNTDIR}/EFI/BOOT/grub.cfg
search --label "${BOOTLABEL}" --set prefix
configfile (\$prefix)/boot/grub/grub.cfg
GRUBCFG
 
umount $MOUNTDIR
rmdir $MOUNTDIR
 
# Remove loop device
sync ${LOOPDEV} 
losetup -d ${LOOPDEV}
 
echo "Done. ${DISK} is ready to be booted via BIOS and UEFI."

# Test the base image
# qemu-system-x86_64 -m 2048  my.img -serial stdio  #It's sda, and also need to change device.map
# qemu-system-x86_64 -m 2048 -drive file=my.img,if=virtio -serial stdio  #It's vda, and it requires device.map
BASE_MAC="52:54:74:b7:10:"
# qemu-system-x86_64 -m 2048 -drive file=my.img,if=virtio -device virtio-net-pci,netdev=net1,mac=${BASE_MAC}fd -netdev tap,id=net1,script=/tmp/qemu-ifup,downscript=/tmp/qemu-ifdown

# Burning to disk
#dd if=/dev/nbd0 of=/dev/sdb bs=4M; sync

# 创建dhcp服务器
BASE_MAC="52:54:74:b7:10:"
NETWORK="192.168.123."
apt-get install -y qemu-kvm bridge-utils dnsmasq
declare -i result=$(brctl show | grep demobr0 | wc -l)
if [ $result == 0 ]; then
   brctl addbr demobr0
   brctl stp demobr0 off
   ip link set demobr0 up
   if [ -n "$PHY_IF" ]; then
     ifconfig $PHY_IF 0.0.0.0 up
     brctl addif demobr0 $PHY_IF
   fi
   sleep 1
   ifconfig demobr0 ${NETWORK}1/24
   echo 'create bridge demobr0 success'
   echo 1 > /proc/sys/net/ipv4/ip_forward
   iptables -t nat -A POSTROUTING -s ${NETWORK}0/24 -d ${NETWORK}0/24 -j ACCEPT
   iptables -t nat -A POSTROUTING -s ${NETWORK}0/24 -j MASQUERADE
fi
brctl show

# dnsmasq
service dnsmasq stop
echo "${BASE_MAC}fd,${NETWORK}249,guest" > /tmp/dhcphosts
echo "${BASE_MAC}fe,${NETWORK}250,guest" >> /tmp/dhcphosts
tee "/tmp/dnsmasq.conf" <<EOF
interface=demobr0
except-interface=lo
bind-interfaces
dhcp-range=${NETWORK}1,${NETWORK}250,12h
EOF
PID=$(ps -eo pid,cmd |grep -E '([0-9]+)\s+[^0-9]+dnsmasq' |grep demobr0 |awk '{print $1}')
if [ -n "$PID" ]; then
  kill -9 $PID
fi
dnsmasq -C /tmp/dnsmasq.conf --dhcp-hostsfile=/tmp/dhcphosts --pid-file=/tmp/demobr0-dnsmasq.pid

tee "/tmp/qemu-ifup" <<EOF
#!/bin/sh
switch=demobr0
if [ -n "\$1" ];then
        sudo tunctl -u \`whoami\` -t \$1
        sudo ip link set \$1 up 2>/dev/null
        sleep 1
        sudo brctl addif \$switch \$1
        exit 0
else
        echo "Error: no interface specified"
        exit 1
fi
EOF
tee "/tmp/qemu-ifdown" <<EOF
#!/bin/sh
switch=demobr0
if [ -n "\$1" ];then
        sudo ip link set \$1 down
        sudo brctl delif \$switch \$1 2>/dev/null
        sudo tunctl -d \$1
        exit 0
else
        echo "Error: no interface specified"
        exit 1
fi
EOF
chmod 777 /tmp/qemu-ifup && chmod 777 /tmp/qemu-ifdown
apt-get install -y uml-utilities

# 启动一个测试虚机
QEMU_PID=$(ps -eo pid,cmd |grep qemu-system-x86_64 |grep '/tmp/qemu-ifup' |awk '{print $1}')
if [ -n "$QEMU_PID" ]; then
  kill -9 $QEMU_PID
fi
BASE_MAC="52:54:74:b7:10:"
sudo qemu-system-x86_64 -enable-kvm -machine q35 -smp 8 -m 4096 \
-name guest=guest,debug-threads=on \
-device virtio-net-pci,netdev=net0,mac=${BASE_MAC}fe \
-netdev tap,id=net0,script=/tmp/qemu-ifup,downscript=/tmp/qemu-ifdown \
-device virtio-net-pci,netdev=net1,mac=${BASE_MAC}fd \
-netdev tap,id=net1,script=/tmp/qemu-ifup,downscript=/tmp/qemu-ifdown \
-drive file=my.img,if=virtio \
-numa node,nodeid=0,cpus=0-3 \
-numa node,nodeid=1,cpus=4-7 \
-chardev socket,id=monitor,path=/tmp/guest.monitor,server,nowait \
-monitor chardev:monitor \
-chardev socket,id=serial,path=/tmp/guest.serial,server,nowait \
-serial chardev:serial \
#-curses
#-serial stdio

cat /tmp/dhcphosts
echo " - SSH: hua@${NETWORK}250 (password: password)"
echo " OR: minicom -D unix\#/tmp/guest.monitor"
