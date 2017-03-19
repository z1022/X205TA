For bluetooth, some distro need /dev/ttyS4 instead of /dev/ttyS1 in file btattach.service
save and run
sudo systemctl daemon-reload
sudo systemctl restart btattach
