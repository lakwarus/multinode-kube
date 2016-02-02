# Setup scripts to create a multi-node Kubernetes Cluster


## Configuration

1. Change `OS_USERNAME` in `openrc.sh` to match your username to the OpenStack cloud.
```
export OS_USERNAME="lakmal"
```

2. If you already have a key-pair named `kube` generated under your account, copy that to project root (`<ROOT>/kube.pem`). Otherwise the script will attempt to create a key-pair with name `kube` and download it for you.


## How to run

`./kube.sh`

This will install the prerequisites needed and setup the Kubernetes Master and Minion nodes per your input.

## Tested on
1. Mac
2. Ubuntu
