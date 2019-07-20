# Precondition
local_host="`hostname --fqdn`"
local_ip=`host $local_host 2>/dev/null | awk '{print $NF}' |head -n 1`
sudo bash -c 'cat >> /etc/hosts' << EOF
`echo $local_ip`   `echo $local_host`
EOF
sudo sed -i "/$local_host/"d /etc/hosts
ssh-copy-id -i ~/.ssh/id_rsa.pub $local_ip
ping -c 1 $local_ip

# Create two disk for test
sudo mkdir -p /images && sudo chown $(whoami) /images
dd if=/dev/zero of=/images/ceph-volumes.img bs=1M count=8192 oflag=direct
sudo losetup -d /dev/loop0 > /dev/null 2>&1
sudo vgremove -y ceph-volumes > /dev/null 2>&1
sudo vgcreate ceph-volumes $(sudo losetup --show -f /images/ceph-volumes.img)
sudo lvcreate -L2G -nceph0 ceph-volumes
sudo lvcreate -L2G -nceph1 ceph-volumes
sudo mkfs.xfs -f /dev/ceph-volumes/ceph0
sudo mkfs.xfs -f /dev/ceph-volumes/ceph1
sudo mkdir -p /srv/ceph/{osd0,osd1,mon0,mds0} && sudo chown -R $(whoami) /srv
sudo mount /dev/ceph-volumes/ceph0 /srv/ceph/osd0
sudo mount /dev/ceph-volumes/ceph1 /srv/ceph/osd1

# Deploy new monitor node
sudo apt update && sudo apt-cache policy ceph-deploy
sudo apt install -y ceph ceph-deploy
mkdir -p ceph-cluster && cd ceph-cluster
ceph-deploy new $local_host
echo "osd crush chooseleaf type = 0" >> ceph.conf
echo "osd pool default size = 1" >> ceph.conf
echo "osd journal size = 100" >> ceph.conf
echo "rbd_default_features = 1" >> ceph.conf

# Install ceph packages to other nodes
#ceph-deploy purgedata $local_host && ceph-deploy forgetkeys
ceph-deploy install $local_host
ceph-conf --name mon.monitor --show-config-value admin_socket

# Generate the keys
ceph-deploy mon destroy $local_host    #monitor is not yet in quorum
ceph-deploy --overwrite-conf mon create-initial

# Prepare OSDs
#ceph-deploy osd prepare ${local_host}:sdb1:sdc
ceph-deploy osd prepare ${local_host}:/srv/ceph/osd0
ceph-deploy osd prepare ${local_host}:/srv/ceph/osd1

# Active OSDs
sudo chmod 777 /srv/ceph/osd0
sudo chmod 777 /srv/ceph/osd1
sudo ceph-deploy osd activate ${local_host}:/srv/ceph/osd0
sudo ceph-deploy osd activate ${local_host}:/srv/ceph/osd1

# Copy the keys to other nodes
ceph-deploy admin $local_host
sudo chmod +r /etc/ceph/ceph.client.admin.keyring

# Verify
sudo ceph -s
sudo ceph osd tree 

# How to use it as block devices
sudo modprobe rbd
sudo rados mkpool data
sudo ceph osd pool set data min_size 1 
sudo rbd create --size 1 -p data test1
sudo rados -p data ls
sudo rbd map test1 --pool data
rbd showmapped
sudo mkfs.ext4 /dev/rbd0
mkdir test && sudo mount /dev/rbd0 test/
sudo umount test && sudo rbd unmap /dev/rbd0 /dev/null 2>&1
