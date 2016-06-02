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
# Need to reinstall requests since it's rm'd in toci_gate_test.sh
sudo yum -y reinstall python-requests
# Open up port for openvpn
sudo iptables -I INPUT -p udp --dport 1194 -j ACCEPT
# Open up port for delorean yum repo server
sudo iptables -I INPUT -p tcp --dport 8766 -j ACCEPT

trap "[ \$? != 0 ] && echo ERROR DURING PREVIOUS COMMAND ^^^ && echo 'See postci.txt in the logs directory for debugging details'; postci 2>&1 | ts '%Y-%m-%d %H:%M:%S.000 |' > $WORKSPACE/logs/postci.log 2>&1" EXIT

delorean_build_and_serve

# Since we've moved a few commands from this spot before the wget, we need to
# sleep a few seconds in order for the SimpleHTTPServer to get setup.
sleep 3

layer_ci_repo

for ip in $(cat /etc/nodepool/sub_nodes); do
    # Layer the ci repository on top of it
    ssh -t -i /etc/nodepool/id_rsa $ip \
        sudo yum -y install wget
    ssh -t -i /etc/nodepool/id_rsa $ip \
        sudo wget http://$MY_IP:8766/current/delorean-ci.repo -O /etc/yum.repos.d/delorean-ci.repo
    # rewrite the baseurl in delorean-ci.repo as its currently pointing a http://trunk.rdoproject.org/..
    ssh -t -i /etc/nodepool/id_rsa $ip \
        sudo sed -i -e "s%baseurl=.*%baseurl=http://$MY_IP:8766/current/%" /etc/yum.repos.d/delorean-ci.repo
    ssh -t -i /etc/nodepool/id_rsa $ip \
        sudo sed -i -e 's%priority=.*%priority=1%' /etc/yum.repos.d/delorean-ci.repo
done

create_dib_vars_for_puppet

export http_proxy=""
source $TRIPLEO_ROOT/tripleo-ci/deploy.env

echo_vars_to_deploy_env

$TRIPLEO_ROOT/tripleo-ci/scripts/tripleo.sh --multinode

source /opt/stack/new/tripleo-ci/deploy.env

# Add a simple system utilisation logger process
sudo dstat -tcmndrylpg --output /var/log/dstat-csv.log >/dev/null &
# Install our test cert so SSL tests work
sudo cp $TRIPLEO_ROOT/tripleo-ci/test-environments/overcloud-cacert.pem /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust extract

$TRIPLEO_ROOT/tripleo-ci/scripts/deploy.sh

exit 0
echo 'Run completed.'
