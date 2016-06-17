#!/usr/bin/env bash
set -eux

# Need to make sure lsb_release is installed
sudo yum -y install redhat-lsb-core

LSBRELEASE=`lsb_release -i -s`

if ping -c 1 192.168.100.1 ; then
    source scripts/rh2.env
fi

# Clean any cached yum metadata, it maybe stale
sudo yum clean all

# NOTE(pabelanger): Current hack to make centos-7 dib work.
if [ $LSBRELEASE == 'CentOS' ]; then
    # TODO(pabelanger): Why is python-requests installed from pip?
    sudo rm -rf /usr/lib/python2.7/site-packages/requests
fi

# Remove metrics from a previous run
rm -f /tmp/metric-start-times /tmp/metrics-data

# In order to save space remove some of the largest git repos
# mirrored on the jenkins slave, together these make up 2G(of 4.6G)
sudo rm -rf /opt/git/openstack/openstack-manuals /opt/git/openstack/daisycloud-core /opt/git/openstack/fuel-* /opt/git/openstack-infra/activity-board

# cd to toci directory so relative paths work (below and in toci_devtest.sh)
cd $(dirname $0)

# Mirrors
# This Fedora Mirror is in the same data center as our CI rack
export FEDORA_MIRROR=http://dl.fedoraproject.org/pub/fedora/linux
# We don't seem to have a CentOS mirror in the data center, so we need to pick
# one that has reasonable connectivity to our rack.  Provide a few options in
# case one of them goes down.
for mirror in http://mirror.hmc.edu/centos/ http://mirrors.usc.edu/pub/linux/distributions/centos/ http://mirror.centos.org/centos/; do
    if curl -L -f -m 10 $mirror > /dev/null 2>&1; then
        export CENTOS_MIRROR=$mirror
        break
    fi
done
# This EPEL Mirror is in the same data center as our CI rack
export EPEL_MIRROR=http://dl.fedoraproject.org/pub/epel

export http_proxy=http://$PROXYIP:3128/
export GEARDSERVER=$TEBROKERIP
export MIRRORSERVER=$MIRRORIP

export CACHEUPLOAD=0
export INTROSPECT=0
export NODECOUNT=2
export PACEMAKER=0
# NOTE(bnemec): At this time, the undercloud install + image build is taking from
# 1 hour to 1 hour and 15 minutes on the jobs I checked.  The devstack gate timeout
# is 170 minutes, so subtracting 90 should leave us an hour and 20 minutes for
# the deploy.  Hopefully that's enough, while still leaving some cushion to come
# in under the gate timeout so we can collect logs.
OVERCLOUD_DEPLOY_TIMEOUT=$((DEVSTACK_GATE_TIMEOUT-90))
export OVERCLOUD_DEPLOY_ARGS=${OVERCLOUD_DEPLOY_ARGS:-""}
export OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS --libvirt-type=qemu -t $OVERCLOUD_DEPLOY_TIMEOUT"
export OVERCLOUD_UPDATE_ARGS=
export UNDERCLOUD_SSL=0
export TRIPLEO_SH_ARGS=
export NETISO_V4=0
export NETISO_V6=0
export RUN_PING_TEST=1
export RUN_TEMPEST_TESTS=0
export MULTINODE=0
export CONTROLLER_HOSTS=
export COMPUTE_HOSTS=
export SUBNODES_SSH_KEY=

# Set the fedora mirror, this is more reliable then relying on the repolist returned by metalink
# NOTE(pabelanger): Once we bring AFS mirrors online, we no longer need to do this.
if [ $LSBRELEASE == 'Fedora' ]; then
    sudo sed -i -e "s|^#baseurl=http://download.fedoraproject.org/pub/fedora/linux|baseurl=$FEDORA_MIRROR|;/^metalink/d" /etc/yum.repos.d/fedora*.repo
else
    sudo sed -i -e "s|^#baseurl=http://mirror.centos.org/centos/|baseurl=$CENTOS_MIRROR|;/^mirrorlist/d" /etc/yum.repos.d/CentOS-Base.repo
fi

# start dstat early
# TODO add it to the gate image building
sudo yum install -y dstat nmap-ncat #nc is for metrics
mkdir -p "$WORKSPACE/logs"
dstat -tcmndrylpg --output "$WORKSPACE/logs/dstat-csv.log" >/dev/null &
disown

# Switch defaults based on the job name
for JOB_TYPE_PART in $(sed 's/-/ /g' <<< "${TOCI_JOBTYPE:-}") ; do
    case $JOB_TYPE_PART in
        overcloud)
            ;;
        upgrades)
            NODECOUNT=3
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml --ceph-storage-scale 1 -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation-v6.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/net-multiple-nics-v6.yaml -e /opt/stack/new/tripleo-ci/test-environments/net-iso.yaml"
            OVERCLOUD_UPDATE_ARGS="-e /usr/share/openstack-tripleo-heat-templates/overcloud-resource-registry-puppet.yaml $OVERCLOUD_DEPLOY_ARGS"
            NETISO_V6=1
            PACEMAKER=1
            ;;
        ha)
            NODECOUNT=4
            # In ci our overcloud nodes don't have access to an external netwrok
            # --ntp-server is here to make the deploy command happy, the ci env
            # is on virt so the clocks should be in sync without it.
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS --control-scale 3 --ntp-server 0.centos.pool.ntp.org -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/network-isolation.yaml -e /usr/share/openstack-tripleo-heat-templates/environments/net-multiple-nics.yaml -e /opt/stack/new/tripleo-ci/test-environments/net-iso.yaml"
            NETISO_V4=1
            PACEMAKER=1
            ;;
        nonha)
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e /opt/stack/new/tripleo-ci/test-environments/enable-tls.yaml -e /opt/stack/new/tripleo-ci/test-environments/inject-trust-anchor.yaml --ceph-storage-scale 1 -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-ceph-devel.yaml"
            INTROSPECT=1
            NODECOUNT=3
            UNDERCLOUD_SSL=1
            ;;
        containers)
            # TODO : remove this when the containers job is passing again
            exit 1
            TRIPLEO_SH_ARGS="--use-containers"
            ;;
        multinode)
            NODECOUNT=2
            MULTINODE=1
            PACEMAKER=1
            CONTROLLER_HOSTS=$(sed -n 1,1p /etc/nodepool/sub_nodes)
            COMPUTE_HOSTS=$(sed -n 2,2p /etc/nodepool/sub_nodes)
            SUBNODES_SSH_KEY=/etc/nodepool/id_rsa
            OVERCLOUD_DEPLOY_ARGS="$OVERCLOUD_DEPLOY_ARGS -e /usr/share/openstack-tripleo-heat-templates/environments/puppet-pacemaker.yaml -e /usr/share/openstack-tripleo-heat-templates/deployed-server/deployed-server-environment.yaml"
            ;;
        periodic)
            export DELOREAN_REPO_URL=http://trunk.rdoproject.org/centos7/consistent
            CACHEUPLOAD=1
            ;;
        liberty|mitaka)
            # This is handled in tripleo.sh (it always uses centos7-$STABLE_RELEASE/current)
            # where $STABLE_RELEASE is derived in toci_instack.sh
            unset DELOREAN_REPO_URL
            ;;
        tempest)
            export RUN_TEMPEST_TESTS=1
            export RUN_PING_TEST=0
            ;;
    esac
done

# print the final values of control variables to console
env | grep -E "(TOCI_JOBTYPE)="

# Allow the instack node to have traffic forwards through here
sudo iptables -A FORWARD -i eth0 -o eth1 -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
sudo iptables -A FORWARD -i eth1 -o eth0 -j ACCEPT
echo 1 | sudo dd of=/proc/sys/net/ipv4/ip_forward

if [ "$MULTINODE" = "0" ]; then
    TIMEOUT_SECS=$((DEVSTACK_GATE_TIMEOUT*60))
    # ./testenv-client kill everything in its own process group it it hits a timeout
    # run it in a separate group to avoid getting killed along with it
    set -m

    source /opt/stack/new/tripleo-ci/scripts/metrics.bash
    start_metric "tripleo.testenv.wait.seconds"
    if [ -z ${TE_DATAFILE:-} ] ; then
        # NOTE(pabelanger): We need gear for testenv, but this really should be
        # handled by tox.
        if [ $LSBRELEASE == 'CentOS' ]; then
            sudo yum -y install epel-release
            sudo yum install -y python-gear qemu-img
        fi
        # Kill the whole job if it doesn't get a testenv in 20 minutes as it likely will timout in zuul
        ( sleep 1200 ; [ ! -e /tmp/toci.started ] && sudo kill -9 $$ ) &
        ./testenv-client -b $GEARDSERVER:4730 -t $TIMEOUT_SECS --envsize $NODECOUNT --ucinstance $(cat /var/lib/cloud/data/instance-id) -- ./toci_instack_ovb.sh
    else
        LEAVE_RUNNING=1 ./toci_instack.sh
    fi
else
    ./toci_instack_multinode.sh
fi
