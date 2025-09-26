#!/bin/bash

echo -n "Enter Luks password: "
read -s password
echo
echo "$password" | ssh 192.168.0.20 sudo rsync-backup
