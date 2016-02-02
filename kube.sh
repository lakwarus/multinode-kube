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

echo -e "\e[2mSetting up prerequisites...\e[0m"

if [[ "$OSTYPE" == "linux-gnu" ]]; then
    command -v pip >/dev/null 2>&1 && {
        command -v nova >/dev/null 2>&1 && {
            echo -e "\e[2mPrerequisites already installed.\e[0m"
        } || {
            # nova absent
            echo -e "\e[2mInstalling nova-client...\e[0m"
            pip install python-novaclient >/dev/null 2>&1
        }
    } || {
        # pip absent
        echo -e "\e[2mInstalling Python PIP and nova-client...\e[0m"
        python -mplatform | grep Ubuntu && sudo apt-get install -y git python python-pip  >/dev/null 2>&1 || {
            echo -e "\e[1;31mUnrecognized OS. Only supports Ubuntu at the moment.\e[0m"
            cleanAndExit 100
        }
        pip install python-novaclient >/dev/null 2>&1
    }

elif [[ "$OSTYPE" == "darwin"* ]]; then
    sudo easy_install pip > /dev/null 2>&1
    sudo pip install rackspace-novaclient > /dev/null 2>&1
else
    # Unknown.
    echo -e "\e[1;31mUnsupported OS!\e[0m"
    cleanAndExit 100
fi

source openrc.sh
echo

if [ ! -f kube.pem ]; then
    echo -e "\e[2mCreating 'kube' key-pair...\e[0m"
    nova keypair-add kube > kube.pem
    chmod 600 kube.pem
fi

echo -ne "\e[2mSetting up K8S Master.\e[0m"
# Check if K8S Master already exists, TODO: ask to delete if true, get IP and continue if delete=false
master_exists=`nova list | grep $OS_USERNAME-kube-master 2> /dev/null`
if [ -n "$master_exists" ]; then
    echo -e "\e[1;31mFAILED\e[0m: An instance already exists with name '${OS_USERNAME}-kube-master'."
    cleanAndExit 100
fi

nova boot \
--image CoreOS \
--key-name kube \
--flavor 8ca857cd-a3c8-4fac-afaf-05359eb88cd9 \
--security-group kubernetes \
--user-data files/master.yaml \
$OS_USERNAME-kube-master  >/dev/null 2>&1 || {
    echo -e "\e[1;31mFAILED\e[0m"
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
        echo -e "\e[1;32mOK\e[0m"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 300 ]; then
        echo -e "\e[1;31mTIMEOUT [5m]\e[0m"
        cleanAndExit 100
    fi

    echo -ne "\e[2m.\e[0m"
done
echo -e "\e[2mK8S Master:\e[0m \e[1m${IP}\e[0m"

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
    echo -en "\e[2mSetting up K8S Node $node...\e[0m"
    # Check if each node exists, TODO: ask to delete if true
    node_exists=`nova list | grep $OS_USERNAME-node$node 2> /dev/null`
    if [ -n "$node_exists" ]; then
        echo -e "\e[1;31mFAILED [${node}]\e[0m: An instance already exists with name '${OS_USERNAME}-node${node}'."
        let "failed++"

        if [ $failed -eq $node ]; then
            echo "Couldn't create any Nodes. Check output for errors."
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
    $OS_USERNAME-node$node > /dev/null 2>&1 && echo -e "\e[1;32mOK\e[0m" || {
        echo -e "\e[1;31mFAILED [${node}]\e[0m"
    }
done

echo -ne "\e[2mWaiting for API Server.\e[0m"
before_time=`date +%s`
while [ 1 ]
do
    sleep 1
    if curl -m1 http://$IP:8080/api/v1/namespaces/default/pods > /dev/null 2>&1
    then
        echo -e "\e[1;32mOK\e[0m"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 300 ]; then
        echo -e "\e[1;31mTIMEOUT [5m]\e[0m"
        cleanAndExit 100
    fi

    echo -en "\e[2m.\e[0m"
done

echo -ne "\e[2mWaiting for the Node/s to register.\e[0m"
before_time=`date +%s`
while [ 1 ]; do
    sleep 5

    node_list=`kubectl -s http://$IP:8080 get nodes 2> /dev/null`
    arr=()
    while read -r line; do
       arr+=("$line")
    done <<< "$node_list"

    if [ ${#arr[@]} -eq `expr $nodes + 1` ]; then
        echo -e "\e[1;32mOK\e[0m"
        break
    fi

    now_time=`date +%s`
    spent_time=`expr $now_time - $before_time`
    if [ $spent_time -gt 600 ]; then
        echo -e "\e[1;31mTIMEOUT [10m]\e[0m"
        cleanAndExit 100
    fi

    echo -en "\e[2m.\e[0m"
done

echo
echo "K8S Nodes (Minions)"
echo "==================="
kubectl -s http://$IP:8080 get nodes
echo

# add kube-ui rc and svc
echo -e "\e[2mAdding K8S UI...\e[0m"
kubectl -s http://$IP:8080 create -f files/kube-system.yaml  >/dev/null 2>&1 && \
kubectl -s http://$IP:8080 create -f files/kube-ui/kube-ui-rc.yaml --namespace=kube-system  >/dev/null 2>&1 && \
kubectl -s http://$IP:8080 create -f files/kube-ui/kube-ui-svc.yaml --namespace=kube-system  >/dev/null 2>&1 && {
    echo -e "\e[2mK8S UI Added.\e[0m [URL] \e[1mhttp://${IP}:8080/ui\e[0m"
} || {
    echo -e "\e[31mFailed to add K8S UI\e[0m"
}

echo -e "\e[1mK8S Cluster setup complete.\e[0m"
cleanAndExit

# TODO:
# Check if key-pair exists, ask to add this machine's public key, if not ask to delete, crete if key pair doesn't exist
# call a clean method instead of exit 100
