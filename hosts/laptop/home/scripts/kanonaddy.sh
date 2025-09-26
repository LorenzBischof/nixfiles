#!/bin/bash

set -e

##############################################################################
#
#  BEFORE RUNNING - two environment variables
#  export KPPW="Your KeepassxC password"
#  export KPDB=/path/to/keepassxc.kdbx
#
##############################################################################

KPDB=/home/lbischof/files-lo/Passwords.kdbx

if [ ! -f "${KPDB}" ];then
    echo "Please specify the database path in KPDB"
    exit 1
fi

if [ -z "${KPPW}" ];then
    read -s -p "Please enter the password for the Keepassxc database:" KPPW
    # Add a new line after password prompt
    echo
fi

TOKEN="$(echo "${KPPW}" | keepassxc-cli show -q -s "${KPDB}" "Anonaddy" -a API-Token)"

emails=""

# Search notes for email
while read line; do
    email="$(echo "${KPPW}" | keepassxc-cli show -q "${KPDB}" "${line}" -a notes | grep -oP '(?<=email:).*')"
    title="$(echo "${KPPW}" | keepassxc-cli show -q "${KPDB}" "${line}" -a title)"
    echo $title ${email## }
    # Trim one leading whitespace character
    emails+="\n${email## }"
done <<< $(echo "${KPPW}" | keepassxc-cli search -q "${KPDB}" '*notes:"email:.*@(anonaddy|mailer.me)" !group:"Recycle Bin"')

# Search attributes for email
while read line; do
    email="$(echo "${KPPW}" | keepassxc-cli show -q "${KPDB}" "${line}" -a email)"
    title="$(echo "${KPPW}" | keepassxc-cli show -q "${KPDB}" "${line}" -a title)"
    echo $title $email
    emails+="\n$email"
done <<< $(echo "${KPPW}" | keepassxc-cli search -q "${KPDB}" 'attr:email !group:"Recycle Bin"')

while read line; do
    email="$(echo "${KPPW}" | keepassxc-cli show -q "${KPDB}" "${line}" -a username)"
    title="$(echo "${KPPW}" | keepassxc-cli show -q "${KPDB}" "${line}" -a title)"
    echo $title $email
    emails+="\n$email"
done <<< $(echo "${KPPW}" | keepassxc-cli search -q "${KPDB}" 'user:"@anonaddy|@mailer.me" !group:"Recycle Bin"')

# trim first newline
emails="${emails:2}"

aliases="$(curl --silent --request GET \
    --get "https://app.anonaddy.com/api/v1/aliases" \
    --header "Content-Type: application/json" \
    --header "X-Requested-With: XMLHttpRequest" \
    --header "Authorization: Bearer ${TOKEN}" | jq -r '.data[] | .email')"

echo
echo "Emails in Keepassxc that do not exist as aliases:"
comm -23 <(echo -e "$emails" | sort) <(echo "$aliases" | sort)
echo
echo "Aliases that were not found in Keepassxc:"
comm -23 <(echo "$aliases" | sort) <(echo -e "$emails" | sort)

