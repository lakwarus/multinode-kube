#!/bin/bash

echo "Setting up prerequisites..."

if [[ "$OSTYPE" == "linux-gnu" ]]; then
    command -v pip >/dev/null 2>&1 && {
        command -v nova >/dev/null 2>&1 && {
            echo "Prerequisites already installed."
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
    exit 100
fi

source openrc.sh
echo

if [ ! -f kube.pem ]; then
    echo "Creating 'kube' key-pair..."
    nova keypair-add kube > kube.pem
    chmod 600 kube.pem
fi

echo -n "Setting up K8S Master."
nova boot \
--image CoreOS \
--key-name kube \
--flavor 8ca857cd-a3c8-4fac-afaf-05359eb88cd9 \
--security-group kubernetes \
--user-data files/master.yaml \
$OS_USERNAME-kube-master || {
    echo "Failed."
    exit 100
}

# echo -n "Waiting for the instance to be provisioned."
before_time=`date +%s`
while [ 1 ]; do
    sleep 3
    tmp=`nova list |grep $OS_USERNAME-kube-master | awk '{ print $12 }' 2> /dev/null`
    IP=$(echo $tmp | sed 's/dev_private_network=//g')
    IP=${IP//[[:blank:]]/}
    # echo "${IP//|}"
    if [ ${#IP} -gt 4 ]; then
        echo "OK"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 300 ]; then
        echo "TIMEOUT [5m]"
        break
    fi

    echo -n "."
done
echo "K8S Master: ${IP}"

cp -f files/node.yaml ./node.yaml
sed -i -e "s/<master-private-ip>/$IP/g" ./node.yaml

echo -n "Number of K8S Nodes (Minions) to create> "
read nodes
re='^[0-9]+$'

while [ 1 ]; do
    if ! [[ $nodes =~ $re ]] ; then
        echo "error: Not a number"
    echo -n "Number of K8S Nodes (Minions) to create> "
    read nodes
    else
        break
    fi
done

node=0
while [  $node -lt $nodes ]; do
let node=node+1
    echo "Setting up K8S Node $node..."
    nova boot \
    --image CoreOS \
    --key-name kube \
    --flavor 3 \
    --security-group kubernetes \
    --user-data node.yaml \
    $OS_USERNAME-node$node > /dev/null 2>&1 || {
        echo "Failed [${node}]"
    }
done

echo -n "Waiting for API Server."
before_time=`date +%s
while [ 1 ]
do
    sleep 1
    if curl -m1 http://$IP:8080/api/v1/namespaces/default/pods > /dev/null 2>&1
    then
        echo "OK"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 300 ]; then
        echo "TIMEOUT [5m] "
        break
    fi

    echo -n "."
done

echo -n "Waiting for the Node/s to register."
before_time=`date +%s
while [ 1 ]; do
    sleep 5

    node_list=`kubectl -s http://$IP:8080 get nodes 2> /dev/null`
    arr=()
    while read -r line; do
       arr+=("$line")
    done <<< "$node_list"

    if [ ${#arr[@]} -eq `expr $nodes + 1` ]; then
        echo "OK"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 600 ]; then
        echo "TIMEOUT [10m] "
        break
    fi

    echo -n "."
done

kubectl -s http://$IP:8080 get nodes

# add kube-ui rc and svc
echo "Adding Kubernetes UI..."
kubectl -s http://$IP:8080 create -f files/kube-system.yaml && \
kubectl -s http://$IP:8080 create -f files/kube-ui/kube-ui-rc.yaml --namespace=kube-system && \
kubectl -s http://$IP:8080 create -f files/kube-ui/kube-ui-svc.yaml --namespace=kube-system || echo "Failed to add Kubernetes UI"

# echo "If no Kubernetes Nodes are listed above... wait for a few seconds and re-try.."
rm -rf node.yaml
echo "Kubernetes Cluster setup complete."
