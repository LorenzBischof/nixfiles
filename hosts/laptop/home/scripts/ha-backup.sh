#!/bin/bash

set -Eeuxo pipefail

src=hassio@192.168.0.102:/root/backup/
dst=lbischof@192.168.0.20:/data/backups/homeassistant/
tmp=$(mktemp --tmpdir -d "$(basename $0).XXXXXXXXXXXX")
trap 'rm -rf "$tmp"; exit' ERR EXIT HUP INT TERM

rsync -av $src $tmp/
rsync -av $tmp/ $dst
