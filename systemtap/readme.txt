sudo stap -e 'probe process("/tmp/test").function("vfpf") { printf("=> %s(%s)\n", probefunc(), $$parms); }' -c "/tmp/test"

注意：systemtap只能使用内核及/usr/share/systemtap/runtime/目录的头文件（从源码的buildrun.cxx中可以看到甚至都不包括/usr/include/目录),
    故当在systemtap中内嵌C时仅对内核友好。对于用户态应用，一是可以将应用的头文件移到/usr/share/systemtap/runtime目录，或者将systemtap
    脚本中用到的结构体都层层嵌套的移到脚本中，这样相当麻烦，但还未想到更好的方法。

当使用vhost-net时，出虚机的流量有丢包现象。可采用systemtap查看vring的rx/tx列队情况。

# Install HWE kernels
#sudo apt install -y linux-generic-lts-xenial
#sudo apt install --install-recommends linux-generic-hwe-16.04

# Install systemtap
sudo apt install systemtap 

# Add the debug symbols repository 
echo "deb http://ddebs.ubuntu.com $(lsb_release -cs) main restricted universe multiverse 
deb http://ddebs.ubuntu.com $(lsb_release -cs)-updates main restricted universe multiverse 
deb http://ddebs.ubuntu.com $(lsb_release -cs)-proposed main restricted universe multiverse" |sudo tee -a /etc/apt/sources.list.d/ddebs.list 
sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 428D7C01 C8CAB6595FDFF622 
sudo apt update
sudo apt install linux-image-$(uname -r)-dbgsym

# Use systemtap in host
sudo stap -g --skip-badvars ./host-queryqemu.stp $(pidof qemu-system-x86_64) | tee -a /home/ubuntu/sf00156382/logs.$(date +'%F_%T') 

例如，我们观测到的数据如下，可以看出，guest的RX没有变化。

RX 0 values: old=34264 new=34264 last_used_event=34263 vring_used=0 vring_avail=0 
TX 6297677760 values: old=30401 new=30402 last_used_event=0 vring_used=30402 vring_avail=30402 

RX 0 values: old=34264 new=34264 last_used_event=34263 vring_used=0 vring_avail=0 
TX 6297677760 values: old=30403 new=30404 last_used_event=0 vring_used=30404 vring_avail=30404 

为什么没有变化呢？让我们先回顾一下vring理论知识：

Guest发数据：guest将发送报文Buffer的head index加入avial_ring中， 在合适的时间点通过ioeventfds消息来通知backend。backend发完报文后再将其加入到used_ring中，并在一个合适的时间点来通过irqdfs中断来通知guest。
Guest收数据：两个queue都需要guest填充buffer, guest将空白Buffer的head index加入avail_ring中，在合适的时间点通过ioeventfds消息来通知backend。backend收完报文后再将其加入到used_ring中，并在一个合适的时间点来通过irqdfs中断来通知guest。
什么叫合适的时间点呢？代码中有两种：
Flags, avail_ring与used_ring中都有flags字段，例如avail_ring中的flags字段代表guest告诉host在host发完报文之后是否需要通知guest。
Event trigger, 当VIRTIO_RING_F_EVENT_IDX=True时((flags=0 and use the "used_event" field in used_ring instead))，guest与backend自己决定是否向对方发通知，如guest可能是当avail_ring里没有空间时发，backend则是通过这行发（https://github.com/torvalds/linux/blob/v4.10/drivers/vhost/vhost.c#L2211 )

根据上面的理论我们可以推测应该是此处（https://github.com/torvalds/linux/blob/v4.10/drivers/vhost/vhost.c#L2211）的vhost_nofity()=False，从而导致backend没有执行eventfd_signal向host发通知更新

/* This actually signals the guest, using eventfd. */
void vhost_signal(struct vhost_dev *dev, struct vhost_virtqueue *vq)
{
	/* Signal the Guest tell them we used something up. */
	if (vq->call_ctx && vhost_notify(dev, vq))
		eventfd_signal(vq->call_ctx, 1);
}

根据systemtap观察到的结果可以计算

: old=7077 new=7077 last_used_event=0 vring_used=7077 vring_avail=7077 
1. False: (7077 + 256) - 0 - 1 < (7077 + 256) - 7077 
2. False: 7077 - 0 - 1 < 7077 - 7077 

不过，它本来开始就应该是False的，然后backend在将所有包发完之后才设置为True，这样backend再通知guest。
如果host比guest发数据慢，那样backend还未设置True通知guest，那样guest无法释放used_ring并为avail_ring生成缓冲，那样guest无缓冲可用它发包的时候就会报'No buffer space available'之类的。
