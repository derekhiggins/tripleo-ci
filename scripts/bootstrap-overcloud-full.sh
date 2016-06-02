#!/bin/bash

set -eux

# instack-undercloud will pull in all the needed deps
sudo yum -y install instack-undercloud

export ELEMENTS_PATH="/usr/share/diskimage-builder/elements:/usr/share/instack-undercloud:/usr/share/tripleo-image-elements:/usr/share/tripleo-puppet-elements:/usr/share/openstack-heat-templates/software-config/elements"

export DIB_INSTALLTYPE_puppet_modules=source

ELEMENTS=$(\
tripleo-build-images \
  --image-json-output \
  --image-config-file /usr/share/tripleo-common/image-yaml/overcloud-images-centos7.yaml \
  --image-config-file /usr/share/tripleo-common/image-yaml/overcloud-images.yaml \
  | jq '. | map(select(.imagename == "overcloud")) | .[0].elements | map(.+" ") | add' \
  | sed 's/"//g')

sudo -E instack \
  -e centos7 \
     enable-packages-install \
     install-types \
     $ELEMENTS \
  -k extra-data \
     pre-install \
     install \
     post-install \
  -b 05-fstab-rootfs-label \
     00-fix-requiretty \
     90-rebuild-ramdisk \
  -d

PACKAGES=$(\
tripleo-build-images \
  --image-json-output \
  --image-config-file /usr/share/tripleo-common/image-yaml/overcloud-images-centos7.yaml \
  --image-config-file /usr/share/tripleo-common/image-yaml/overcloud-images.yaml \
  | jq '. | map(select(.imagename == "overcloud")) | .[0].packages | .[] | tostring')

# Install additional packages expected by the image
sudo yum -y install $PACKAGES

sudo sed -i 's/SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
sudo setenforce 0
