#!/usr/bin/env bash
set -eux

## Signal to toci_gate_test.sh we've started
touch /tmp/toci.started

export CURRENT_DIR=$(dirname ${BASH_SOURCE[0]:-$0})
export TRIPLEO_CI_DIR=$CURRENT_DIR/../

export IP_DEVICE=${IP_DEVICE:-"eth0"}

source $TRIPLEO_CI_DIR/tripleo-ci/scripts/common_vars.bash
source $TRIPLEO_CI_DIR/tripleo-ci/scripts/common_functions.sh
source $TRIPLEO_CI_DIR/tripleo-ci/scripts/metrics.bash
start_metric "tripleo.ci.total.seconds"

mkdir -p $WORKSPACE/logs


MY_IP=$(ip addr show dev $IP_DEVICE | awk '/inet / {gsub("/.*", "") ; print $2}')

export no_proxy=192.0.2.1,$MY_IP,$MIRRORSERVER

# Setup delorean
$TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --delorean-setup

dummy_ci_repo

# Install all of the repositories we need
$TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --repo-setup

# Install wget and moreutils for timestamping postci.log with ts
sudo yum -y install wget moreutils python-simplejson dstat yum-plugin-priorities

trap "[ \$? != 0 ] && echo ERROR DURING PREVIOUS COMMAND ^^^ && echo 'See postci.txt in the logs directory for debugging details'; postci 2>&1 | ts '%Y-%m-%d %H:%M:%S.000 |' > $WORKSPACE/logs/postci.log 2>&1" EXIT

delorean_build_and_serve

# Since we've moved a few commands from this spot before the wget, we need to
# sleep a few seconds in order for the SimpleHTTPServer to get setup.
sleep 3

layer_ci_repo

create_dib_vars_for_puppet

export http_proxy=""
source $TRIPLEO_ROOT/tripleo-ci/deploy.env

echo_vars_to_deploy_env

source /opt/stack/new/tripleo-ci/deploy.env

# Add a simple system utilisation logger process
sudo dstat -tcmndrylpg --output /var/log/dstat-csv.log >/dev/null &
# Install our test cert so SSL tests work
sudo cp $TRIPLEO_ROOT/tripleo-ci/test-environments/overcloud-cacert.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

cd

# Don't get a file from cache if CACHEUPLOAD=1 (periodic job)
# If this 404's it wont error just continue without a file created
wget --progress=dot:mega http://$MIRRORSERVER/builds/current-tripleo/ipa_images.tar || true
if [ -f ipa_images.tar ] ; then
    tar -xf ipa_images.tar
    update_image $PWD/ironic-python-agent.initramfs
fi

# Same thing for the overcloud image
wget --progress=dot:mega http://$MIRRORSERVER/builds/current-tripleo/overcloud-full.tar || true
if [ -f overcloud-full.tar ] ; then
    tar -xf overcloud-full.tar
    update_image $PWD/overcloud-full.qcow2
fi

cp -f $TE_DATAFILE ~/instackenv.json

$TRIPLEO_ROOT/tripleo-ci/scripts/deploy.sh

exit 0
echo 'Run completed.'
