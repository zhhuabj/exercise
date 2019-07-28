#export https_proxy="http://apnpac.com/18027/1945773"
#export HTTPS_PROXY=socks5://127.0.0.1:8080
#sudo polipo socksProxyType=socks5 socksParentProxy=127.0.0.1:8080
#export HTTPS_PROXY=http://192.168.99.1:8123

sudo apt install -y python-setuptools python-dev libpython-dev libssl-dev libmysqlclient-dev libxml2-dev libxslt-dev libxslt1-dev libpq-dev git git-review libffi-dev gettext graphviz libjpeg-dev zlib1g-dev build-essential python-nose python-mock python3-dev python3-nose python3-mock python3.6 python3.6-dev libssl1.1 python-virtualenv
sudo apt remove --purge python-pip python3-pip
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py |sudo python

#sudo pip install -c https://git.openstack.org/cgit/openstack/requirements/plain/upper-constraints.txt?h=stable/ocata .
#sudo pip install -c https://raw.githubusercontent.com/openstack/keystone/stable/ocata/requirements.txt .
#sudo pip install -c https://raw.githubusercontent.com/openstack/keystone/stable/ocata/test-requirements.txt .

find . -name "*.pyc" -exec rm -rf {} \;
rm -rf ~/.cache/pip/*
sudo chown -R $USER  ~/.cache/pip/
sudo pip uninstall -y python_marconiclient
sudo pip uninstall -y virtualenv
sudo apt-get purge -y python-virtualenv
sudo pip install --upgrade virtualenv
sudo pip install --upgrade distribute
sudo rm -rf /usr/local/lib/python2.7/dist-packages/oslo*
sudo rm -rf /usr/local/lib/python2.7/dist-packages/*keystone*
sudo rm -rf /usr/local/lib/python2.7/dist-packages/*glance*
sudo rm -rf /usr/local/lib/python2.7/dist-packages/*swift*
sudo rm -rf /usr/local/lib/python2.7/dist-packages/*cinder*
sudo rm -rf /usr/local/lib/python2.7/dist-packages/*nova*
sudo rm -rf /usr/local/lib/python2.7/dist-packages/*neutron*
root_dir=/bak/openstack
for pro in keystone glance cinder horizon nova neutron neutron-fwaas neutron-lbaas requirements tempest; do
  echo $pro
  cd $pro
  git diff > diff && git checkout . && git checkout master
  git pull
  sudo pip uninstall -r requirements.txt
  sudo pip uninstall -r test-requirements.txt
  sudo pip install --upgrade -r requirements.txt
  sudo pip install --upgrade -r test-requirements.txt
  sudo python setup.py develop
  cd $root_dir
done;
unset HTTPS_PROXY
