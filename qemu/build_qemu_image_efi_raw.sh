#!/bin/bash 
# 
# 该脚本将创建raw格式的虚机镜像，使用debootstrap创建根文件系统，安装grub到根分区，同时也安装了EFI启动分区。可从注释获取更详细解释。
# ./build_qemu_image_efi_raw.sh      #create chroot
# ./build_qemu_image_efi_raw.sh no   #not create chroot
# 

MAKEROOTFS=$1
BOOTLABEL=BOOT
if [ "$UID" != "0" ]; then
  echo "Must be root."
  exit 1
fi
 
# Exit on errors
set -xe
 
if [ ! -f "os.img" ]; then
  truncate -s 5G os.img
fi
is_looped=$(losetup -a |grep 'os.img')
if [ ! -n "$is_looped" ]; then
  LOOPDEV=$(losetup --find --show os.img)
fi

# install some packages
apt-get install -y --force-yes \
  debootstrap \
  gdisk \
  rsync \
  grub-efi-amd64-bin \
  e2fsprogs
 
# make ./rootfs, install grub, and create login user(demo/password)
if [ -z "$MAKEROOTFS" ]; then
  # Bootstrap minimal system
  debootstrap --variant=minbase bionic rootfs
 
  for d in dev sys proc; do mount --bind /$d rootfs/$d; done

cat << EOF > rootfs/etc/apt/sources.list
deb http://mirrors.aliyun.com/ubuntu/ bionic main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ bionic-security main restricted universe multiverse
deb http://mirrors.aliyun.com/ubuntu/ bionic-updates main restricted universe multiverse
EOF
  DEBIAN_FRONTEND=noninteractive chroot rootfs apt-get update
  DEBIAN_FRONTEND=noninteractive chroot rootfs apt-get install linux-image-generic grub-pc -y --force-yes

  chroot rootfs userdel -r -f demo > /dev/null 2>&1
  #chroot rootfs useradd -g users -G root -s /bin/bash -d /home/demo -m demo
  chroot rootfs adduser --disabled-password --gecos "" demo
  #echo "demo:password" | chpasswd --root rootfs
  echo "demo:password" |chroot rootfs /usr/sbin/chpasswd
  echo 'demo ALL=(ALL) NOPASSWD: ALL' >> rootfs/etc/sudoers
  mkdir -p "rootfs/home/demo/.ssh"
  cat /home/demo/.ssh/{id_*.pub,authorized_keys} 2>/dev/null | sort -u > "rootfs/home/demo/.ssh/authorized_keys"
  echo "root:password" |chroot rootfs /usr/sbin/chpasswd
  mkdir -p "rootfs/root/.ssh"
  cat /home/demo/.ssh/{id_*.pub,authorized_keys} 2>/dev/null | sort -u > "rootfs/root/.ssh/authorized_keys"

  umount rootfs/{dev,proc,sys}
fi


 
# Create a GPT disk, divide it into three partitions
# 1M BIOS Boot Partition
# 100M EFI Partition
# ROOT Partition
# Create partition layout
#sgdisk --clear \
#  --new 1::+1M --typecode=1:ef02 --change-name=1:'BIOS boot partition' \
#  --new 2::+100M --typecode=2:ef00 --change-name=2:'EFI System' \
#  --new 3::-0 --typecode=3:8300 --change-name=3:'Linux root filesystem' \
#  $LOOPDEV 
gdisk ${LOOPDEV} << EOF
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
 
# 安装./rootfs与grub到${LOOPDEV}p3
# 1, 将根分区(${LOOPDEV}p3)格式化为ext4格式，同时将EFI分区(${LOOPDEV}p2)格式化为fat32格式
# 2, 将我们用bootstrap制作的根文件系统拷贝到根分区(rsync -a rootfs/ ${MOUNTDIR}/)
# 3, 在根分区中安装grub (因为用的是GPT，所以安装GRUB时也要安装ext2与part_gpt模块)
# 4, 更新grub
partprobe ${LOOPDEV} && sleep 5

mkfs.fat -F32 ${LOOPDEV}p2
mkfs.ext4 -F -L "${BOOTLABEL}" ${LOOPDEV}p3

MOUNTDIR=$(mktemp -d -t demoXXXXXX)
mount ${LOOPDEV}p3 ${MOUNTDIR}
rsync -a rootfs/ ${MOUNTDIR}/
 
for d in dev sys proc; do mount --bind /$d ${MOUNTDIR}/$d; done
chroot ${MOUNTDIR}/ grub-install --modules="ext2 part_gpt" ${LOOPDEV}
chroot ${MOUNTDIR}/ update-grub
 
umount $MOUNTDIR/{dev,proc,sys,}
rmdir $MOUNTDIR
 
# 安装EFI分区到${LOOPDEV}p2设备(/boot/efi type vfat)
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

#e2label ${${LOOPDEV}}p3 ${BOOTLABEL}
#blkid
cat <<GRUBCFG > ${MOUNTDIR}/EFI/BOOT/grub.cfg
search --label "${BOOTLABEL}" --set prefix
configfile (\$prefix)/boot/grub/grub.cfg
GRUBCFG

# Remove loop device
umount $MOUNTDIR
sync ${LOOPDEV} 
losetup -d ${LOOPDEV}
 
echo "Done. ${DISK} is ready to be booted via BIOS and UEFI."

# Test the base image
# qemu-system-x86_64 -m 2048 os.img -serial stdio  #It's sda, and also need to change device.map
# qemu-system-x86_64 -m 2048 -drive file=os.img,if=virtio -serial stdio  #It's vda, and it requires device.map
BASE_MAC="52:54:74:b7:10:"
# qemu-system-x86_64 -m 2048 -drive file=os.img,if=virtio -device virtio-net-pci,netdev=net1,mac=${BASE_MAC}fd -netdev tap,id=net1,script=/tmp/qemu-ifup,downscript=/tmp/qemu-ifdown

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
echo " - SSH: demo@${NETWORK}250 (password: password)"
echo " OR: minicom -D unix\#/tmp/guest.monitor"
