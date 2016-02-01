#!/bin/bash

echo "-----------------------------------------------------------"
echo "Setting up prerequisites..."
echo "-----------------------------------------------------------"

if [[ "$OSTYPE" == "linux-gnu" ]]; then
    command -v pip >/dev/null 2>&1 && {
        command -v nova >/dev/null 2>&1 && {
            echo "Prerequisites already installed..."
        } || {
            # nova absent
            echo "Installing nova-client..."
            pip install python-novaclient
        }
    } || {
        # pip absent
        echo "Installing Python PIP and nova-client..."
        python -mplatform | grep Ubuntu && sudo apt-get install -y git python python-pip || echo "Unrecognized OS. Only supports Ubuntu at the moment."; exit 100;
        pip install python-novaclient
    }

elif [[ "$OSTYPE" == "darwin"* ]]; then
    sudo easy_install pip > /dev/null 2>&1
    sudo pip install rackspace-novaclient > /dev/null 2>&1
else
    # Unknown.
    echo "Unsupported OS"
fi

source openrc.sh

if [ ! -f kube.pem ]; then
    echo "Creating 'kube' key-pair..."
    nova keypair-add kube > kube.pem
    chmod 600 kube.pem
fi

echo "-----------------------------------------------------------"
echo "Setting up K8S Master..."
echo "-----------------------------------------------------------"
nova boot \
--image CoreOS \
--key-name kube \
--flavor 8ca857cd-a3c8-4fac-afaf-05359eb88cd9 \
--security-group kubernetes \
--user-data files/master.yaml \
$OS_USERNAME-kube-master > /dev/null 2>&1
sleep 20
tmp=`nova list |grep $OS_USERNAME-kube-master | awk '{ print $12 }' 2> /dev/null`
IP=$(echo $tmp | sed 's/dev_private_network=//g')
echo "K8S Master: ${IP}"
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
    echo "Setting up K8S Node $node..."
    echo "-----------------------------------------------------------"
    nova boot \
    --image CoreOS \
    --key-name kube \
    --flavor 3 \
    --security-group kubernetes \
    --user-data node.yaml \
    $OS_USERNAME-node$node > /dev/null 2>&1
done
echo -n "Waiting for API  "
while [ 1 ]
do
    sleep 1
if curl -m1 http://$IP:8080/api/v1/namespaces/default/pods > /dev/null 2>&1
then
    break
    fi
done
# sleep 30
echo -e "OK"
echo "Kubernetes Master IP : $IP"
echo "kubectl -s http://$IP:8080 get nodes"
kubectl -s http://$IP:8080 get nodes
echo "If no Kubernetes Nodes are listed above... wait for a few seconds and re-try.."
