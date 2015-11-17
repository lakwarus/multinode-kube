#!/bin/bash

if [[ "$OSTYPE" == "linux-gnu" ]]; then
    echo "Setting up prerequisite for Linux..."
    aptitude install python-pip
elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Setting up prerequisite for Mac..."
    sudo easy_install pip > /dev/null 2>&1
    sudo pip install rackspace-novaclient > /dev/null 2>&1
    source openrc.sh
else
    # Unknown.
    echo "Setting up prerequisite..."
fi
