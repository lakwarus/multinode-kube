#!/bin/bash

if [[ "$OSTYPE" == "linux-gnu" ]]; then
    echo "Setting up prerequisite for Linux..."
    aptitude install python-pip
elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "-----------------------------------------------------------"
    echo "Setting up prerequisite for Mac..."
    echo "-----------------------------------------------------------"
    sudo easy_install pip > /dev/null 2>&1
    sudo pip install rackspace-novaclient > /dev/null 2>&1
    source openrc.sh
    echo "-----------------------------------------------------------"
    echo "Setting up K8S Master..."
    echo "-----------------------------------------------------------"
    nova boot \
    --image CoreOS \
    --key-name kube \
    --flavor 8ca857cd-a3c8-4fac-afaf-05359eb88cd9 \
    --security-group kubernetes \
    --user-data files/master.yaml \
    $OS_USERNAME-kube-master
    sleep 10
    tmp=`nova list |grep $OS_USERNAME-kube-master | awk '{ print $12 }'`
    IP=$(echo $tmp | sed 's/dev_private_network=//g')
    cp -f files/node.yaml ./node.yaml
    sed -i -e "s/<master-private-ip>/$IP/g" ./node.yaml
    echo "Required number of k8s nodes:" 
    read nodes
    re='^[0-9]+$'
    while [ 1 ]
    do
    if ! [[ $nodes =~ $re ]] ; then
        echo "error: Not a number"
	echo "Required number of k8s nodes:" 
	read nodes
    else
        break
    fi
    done
    node=0
    while [  $node -lt $nodes ]; do
	let node=node+1 
        echo "-----------------------------------------------------------"
        echo "Setting up K8S Node$node..."
        echo "-----------------------------------------------------------"
        nova boot \
        --image CoreOS \
        --key-name kube \
        --flavor 3 \
        --security-group kubernetes \
        --user-data node.yaml \
        $OS_USERNAME-node$node
    done
    echo -n "Waiting for API  "
    while [ 1 ]
    do
        sleep 1
	if curl -m1 http://$IP:8080/api/v1/namespaces/default/pods >/dev/null 2>&1
	then
	    break
        fi
    done
    echo -e "OK"
    kubectl -s http://$IP:8080 get nodes
else
    # Unknown.
    echo "Setting up prerequisite..."
fi
