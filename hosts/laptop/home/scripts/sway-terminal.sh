# I had the following before:
# [con_id="__focused__" app_id="^(?!org.keepassxc.KeePassXC).*$"] exec foot; [con_id="__focused__" app_id="org.keepassxc.KeePassXC"] exec wtype -M ctrl t -m ctrl'
# Problems:
# - Always have to specify excludes/negatives
# - Does not work if no window is focused
focused="$(swaymsg -t get_tree | jq '.. | select(.type?) | select(.focused==true).app_id')"
if [[ $focused == "org.keepassxc.KeePassXC" ]]; then
    wtype -M ctrl t -m ctrl
else
    foot
fi
