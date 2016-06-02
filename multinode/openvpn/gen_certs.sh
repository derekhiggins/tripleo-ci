#!/bin/bash

set -eux

NODECOUNT=${NODECOUNT:-2}

function gen_ca {
    cn=$1
    basename=${2:-$1}
    openssl req -nodes -x509 -new -days 3650 -config <(sed "s/CN=/CN=$cn/" req.cnf) -keyout $basename.key -out $basename.crt
}

function gen_cert {
    cn=$1
    basename=${2:-$1}
    openssl req -nodes -new -days 3650 -config <(sed "s/CN=/CN=$cn/" req.cnf) -keyout $basename.key -out $basename.csr
}

function sign_cert {
    cn=$1
    openssl ca -config ca.cnf -batch -out $cn.crt -keyfile ca.key -cert ca.crt -in $cn.csr
}

echo 01 > serial
rm -f index.txt && touch index.txt
rm -f index.txt.attr && touch index.txt.attr
gen_ca tripleo-ci-ca ca

let cert_count=$NODECOUNT+1
for i in $(seq $cert_count); do
    gen_cert node$i
    sign_cert node$i
done

if [ ! -e dh1024.pem ]; then
    openssl dhparam -out dh1024.pem 1024
fi
