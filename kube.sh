#!/bin/bash

function cleanAndExit () {
    if [ -f node.yaml ]; then
        rm -rf node.yaml
    fi

    if [ -z "$1" ]; then
        exit 0
    fi

    exit $1
}

function echoDim () {
    if [ -z "$2" ]; then
        echo $'\e[2m'"${1}"$'\e[0m'
    else
        echo -n $'\e[2m'"${1}"$'\e[0m'
    fi
}

function echoError () {
    echo $'\e[1;31m'"${1}"$'\e[0m'
}

function echoSuccess () {
    echo $'\e[1;32m'"${1}"$'\e[0m'
}

function echoDot () {
    echoDim "." "append"
}

function echoBold () {
    echo $'\e[1m'"${1}"$'\e[0m'
}

echoDim "Setting up prerequisites..."

if [[ "$OSTYPE" == "linux-gnu" ]]; then
    command -v pip >/dev/null 2>&1 && {
        command -v nova >/dev/null 2>&1 && {
            echoDim "Prerequisites already installed."
        } || {
            # nova absent
            echoDim "Installing nova-client..."
            pip install python-novaclient >/dev/null 2>&1
        }
    } || {
        # pip absent
        echoDim "Installing Python PIP and nova-client..."
        python -mplatform | grep Ubuntu && sudo apt-get install -y git python python-pip  >/dev/null 2>&1 || {
            echoError "Unrecognized OS. Only supports Ubuntu at the moment."
            cleanAndExit 100
        }
        pip install python-novaclient >/dev/null 2>&1
    }

elif [[ "$OSTYPE" == "darwin"* ]]; then
    command -v pip >/dev/null 2>&1 && {
        command -v nova >/dev/null 2>&1 && {
            echoDim "Prerequisites already installed."
    	} || {
	    # nova absent
    	    sudo pip install python-novaclient >/dev/null 2>&1
	}
     } || {
     	   # pip absent
	   echoDim "Installing Python PIP and nova-client..."
	   sudo easy_install pip > /dev/null 2>&1
	   sudo pip install python-novaclient >/dev/null 2>&1
   	}	
else
    # Unknown.
    echoError "Unsupported OS!"
    cleanAndExit 100
fi

source openrc.sh
echo

if [ ! -f kube.pem ]; then
    echoDim "Creating 'kube' key-pair..."
    nova keypair-add kube > kube.pem
    chmod 600 kube.pem
fi

echoDim "Setting up K8S Master." "append"
# Check if K8S Master already exists, TODO: ask to delete if true, get IP and continue if delete=false
master_exists=`nova list | grep $OS_USERNAME-kube-master 2> /dev/null`
if [ -n "$master_exists" ]; then
    echoError "FAILED"
    echoError "An instance already exists with name '${OS_USERNAME}-kube-master'."
    cleanAndExit 100
fi

nova boot \
--image CoreOS \
--key-name kube \
--flavor 8ca857cd-a3c8-4fac-afaf-05359eb88cd9 \
--security-group kubernetes \
--user-data files/master.yaml \
$OS_USERNAME-kube-master  >/dev/null 2>&1 || {
    echoError "FAILED"
    cleanAndExit 100
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
        echoSuccess "OK"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 300 ]; then
        echoError "TIMEOUT [5m]"
        cleanAndExit 100
    fi

    echoDot
done
echoDim "K8S Master:" "append"
echoBold "${IP}"

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
failed=0
while [  $node -lt $nodes ]; do
    let node=node+1
    echoDim "Setting up K8S Node $node..." "append"
    # Check if each node exists, TODO: ask to delete if true
    node_exists=`nova list | grep $OS_USERNAME-node$node 2> /dev/null`
    if [ -n "$node_exists" ]; then
        echoError "FAILED [${node}]"
        echoError "An instance already exists with name '${OS_USERNAME}-node${node}'."
        let "failed++"

        if [ $failed -eq $node ]; then
            echoError "Couldn't create any Nodes. Check output for errors."
            cleanAndExit 100
        else
            break
        fi
    fi

    nova boot \
    --image CoreOS \
    --key-name kube \
    --flavor 3 \
    --security-group kubernetes \
    --user-data node.yaml \
    $OS_USERNAME-node$node > /dev/null 2>&1 && echoSuccess "OK" || {
        echoError "FAILED [${node}]"
    }
done

echoDim "Waiting for API Server." "append"
before_time=`date +%s`
while [ 1 ]
do
    sleep 1
    if curl -m1 http://$IP:8080/api/v1/namespaces/default/pods > /dev/null 2>&1
    then
        echoSuccess "OK"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 300 ]; then
        echoError "TIMEOUT [5m]"
        cleanAndExit 100
    fi

    echoDot
done

echoDim "Waiting for the Node/s to register." "append"
before_time=`date +%s`
while [ 1 ]; do
    sleep 5

    node_list=`kubectl -s http://$IP:8080 get nodes 2> /dev/null`
    arr=()
    while read -r line; do
       arr+=("$line")
    done <<< "$node_list"

    if [ ${#arr[@]} -eq `expr $nodes + 1` ]; then
        echoSuccess "OK"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 600 ]; then
        echoError "TIMEOUT [10m]"
        cleanAndExit 100
    fi

    echoDot
done

echo
echo "K8S Nodes (Minions)"
echo "==================="
kubectl -s http://$IP:8080 get nodes
echo

# add SkyDNS
echoDim "Adding SkyDNS ..."
kubectl -s http://$IP:8080 create -f files/kube-system.yaml  >/dev/null 2>&1 && \
kubectl -s http://$IP:8080 create -f files/dns-service.yaml --namespace=kube-system  >/dev/null 2>&1 && \
kubectl -s http://$IP:8080 create -f files/dns-controller.yaml --namespace=kube-system  >/dev/null 2>&1 && {
    echoDim "SkyDNS Added."
    echoDim "Waiting for the SkyDNS to start." "append"
    before_time=`date +%s`
    while [ 1 ]; do
        sleep 2

        ui_status=`curl --write-out %{http_code} --silent --output /dev/null http://${IP}:8080/api/v1/proxy/namespaces/kube-system/services/skydns`
        if [ "${ui_status}" -eq 200 ]; then
            echoSuccess "OK"
            echoDim "SkyDNS Started:" "append"
            break
        fi

        now_time=`date +%s`
        spent_time=`expr $now_time - $before_time`
        if [ $spent_time -gt 300 ]; then
            echoError "TIMEOUT [5m]"
            cleanAndExit 100
        fi

        echoDot
    done
} || {
    echoError "Failed to add SkyDNS"
}


# add kube-ui rc and svc
echoDim "Adding K8S UI..."
kubectl -s http://$IP:8080 create -f files/kube-ui/kube-ui-rc.yaml --namespace=kube-system  >/dev/null 2>&1 && \
kubectl -s http://$IP:8080 create -f files/kube-ui/kube-ui-svc.yaml --namespace=kube-system  >/dev/null 2>&1 && {
    echoDim "K8S UI Added."
    echoDim "Waiting for the K8S UI to start." "append"
    before_time=`date +%s`
    while [ 1 ]; do
        sleep 2

        ui_status=`curl --write-out %{http_code} --silent --output /dev/null http://${IP}:8080/api/v1/proxy/namespaces/kube-system/services/kube-ui/#/dashboard/`
        if [ "${ui_status}" -eq 200 ]; then
            echoSuccess "OK"
            echoDim "K8S UI Started:" "append"
            echoBold "http://${IP}:8080/ui"
            break
        fi

        now_time=`date +%s`
        spent_time=`expr $now_time - $before_time`
        if [ $spent_time -gt 300 ]; then
            echoError "TIMEOUT [5m]"
            cleanAndExit 100
        fi

        echoDot
    done
} || {
    echoError "Failed to add K8S UI"
}


echoSuccess "K8S Cluster setup complete."
cleanAndExit

# TODO:
# Check if key-pair exists, ask to add this machine's public key, if not ask to delete, crete if key pair doesn't exist
