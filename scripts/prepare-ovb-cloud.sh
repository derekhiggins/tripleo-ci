#!/bin/bash
set -ex

export PATH=$PATH:scripts

# Script to deploy the base infrastructure required to create the ovb-common and ovb-testenv stacks
# Parts of this script could have been a heat stack but not all

# We can't use heat to create the flavors as they can't be given a name with the heat resource
nova flavor-show bmc || nova flavor-create bmc auto 512 20 1
nova flavor-show baremetal || nova flavor-create baremetal auto 5120 41 1

glance image-show 'CentOS-7-x86_64-GenericCloud' || \
glance image-create --progress --name 'CentOS-7-x86_64-GenericCloud' --is-public true --disk-format qcow2 --container-format bare \
    --copy-from http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud.qcow2

glance image-show 'ipxe-boot' || \
glance image-create --name ipxe-boot --is-public true --disk-format qcow2 --property os_shutdown_timeout=5 --container-format bare \
    --copy-from https://raw.githubusercontent.com/cybertron/openstack-virtual-baremetal/master/ipxe/ipxe-boot.qcow2

# Create a pool of floating IP's
neutron net-show public || neutron net-create public --router:external=True
neutron subnet-show public_subnet || neutron subnet-create --name public_subnet --enable_dhcp=False --allocation_pool start=8.43.87.224,end=8.43.87.253 --gateway 8.43.87.254 public 8.43.86.0/23

# Create a shared private network 
neutron net-show private || neutron net-create --shared private
neutron subnet-show private_subnet || neutron subnet-create --name private_subnet --gateway 192.168.100.1 --allocation-pool start=192.168.100.2,end=192.168.103.254 --dns-nameserver 8.8.8.8 private 192.168.100.0/22


# Give outside access to the private network
if ! neutron router-show private_router ; then
    neutron router-create private_router
    neutron router-gateway-set private_router public
    neutron router-interface-add private_router private_subnet
fi

# Keys to used in infrastructure
nova keypair-show tripleo-cd-admins || nova keypair-add --pub-key scripts/tripleo-cd-admins tripleo-cd-admins

# Create a new project/user whose creds will be injected into the te-broker for creating heat stacks
./scripts/assert-user -n toci -t toci -u toci -e toci@noreply.org || true
#openstack role add --project toci --user toci heat_stack_owner || true

PASSWORD=$(grep toci os-asserted-users | awk '{print $2}')
touch tocirc
chmod 600 tocirc
echo -e "export OS_USERNAME=toci\nexport OS_TENANT_NAME=toci" > tocirc
echo "export OS_AUTH_URL=$OS_AUTH_URL" >> tocirc
echo "export OS_PASSWORD=$PASSWORD" >> tocirc

source tocirc

nova keypair-show tripleo-cd-admins || nova keypair-add --pub-key scripts/tripleo-cd-admins tripleo-cd-admins
# And finally some servers we need
nova show te-broker || nova boot --flavor m1.medium --image "CentOS-7-x86_64-GenericCloud" --key-name tripleo-cd-admins --nic net-name=private,v4-fixed-ip=192.168.103.254 --user-data scripts/deploy-server.sh --file "/etc/tocirc=tocirc" te-broker
#nova show mirror-server || nova boot --flavor m1.medium --image "CentOS-7-x86_64-GenericCloud" --key-name tripleo-cd-admins --nic net-name=private,v4-fixed-ip=192.168.103.253 --user-data scripts/deploy-server.sh mirror-server
