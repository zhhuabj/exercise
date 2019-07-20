#Prepare a machine for test, the name of machine is node1
#nova boot --key-name mykey --image auto-sync/ubuntu-xenial-16.04-amd64-server-20171116-disk1.img --flavor m1.large --nic net-id=$(neutron net-list |grep 'zhhuabj_admin_net' |awk '{print $2}') node1
#nova floating-ip-associate node1 10.230.65.123
#ssh ubuntu@10.230.65.123 -v

# Precondition
sudo -i
echo '127.0.0.1       localhost' >> /etc/hosts
echo '192.168.99.124 node1' >> /etc/hosts
exit

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
sudo update && sudo apt-cache policy ceph-deploy
sudo apt -y install ceph ceph-deploy
mkdir -p ceph-cluster && cd ceph-cluster
ceph-deploy new node1
echo "osd crush chooseleaf type = 0" >> ceph.conf
echo "osd pool default size = 1" >> ceph.conf
echo "osd journal size = 100" >> ceph.conf
echo "rbd_default_features = 1" >> ceph.conf

# Install ceph packages to other nodes
#ceph-deploy purgedata node1 && ceph-deploy forgetkeys
ceph-deploy install node1

# Generate the keys
ceph-deploy mon create-initial

# Prepare OSDs
#ceph-deploy osd prepare node1:sdb1:sdc
ceph-deploy osd prepare node1:/srv/ceph/osd0
ceph-deploy osd prepare node1:/srv/ceph/osd1

# Active OSDs
sudo chmod 777 /srv/ceph/osd0
sudo chmod 777 /srv/ceph/osd1
sudo ceph-deploy osd activate node1:/srv/ceph/osd0
sudo ceph-deploy osd activate node1:/srv/ceph/osd1

# Copy the keys to other nodes
ceph-deploy admin node1
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
#sudo rbd unmap /dev/rbd0 /dev/null 2>&1
sudo rbd map test1 --pool data
rbd showmapped
sudo mkfs.ext4 /dev/rbd0
mkdir test && sudo mount /dev/rbd0 test/
