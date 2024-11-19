#!/bin/bash -i
echo ${_REMOTE_USER}
sudo -Hn -u ${_REMOTE_USER} ./install_user.sh
