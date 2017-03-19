#!/usr/bin/env bash

####################################################
##
## Usage:
## The partition you run this script from should not be NTFS or FAT formatted and should have at least 6.5GB free space.
##
## Run either: 	sudo ./x205ta-iso2zip.sh /path/to/ubuntu.iso
## or: 			sudo ./x205ta-iso2zip.sh
## (The latter will open a GUI box to let you pick an iso (requires zenity)
##
## You can choose to make the script create a zip-file that can be copied to a usb stick manually,
## or you can choose to let the script format a specified usb stick and copy the altered iso onto it.
##
## What does this script do to the iso?:
## This script extracts an Ubuntu iso into a temporary directory in the same directory as this script,
## then extracts the squashfs which was within that iso and adds tweaks to it meant to improve usability of,
## and ease of installation particular to, the X205TA.
## Then it repackages the squashfs, and zips the iso-contents or copies them to a usb.
## Lastly it deletes the temporary directory.
##
## This script needs internet access to download (from github):
## brcmfmac43340-sdio.bin & brcmfmac43340-sdio.txt (to make wifi work)
## BCM43341B0.hcd (to make bluetooth work)
## bootia32.efi (to make the installer-usb efi-bootable)
##
## Prerequisites:
## -	zenity (if not specifying an iso in the command when running the script)
## -	7zip
## -	tar
## -	parted (if choosing to directly create a usb)
## -	curl
## -	squashfs-tools
## -	zip (if choosing to create a zip file)
## -	(root rights (because files & directories in the extracted squashfs are owned by root) and to format usb stick)
##
## If this scripts errors during unsquashing on account of not being able to find the squashfs-file
## because you use an ISO from a distro that is not mentioned in the script, try to manually unzipping the iso
## to find out where the squashfsfile is stored and change the variables SQUASHFSDIR & SQUASHFSFILE accordingly.
##
## This script is intended for general use and no warranty is implied for suitability to any given task.
## I hold no responsibility for your setup or any damage done while using/installing/modifing this script.
##
####################################################

##  PRECAUTIONS (EXIT ON UNBOUND VARIABLES / IF A SUBCOMMAND RETURNES A NON-ZERO EXIT / ON PIPEFAIL)
set -ueo pipefail

##  LET SCRIPT CONTINUE IF $1 IS NOT SET EVEN THOUGH set -u WONT ALLOW UNSET PARAMETERS IN ORDER TO PREVENT UNWANTED SCRIPT-BEHAVIOUR
##  ($1 MEANS: SPECIFYING AN ISO-FILE AS A PARAMETER AS PART OF YOUR COMMAND TO RUN THIS BASH-SCRIPT)
SET1=${1:-}

CURRENTPATH=$(pwd)
USR=""

##  FOR DEBUGGING PURPOSES, TO DISABLE THE clear COMMAND ACROSS THE SCRIPT
CLEAR1="clear"
##  IF THE USER EXITS THE SCRIPT, OR IF THE SCRIPT FINISHES: REMOVE THE TEMPORARY DIRECTORY AND ITS CONTENTS
trap 'removetempdir' TERM EXIT

#  SQUASHFSDIR AND SQUASHFSFILE VARY PER DISTRO, AND SOMETIMES EVEN PER DESKTOP ENVIRONMENT
#  IN THE FUNCTION whichdistro THE USER IS ASKED WHICH DISTRO AND DESKTOP ENVIRONMENT THE ISO HAS TO SET THESE VARIABLES TO THEIR CORRECT VALUES
#  TO OVERRIDE (AND DISABLE) THE FUNCTION whichdistro; SET OVERRIDE TO "1".
OVERRIDE="0"
DISTRO=manjaro
ARCH=x86_64 #or ARCH=i686
SQUASHFSDIR=manjaro/x86_64
SQUASHFSFILE=xfce-image.sqfs

##  TO DISPLAY TOTAL NUMBER OF STEPS WHEN INFORMING THE USER WHICH STEP IS CURRENTLY BEING EXECUTED (ONLY COUNTING TASKS THAT TAKE A LONG TIME)
TOTALSTEPS=4

##  TO COLORIZE PRINTF OUTPUTS
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[38;5;208m'
NC='\033[0m'
bold=$(tput bold)
normal=$(tput sgr0)

##  CHECK IF USER USED PARAMETER TO SPECIFY ISO-FILE OR WANTS TO USE ZENITY TO BROWSE TO ISO-FILE
function zenityorparameter {
if [ ! -z $SET1 ]; then
ISO=$SET1
$CLEAR1
else
command -v zenity >/dev/null 2>&1 || { printf "${RED}[ FAIL ]${NC} zenity not installed: type iso path and filename as parameter (e.g. ${bold}./script.sh /path/to/filename.iso${normal}) or install zenity\n"; exit 8; }
ISO=$(zenity --file-selection --file-filter='ISO files (iso) | *.iso' --title="Select an ISO file" 2>/dev/null)
	if [ -z $ISO ]; then
	exit 1
	fi
fi

##  CUTS THE PATH FROM THE INPUTFILE SO THE FILENAME IS KNOWN, NECESSARY TO OUTPUT <ISOFILENAME>.zip
ISOFILE=${ISO##*/}
}

##  LISTS REMOVABLE USB STICKS, AND LETS USER CHOOSE WHICH USB STICK TO USE
function whichusb {
	export USBKEYS=($(
	    grep -Hv ^0$ /sys/block/*/removable |
	    sed s/removable:.*$/device\\/uevent/ |
	    xargs grep -H ^DRIVER=sd |
	    sed s/device.uevent.*$/size/ |
	    xargs grep -Hv ^0$ |
	    cut -d / -f 4
	))
	export STICK
	case ${#USBKEYS[@]} in
	    0 ) echo; echo -e " ${RED}[ FAIL ]${NC} No USB Stick found, exiting..."; echo; exit 0 ;;
	    Q ) exit 5 ;;
	    * )
	    STICK=$(
	    bash -c "$(
	        echo -n dialog --menu \"Choose which USB stick you want to use \(WARNING: ALL DATA ON THE USB STICK WILL BE ERASED !!!\)\" 22 100 17;
	        for dev in ${USBKEYS[@]} ;do
	            echo -n \ $dev \"$(
	                sed -e s/\ *$//g </sys/block/$dev/device/model
	                )\" ;
	            done
	        )" 2>&1 >/dev/tty
	    )
	    ;;
	esac
	if [ -z "$STICK" ]; then
		$CLEAR1
		echo -e " ${GREEN}[ OK ]${NC} Aborting per user request..."
		exit 6
	fi
		$CLEAR1
		read -p "`echo $'\n '` THIS WILL DESTROY ALL EXISTING DATA ON: `echo $'\n '` DEVICE:      /dev/$STICK `echo $'\n '` WITH NAME:   $(cat /sys/block/$STICK/device/model) `echo $'\n '``echo $'\n '` IF YOU ARE SURE, TYPE UPPERCASE yes BENEATH AND HIT ENTER: `echo $'\n '` `echo $'\n '` " choice
		case "$choice" in 
	  		YES ) echo; echo -e "  ${GREEN}[ OK ]${NC} You have typed YES"; echo; sleep 1; echo "  formatting /dev/$STICK $(cat /sys/block/$STICK/device/model)... (hold ctrl+c to abort)"; sleep 5;;
	  		n|N|no|NO|nO|Q|q|quit|QUIT|Quit|EXIT|Exit|exit ) echo "${GREEN}[ OK ]${NC} Aborting per user request..."; exit 7;;
	  		yes ) echo -e "  ${RED}[ FAIL ]${NC} You have typed lowercase yes, Aborting..."; exit 7;;
	  		* ) printf "  ${RED}[ FAIL ]${NC} Invalid entry, Aborting...\n"; exit 7;;
		esac
}

##  CHECKS IF THE SCRIPT IS RUN AS ROOT
##  ROOT IS NECESSARY BECAUSE THE SQUASHFS FILESYSTEM CONTAINS FILES/DIRECTORIES (THAT NEED TO BE ALTERED) WHICH ARE OWNED BY ROOT
function checkroot {
	if [ "$EUID" -ne 0 ]
		then
			printf "${RED}[ FAIL ]${NC} Please run as root\n"
			removetempdir
			exit 1
		else
			printf "${GREEN}[ OK ]${NC} You are root\n"
			$CLEAR1
	fi
}

##  CHECKS FREE SPACE ON THE PARTITION WHERE THE CURRENT DIRECTORY RESIDES
##  THE WORKING DIRECTORY WILL GET AS BIG AS 6.5GB (DEPENDING ON THE ISO THAT WAS CHOSEN)
function checkfreespace {
	if [ $(df $CURRENTPATH|tail -n1|awk '{print $4}') -gt 6500000 ]
	then
		printf "${GREEN}[ OK ]${NC} Enough free space\n"
		$CLEAR1
	else
		printf "${RED}[ FAIL ]${NC} Not enough free space, move script and iso to a directory with more than 6GB free space and try again"
		removetempdir
		exit 2
	fi
}

##  CHECKS IF THE PARTITION TYPE WHERE THE SQUASHFS FILESYSTEM WILL BE EXTRACTED SUPPORTS FILE OWNER/GROUP PROPERTIES. IF IT DOESNT THE EXTRACTED FILESYSTEM MIGHT 
##  LOSE GROUP/OWNERSHIP PROPERTIES AND SYMLINK CAPABILITY, RESULTING IN AN UNBOOTABLE USB.
function checkpartitiontype {
	if [ $(df -T $CURRENTPATH|tail -n1|awk '{print $2}') = "vfat" ] || [ $(df -T $CURRENTPATH|tail -n1|awk '{print $2}') = "ntfs" ]
	then
		printf "${RED}[ FAIL ]${NC} Wrong partition type: move the script and iso to a partition that supports group/ownership\n"
		removetempdir
		exit 3
	else
		printf "${GREEN}[ OK ]${NC} Partition type correct\n"
		$CLEAR1
	fi
}

##  CHECKS IF SOME BINARIES THAT ARE USED IN THE SCRIPT ARE INSTALLED, AND INFORMS THE USER IF THEY AREN'T (AND THEN EXITS)
function checkprerequisites {
NOTFOUND="0"
BINARIES=( 7z mksquashfs unsquashfs curl zip tar mkfs.vfat parted isoinfo dialog )
for i in "${BINARIES[@]}"
do
command -v $i >/dev/null 2>&1 || { printf "${RED}[ FAIL ]${NC} $i not installed\n"; NOTFOUND="1"; }
done

if [[ $NOTFOUND == "1" ]]; then
exit 8
fi
}

##  UNZIPS SELECTED ISO INTO THE TEMPORARY DIRECTORY
function unzipiso {
	$CLEAR1
	VERSION7Z=$(echo $( 7z --help|grep Copyright|awk '{print $3}' |cut -c 1-1))
	echo
	echo "Unzipping iso... (step 1 of $TOTALSTEPS)"
	echo
	if [ $VERSION7Z -lt 2 ]
		then
		7z x -bb0 -bso0 -bse0 -bsp2 $ISO -o$TEMPDIR
		else
		7z x $ISO -o$TEMPDIR >/dev/null 2>&1
	fi
$CLEAR1
}

##  EXTRACTS THE SQUASHFS FILE THAT WAS WITHIN THE ISO FILE TO squashfs-root DIRECTORY; CREATED IN THE SAME DIRECTORY AS THE SQUASHFS FILE ITSELF
function unsquash {
	echo
	echo "Unsquashing $SQUASHFSFILE... (step 2 of $TOTALSTEPS)"
	echo
	if [ $DISTRO == "fedora" ] && [ ! -d $TEMPDIR/$SQUASHFSDIR ]; then
	SQUASHFSDIR=images
	SQUASHFSFILE=install.img
	fi
	pushd $TEMPDIR/$SQUASHFSDIR
	unsquashfs $SQUASHFSFILE
	if [ $DISTRO == "manjaro" ]; then
        if [ ! -d $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/systemd/system ]; then
            if [ -f $TEMPDIR/$SQUASHFSDIR/try-root-image.sqfs ]; then
                echo -e " ${RED}[ FAIL ]${NC} Aborting operation, could not find suitable rootfs to unpack and apply tweaks to..."
                exit 0
            else
            rm -rf $TEMPDIR/$SQUASHFSDIR/squashfs-root
            touch $TEMPDIR/tryrootimagesqfs
            OLDSQUASHFSFILE="$SQUASHFSFILE"
            SQUASHFSFILE="root-image.sqfs"
            echo;echo;echo;echo -e "${ORANGE}[ WARN ]${NC} Attempting to unsquash again with $SQUASHFSFILE because $OLDSQUASHFSFILE did not contain rootfs filesystem to which tweaks could be applied"
            unsquash
            fi
        fi
    fi
    rm -rf $TEMPDIR/tryrootimagesqfs
	popd
}

function install-grub-sh {
cat > $TEMPDIR/$SQUASHFSDIR/squashfs-root/root/install-grub.sh << "EOF2"
#!/usr/bin/env bash

set -uo pipefail

SET1=${1:-}
TEMPMOUNT=$(mktemp -d -p /tmp)

##  TO COLORIZE PRINTF OUTPUTS
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
bold=$(tput bold)
normal=$(tput sgr0)


trap 'removetempdir' EXIT
CLEAR1="clear"

function silent {
if [ ! -z $SET1 ] && [ $SET1 == "-v" ];then
        $@
else
	$@ > /dev/null 2>&1
fi
}

function checkprerequisites {
$CLEAR1
## CHECK INTERNET CONNECTIVITY
wget -q --tries=10 --timeout=10 --spider http://google.com
if [[ $? -eq 0 ]]; then
        silent echo -e "${GREEN}[ OK ]${NC} Online"
else
        echo -e "${RED}[ FAIL ]${NC} Can't reach the internet, please check your connection"
        exit 1
fi
printf "Checking prerequisites, this might take a while... "
if [ -f /usr/bin/dnf ]; then
    echo "(Especially for Fedora)"
    silent dnf install dialog --assumeyes
elif [ -f /usr/bin/apt-get ]; then
    sed -e '/cdrom/ s/^#*/#/' -i /etc/apt/sources.list
    silent apt-get update
    silent apt-get install -y dialog
elif [ -f /usr/bin/pacman ]; then
    silent pacman -Sy --noconfirm
    silent pacman -S dialog --noconfirm
fi
    command -v dialog || { printf "${RED}[ FAIL ]${NC} dialog not installed\n"; exit 1; }
}

function whichpartition {
        export PARTITIONS=($(
                grep -Hv ^1$ /sys/block/mmcblk*/mmcblk*/ro | sed s/ro:.*$/uevent/ \
                | xargs grep -H ^DEVNAME=mmc | sed s/device.uevent.*$/size/ \
                | cut -d / -f 5
        ))
        export TARGET
        case ${#PARTITIONS[@]} in
            0 ) echo No suitable mmcblk drive found; exit 0 ;;
            Q ) exit 5 ;;
            * )
            TARGET=$(
            bash -c "$(
                echo -n dialog --menu \"On which partition did you just install Linux ?\" 20 30 10;
                for dev in ${PARTITIONS[@]} ;do
                    echo -n \ $dev \"$(
                        echo
                        )\" ;
                    done
                )" 2>&1 >/dev/tty
            )
            ;;
        esac
        if [ -z "$TARGET" ]; then
                $CLEAR1
                echo "Aborting at user request..."
                exit 6
        fi
                $CLEAR1
                read -p "`echo $'\n '` THIS SCRIPT WILL ATTEMPT TO INSTALL GRUB-I386-EFI FOR THE FOLLOWING PARTITION: `echo $'\n '` DEVICE:      /dev/$TARGET `echo $'\n '` `echo $'\n '``echo $'\n '` IF YOU ARE SURE, TYPE UPPERCASE yes BENEATH AND HIT ENTER `echo $'\n '``echo $'\n '` " choice
                case "$choice" in
                        YES ) echo; $CLEAR1; printf "${GREEN}[ OK ]${NC} You have typed YES, please wait for the script to finish...\n"; sleep 5;;
                        n|N|no|NO|nO|Q|q|quit|QUIT|Quit|EXIT|Exit|exit ) echo -e "${RED}[ FAIL ]${NC} Aborting..."; exit 7;;
                        yes ) printf "${RED}[ FAIL ]${NC} You have typed lowercase yes, Aborting...\n"; exit 7;;
                        * ) printf "${RED}[ FAIL ]${NC} Invalid entry, Aborting...\n"; exit 7;;
                esac
}

function chrootandinstallgrub {
        silent mount /dev/$TARGET $TEMPMOUNT
        silent pushd $TEMPMOUNT > /dev/null 2>&1
        silent mount --bind /proc $TEMPMOUNT/proc
        silent mount --bind /sys $TEMPMOUNT/sys
        silent mount --bind /dev $TEMPMOUNT/dev
        silent mount --bind /dev/pts $TEMPMOUNT/dev/pts
        silent mount --bind /run $TEMPMOUNT/run
        silent mount --bind /sys/firmware/efi/efivars $TEMPMOUNT/sys/firmware/efi/efivars
        silent cp /lib/firmware/brcm/brcmfmac43340-sdio.txt lib/firmware/brcm/brcmfmac43340-sdio.txt
        silent chroot $TEMPMOUNT /bin/bash -x << EOF
mount -a

##  SOMEHOW FEDORA KEEPS USING linuxefi/initrdefi AS BOOT COMMANDS IN GRUB, WHICH DOESNT WORK
##  SO I REPLACE THEM WITH linux/initrd INSTEAD
sed -i "s/linuxefi=\"linuxefi\"/linuxefi=\"linux\"/g" /etc/grub.d/10_linux
sed -i "s/initrdefi=\"initrdefi\"/initrdefi=\"initrd\"/g" /etc/grub.d/10_linux

## ADD BOOT PARAMETER intel_idle.max_cstate=1 (TO PREVENT FREEZES) AND clocksource=acpi_pm (TO PREVENT KERNEL LOCKUPS WITH FEDORA)
if [ -f etc/default/grub ]; then
        if [ $(grep -c "intel_idle.max_cstate" etc/default/grub) -gt 0 ]; then
        echo
        else
        sed -i.bak 's/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"intel_idle.max_cstate=1 clocksource=acpi_pm /g' /etc/default/grub
        rm -f /etc/default/grub.bak
    fi
else
    echo "GRUB_CMDLINE_LINUX=\"quiet splash intel_idle.max_cstate=1 clocksource=acpi_pm\"" >> /etc/default/grub
fi
## CHECK INTERNET CONNECTIVITY IN CHROOT
wget -q --tries=10 --timeout=10 --spider http://google.com
if [[ $? -eq 0 ]]; then
        echo "Online"
else
        echo "Offline"
        rm -f /etc/resolv.conf
        echo "nameserver 8.8.4.4" >> /etc/resolv.conf
        echo "nameserver 8.8.8.8" >> /etc/resolv.conf
fi
if [ -f /usr/bin/apt-get ]; then
    apt-get update -y
    apt-get install -y grub-efi-ia32 efibootmgr
elif [ -f /usr/bin/pacman ]; then
    pacman -Sy --noconfirm
    pacman -Rsc efibootmgr --noconfirm
    pacman -S grub efibootmgr --noconfirm --force
elif [ -f /usr/bin/dnf ]; then
    dnf install grub2 grub2-efi-modules efibootmgr --assumeyes
    sed -i.bak '/ \/ /d' /etc/fstab
    echo "UUID="$(tune2fs -l /dev/$TARGET | grep UUID | awk '{print $3}')" /   "$(lsblk -f | grep $TARGET | awk '{print $2}')"    defaults    1   1" >> /etc/fstab
fi
##  CHECK IF THE LINUX INSTALLER INSTALLED A GRUB PACKAGE THAT SUPPORTS i386-efi
##  WHICH IS ESSENTIAL FOR THE X205TA BOOT PROCESS, SO IF IT ISN'T PROVIDED BY GRUB,
##  DOWNLOAD A COPY
if [ ! -d "/usr/lib/grub/i386-efi" ]; then
	echo "Downloading /usr/lib/grub/i386-efi because it doesn't exist..."
	curl -s https://raw.githubusercontent.com/harryharryharry/x205ta-iso2usb-files/master/grublibs-i386-efi.tar.gz | tar xz
fi
if [ -f "/usr/sbin/grub-install" ]; then
    grub-install --target=i386-efi --bootloader-id=ubuntu --efi-directory=/boot/efi --recheck
elif [ -f "/usr/sbin/grub2-install" ]; then
    grub2-install --target=i386-efi --bootloader-id=ubuntu --efi-directory=/boot/efi --recheck
else
    echo
fi
if [ -f "/usr/bin/grub-mkconfig" ]; then
    grub-mkconfig -o /boot/grub/grub.cfg
elif [ -f "/usr/sbin/grub2-mkconfig" ]; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
else
    echo
fi
EOF
}

function copytweaks {
	silent mkdir -p $TEMPMOUNT/etc/modprobe.d/
	if [ -f $TEMPMOUNT/etc/modprobe.d/blacklist.conf ] && [ $(grep -o 'blacklist btsdio' $TEMPMOUNT/etc/modprobe.d/blacklist.conf | wc -l) -lt 1 ]; then
		silent echo "blacklist btsdio" >> $TEMPMOUNT/etc/modprobe.d/blacklist.conf
	fi
	silent mkdir -p $TEMPMOUNT/usr/lib/systemd/system-sleep
	silent cp -a /usr/lib/systemd/system-sleep/elan-fix.sh $TEMPMOUNT/usr/lib/systemd/system-sleep/elan-fix.sh
	silent mkdir -p $TEMPMOUNT/lib/firmware/brcm
	silent cp -a /lib/firmware/brcm/brcmfmac43340-sdio.txt $TEMPMOUNT/lib/firmware/brcm/
	silent cp -a /lib/firmware/brcm/brcmfmac43340-sdio.bin $TEMPMOUNT/lib/firmware/brcm/
	silent cp -a /lib/firmware/brcm/BCM43341B0.hcd $TEMPMOUNT/lib/firmware/brcm/
	cp -a /etc/systemd/system/btattach.service $TEMPMOUNT/etc/systemd/system/
	silent cp -a /etc/systemd/system/reload-brcmfmac-and-elan_i2c.service $TEMPMOUNT/etc/systemd/system/
	silent mkdir -p $TEMPMOUNT/etc/systemd/system/multi-user.target.wants
	silent cp -a /etc/systemd/system/multi-user.target.wants/btattach.service $TEMPMOUNT/etc/systemd/system/multi-user.target.wants/
	silent cp -a /etc/systemd/system/multi-user.target.wants/reload-brcmfmac-and-elan_i2c.service $TEMPMOUNT/etc/systemd/system/multi-user.target.wants/
	silent cp -a /root/reload-brcmfmac-and-elan_i2c.sh $TEMPMOUNT/root/
}

function removetempdir {
silent umount -rl $TEMPMOUNT
SETTEMPMOUNT=${TEMPMOUNT:-}
if [ ! -z $SETTEMPMOUNT ]; then
silent rm -rf $SETTEMPMOUNT
fi
}

checkprerequisites
whichpartition
chrootandinstallgrub
copytweaks

echo
echo -e "${GREEN}[ OK ]${NC} Script ended, try rebooting to see if grub is installed correctly !"

exit 0
EOF2
chmod +x $TEMPDIR/$SQUASHFSDIR/squashfs-root/root/install-grub.sh
}

function reloadmodules-sh {
mkdir -p $TEMPDIR/$SQUASHFSDIR/squashfs-root/usr/lib/systemd/system-sleep
cat > $TEMPDIR/$SQUASHFSDIR/squashfs-root/usr/lib/systemd/system-sleep/reloadmodules.sh << "EOF"
#!/usr/bin/env bash
if [ "${1}" == "pre" ]; then
    echo
elif [ "${1}" == "post" ]; then
    modprobe -r elan_i2c
    modprobe elan_i2c
    modprobe -r brcmfmac
    modprobe brcmfmac
fi
EOF
chmod +x $TEMPDIR/$SQUASHFSDIR/squashfs-root/usr/lib/systemd/system-sleep/reloadmodules.sh
}

function boot-reloadmodules-service {
mkdir -p $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/systemd/system/multi-user.target.wants
cat > $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/systemd/system/multi-user.target.wants/reloadmodules.service << "EOF"
[Unit]
Description=Reload brcmfmac and elan_i2c modules on boot

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/lib/systemd/system-sleep/reloadmodules.sh post

[Install]
WantedBy=multi-user.target
EOF
}

function resume-reloadmodules-service {
mkdir -p $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/systemd/system/suspend.target.wants/
cat > $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/systemd/system/suspend.target.wants/reloadmodules.service << "EOF"
[Unit]
Description=Reload elan_i2c and brcmfmac modules on resume
After=suspend.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/lib/systemd/system-sleep/reloadmodules.sh post

[Install]
WantedBy=suspend.target
EOF
}

function bluetooth-fix {
if [ $DISTRO == "ubuntu" ]; then
    SNUMBER=4
elif [ $DISTRO == "fedora" ] || [ $DISTRO == "antergos" ] || [ $DISTRO == "manjaro" ] || [ $DISTRO == "arch" ]; then
    SNUMBER=1
else
    SNUMBER=1
fi
mkdir -p $TEMPDIR/$SQUASHFSDIR/squashfs-root$USR/lib/firmware/brcm
wget -q https://raw.githubusercontent.com/harryharryharry/x205ta-iso2usb-files/master/BCM43341B0.hcd -O $TEMPDIR/$SQUASHFSDIR/squashfs-root$USR/lib/firmware/brcm/BCM43341B0.hcd
#wget -q https://sourceforge.net/p/android-x86/device_generic_common/ci/eb30573f1c0a2c3282b493de690533314e71c91a/tree/firmware/brcm/BCM43341B0.hcd?format=raw -O $TEMPDIR/$SQUASHFSDIR/squashfs-root$USR/lib/firmware/brcm/BCM43341B0.hcd
wget -q https://raw.githubusercontent.com/harryharryharry/x205ta-iso2usb-files/master/brcmfmac43340-sdio.txt -O $TEMPDIR/$SQUASHFSDIR/squashfs-root$USR/lib/firmware/brcm/brcmfmac43340-sdio.txt

cat > $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/systemd/system/btattach.service << EOF
[Unit]
Description=Btattach

[Service]
Type=simple
ExecStart=/usr/bin/btattach --bredr /dev/ttyS$SNUMBER -P bcm
ExecStop=/usr/bin/killall btattach

[Install]
WantedBy=multi-user.target
EOF
ln -sf /etc/systemd/system/btattach.service $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/systemd/system/multi-user.target.wants/
}

##  ADDS TWEAKS (LIKE WIFI AND TOUCHPAD FIXES) TO THE LIVE USB ROOT FILESYSTEM, AND ADDS /root/install-grub.sh FOR SEVERAL DISTROS
function addshit2squash {

##  EXTRA MOUNTING OF rootfs.img WHEN FEDORA ISO IS USED, BECAUSE THE SQUASHFSFILE CONTAINS A rootfs.img INSTEAD OF THE ACTUAL ROOT FILESYSTEM
if [ $DISTRO == "fedora" ]; then
    mount -o loop -t ext4 $TEMPDIR/$SQUASHFSDIR/squashfs-root/LiveOS/$ROOTFS $TEMPDIR/$SQUASHFSDIR/squashfs-root
fi

##  CREATE install-grub.sh FOR FEDORA/MANJARO
if [ $DISTRO == "fedora" ] || [ $DISTRO == "manjaro" ] || [ $DISTRO == "ubuntu" ] ||  [ $DISTRO == "antergos" ]; then
    install-grub-sh
fi

reloadmodules-sh
boot-reloadmodules-service
resume-reloadmodules-service
bluetooth-fix
mkdir -p $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/modprobe.d/
echo "blacklist btsdio" >> $TEMPDIR/$SQUASHFSDIR/squashfs-root/etc/modprobe.d/blacklist.conf

if [ $DISTRO == "arch" ]; then
#THIS WILL MAKE THE ARCH ISO SEARCH FOR WIFI RIGHT AFTER IT BOOTS
echo "rmmod brcmfmac" >> $TEMPDIR/$SQUASHFSDIR/squashfs-root/root/.zshrc
echo "modprobe brcmfmac" >> $TEMPDIR/$SQUASHFSDIR/squashfs-root/root/.zshrc
echo "sleep 5" >> $TEMPDIR/$SQUASHFSDIR/squashfs-root/root/.zshrc
echo "rfkill unblock wifi" >> $TEMPDIR/$SQUASHFSDIR/squashfs-root/root/.zshrc
echo "wifi-menu" >> $TEMPDIR/$SQUASHFSDIR/squashfs-root/root/.zshrc
fi

if [ $DISTRO == "fedora" ]; then
umount $TEMPDIR/$SQUASHFSDIR/squashfs-root
fi
}

function addshit2debian {
INITRDDIR="$TEMPDIR/install.amd/gtk"

    function addshit2initrd {
    mkdir -p $INITRDDIR/tmp
    pushd $INITRDDIR/tmp > /dev/null 2>&1
    gunzip ./../initrd.gz
    cpio -id < ./../initrd
    clear
    mkdir -p $INITRDDIR/tmp/lib/firmware/brcm
    curl -s https://raw.githubusercontent.com/harryharryharry/x205ta-iso2usb-files/master/brcmfmac43340-sdio.bin.base64 | base64 -d > $INITRDDIR/tmp/lib/firmware/brcm/brcmfmac43340-sdio.bin
    curl -s https://raw.githubusercontent.com/harryharryharry/x205ta-iso2usb-files/master/brcmfmac43340-sdio.txt > $INITRDDIR/tmp/lib/firmware/brcm/brcmfmac43340-sdio.txt
    curl -s https://raw.githubusercontent.com/harryharryharry/x205ta-iso2usb-files/master/BCM43341B0.hcd.base64 | base64 -d > $INITRDDIR/tmp/lib/firmware/brcm/BCM43341B0.hcd
    cat > $INITRDDIR/tmp/tweaks.sh << "EOF2"
#!/bin/sh
mkdir -p                    /target/etc/modprobe.d
echo "blacklist btsdio" >>  /target/etc/modprobe.d/blacklist.conf
mkdir -p    /target/usr/lib/systemd/system-sleep
cat >       /target/usr/lib/systemd/system-sleep/reloadmodules.sh << "EOF"
#!/usr/bin/env bash
if [ "${1}" == "pre" ]; then
    echo
elif [ "${1}" == "post" ]; then
    modprobe -r elan_i2c
    modprobe elan_i2c
elif [ "${1}" == "boot" ]; then
    modprobe -r elan_i2c
    modprobe elan_i2c
    modprobe -r brcmfmac
    modprobe brcmfmac
fi
EOF
chmod +x /target/usr/lib/systemd/system-sleep/reloadmodules.sh
mkdir -p    /target/etc/systemd/system/suspend.target.wants
cat >       /target/etc/systemd/system/suspend.target.wants/reloadmodules.service << "EOF"
[Unit]
Description=Reload elan_i2c and brcmfmac modules on resume
After=suspend.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/lib/systemd/system-sleep/reloadmodules.sh post

[Install]
WantedBy=suspend.target
EOF
mkdir -p    /target/etc/systemd/system/multi-user.target.wants
cat >       /target/etc/systemd/system/multi-user.target.wants/reloadmodules.service << "EOF"
[Unit]
Description=Reload brcmfmac and elan_i2c modules on boot

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/lib/systemd/system-sleep/reloadmodules.sh boot

[Install]
WantedBy=multi-user.target
EOF
cat > /target/etc/systemd/system/btattach.service << "EOF"
[Unit]
Description=Btattach

[Service]
Type=simple
ExecStart=/usr/bin/btattach --bredr /dev/ttyS1 -P bcm
ExecStop=/usr/bin/killall btattach

[Install]
WantedBy=multi-user.target
EOF
sed -i 's/quiet/quiet intel_idle.max_cstate=1 clocksource=acpi_pm /g' /target/etc/default/grub
mount --bind /proc /target/proc
mount --bind /sys /target/sys
mount --bind /dev /target/dev
mount --bind /dev/pts /target/dev/pts
chroot /target /bin/bash -x << "EOF"
mount -a
update-grub
EOF
exit 0
EOF2
chmod +x $INITRDDIR/tmp/tweaks.sh
   	rm -rf ./../initrd
    sync
    find . | cpio --create --format='newc' > ./../initrd
    clear
    cd ..
    sync
    gzip initrd > /dev/null 2>&1
    sync
    rm -rf tmp
    popd > /dev/null 2>&1
    }

addshit2initrd
INITRDDIR="$TEMPDIR/install.amd"
addshit2initrd
}

##  AFTER THE TWEAKS HAVE BEEN ADDED TO THE squashfs-root IT CAN BE REPACKAGED, THIS WILL OVERWRITE THE OLD SQUASHFS FILE
##  WHEN THE NEW SQUASHFS FILE IS CREATED, THE squashfs-root DIRECTORY IS NO LONGER NEEDED AND THUS REMOVED
function makesquash {
	$CLEAR1
	echo
	echo "Tweaks added, resquashing $SQUASHFSFILE... (step 3 of $TOTALSTEPS)"
	echo
	mksquashfs $TEMPDIR/$SQUASHFSDIR/squashfs-root/ $TEMPDIR/$SQUASHFSDIR/$SQUASHFSFILE -noappend -always-use-fragments
	$CLEAR1
	rm -rf $TEMPDIR/$SQUASHFSDIR/squashfs-root/
	$CLEAR1
}

##  ADDS grub.cfg AND bootia32.efi TO THEIR APPROPRIATE PLACES WITHIN THE UNZIPPED ISO TO MAKE THE EVENTUAL USB BOOTABLE
function addshit2iso {
	rm -rf $TEMPDIR/EFI
	rm -rf $TEMPDIR/efi
	mkdir -p $TEMPDIR/EFI/BOOT
	curl -s https://raw.githubusercontent.com/harryharryharry/x205ta-iso2usb-files/master/bootia32.efi.base64 | base64 -d > $TEMPDIR/EFI/BOOT/bootia32.efi
	if [ ! -f $TEMPDIR/boot/grub/grub.cfg ]; then
	mkdir -p $TEMPDIR/boot/grub
    fi

if [ $DISTRO == "arch" ]; then
cat > $TEMPDIR/boot/grub/grub.cfg << "EOF"
set timeout=1
menuentry 'Arch Linux' {
linux (hd0,msdos1)/arch/boot/x86_64/vmlinuz quiet archisolabel=X205TA intel_idle.max_cstate=1
initrd (hd0,msdos1)/arch/boot/intel_ucode.img
initrd (hd0,msdos1)/arch/boot/x86_64/archiso.img
}
EOF
elif [ $DISTRO == "antergos" ]; then
cat > $TEMPDIR/boot/grub/grub.cfg << "EOF"
set timeout=1
menuentry 'Antergos' {
linux (hd0,msdos1)/arch/boot/vmlinuz quiet splash archisolabel=X205TA intel_idle.max_cstate=1
initrd (hd0,msdos1)/arch/boot/intel_ucode.img
initrd (hd0,msdos1)/arch/boot/archiso.img
}
EOF
elif [ $DISTRO == "manjaro" ]; then
cat > $TEMPDIR/boot/grub/grub.cfg << EOF
set timeout=1
menuentry 'Manjaro ($ARCH)' {
linux (hd0,msdos1)/manjaro/boot/$ARCH/manjaro quiet splash misobasedir=manjaro misolabel=X205TA nouveau.modeset=1 i915.modeset=1 radeon.modeset=1 logo.nologo overlay=nonfree nonfree=yes intel_idle.max_cstate=1
initrd (hd0,msdos1)/manjaro/boot/intel_ucode.img
initrd (hd0,msdos1)/manjaro/boot/$ARCH/manjaro.img
}
EOF
elif [ $DISTRO == "fedora" ] && [ $DISTRONAME == "Fedora" ]; then
if [ $SQUASHFSDIR == "images" ]; then
BOOTPARAMETER="inst.stage2=hd:LABEL=X205TA"
else
BOOTPARAMETER="root=live:CDLABEL=X205TA rd.live.image"
fi
cat > $TEMPDIR/boot/grub/grub.cfg << EOF
set timeout=1
menuentry 'Fedora' {
linux /isolinux/vmlinuz $BOOTPARAMETER quiet intel_idle.max_cstate=1 clocksource=acpi_pm
initrd /isolinux/initrd.img
}
EOF
elif [ $DISTRO == "fedora" ] && [ $DISTRONAME == "Korora" ]; then
cat > $TEMPDIR/boot/grub/grub.cfg << "EOF"
set timeout=1
menuentry 'Korora' {
linux /isolinux/vmlinuz0 root=live:CDLABEL=X205TA rd.live.image quiet intel_idle.max_cstate=1 clocksource=acpi_pm
initrd /isolinux/initrd0.img
}
EOF
elif [ $DISTRO == "debian" ]; then
cat > $TEMPDIR/preseed.cfg << "EOF"
d-i pkgsel/include string network-manager network-manager-gnome sudo
d-i pkgsel/update-policy select none
d-i preseed/late_command string ./tweaks.sh
popularity-contest popularity-contest/participate boolean false
EOF
#popularity-contest popularity-contest/participate boolean true
sed -i 's/--- quiet/--- quiet intel_idle.max_cstate=1 preseed\/file=\/cdrom\/preseed.cfg/g' $TEMPDIR/boot/grub/grub.cfg
elif [ $DISTRO == "ubuntu" ]; then
    if [ -f $TEMPDIR/boot/grub/grub.cfg ]; then
        sed -i 's/--/intel_idle.max_cstate=1 --/g' $TEMPDIR/boot/grub/grub.cfg
        echo "set timeout=1" >> $TEMPDIR/boot/grub/grub.cfg
        if [ $PERSISTENT == "persistent" ]; then
        dd if=/dev/zero of=$TEMPDIR/casper-rw bs=1M count=$PERSISTENTSIZE
        mkfs.ext3 -F $TEMPDIR/casper-rw
        sed -i.bak -e '0,/boot=casper/ s/boot=casper/boot=casper persistent/g' $TEMPDIR/boot/grub/grub.cfg
        fi
    else
        if [ $PERSISTENT == "persistent" ]; then
        dd if=/dev/zero of=$TEMPDIR/casper-rw bs=1M count=$PERSISTENTSIZE
        mkfs.ext3 -F $TEMPDIR/casper-rw
        fi
        DE=$(isoinfo -d -i $ISO | grep "Volume id:" | awk '{print $3}')
        cat > $TEMPDIR/boot/grub/grub.cfg << EOF
set timeout=1
menuentry 'Ubuntu (x86)' {
linux (hd0,msdos1)/casper/vmlinuz file=/cdrom/preseed/${DE,,}.seed boot=casper $PERSISTENT quiet splash intel_idle.max_cstate=1 ---
initrd (hd0,msdos1)/casper/initrd.lz
}
EOF
	fi
fi

}

##  MAKES A ZIP FILE OUT OF THE UNZIPPED ISO; IT WILL BE NAMED <ISOFILE>.zip AND CREATED IN THE DIRECTORY FROM WHICH THE SCRIPT WAS RUN
function createzip {
	$CLEAR1
	printf "Creating zipfile... (step 4 of $TOTALSTEPS)\n"
	cd $TEMPDIR
	zip -qry $CURRENTPATH/$ISOFILE.zip .
	successfulzip
}

##  IF THE USER CHOOSES TO DIRECTLY CREATE A USB, THIS FUNCTION WILL REFORMAT THE SELECTED USB STICK
function formatusb {
	##  UNMOUNT ANY MOUNTED PARTITIONS ON CHOSEN USB STICK
	command -v udevadm > /dev/null 2>&1 || { printf "${RED}[ FAIL ]${NC} udevadm not installed\n"; exit 9; }

	MOUNTNUMBER=$(mount | grep -c $STICK || /bin/true)
	CMD=""

	command_exists () {
	    type "$1" &> /dev/null
	}
	if command_exists udevadm; then
        	CMD="$(which udevadm) info -q all -n"
	fi

	if command_exists udevinfo; then
	        CMD="$(which udevinfo) -q all -n"
	fi

	if [ $MOUNTNUMBER -gt 0 ]
		then
        	for disk in /dev/$STICK*
        	do
		        DISK=$($CMD $disk | grep ID_BUS)
		        if [[ "$DISK" == *usb ]]; then
		                umount -l $disk > /dev/null 2>&1 || /bin/true
        		fi
	        done
        	else
	        echo
	fi
	unset MOUNTNUMBER
	unset CMD

	##  CREATE NEW MBR PARTITION TABLE ON CHOSEN USB STICK
	parted -s /dev/$STICK mklabel msdos

	##  CREATE A PARTITION THAT FILLS THE WHOLE USB STICK AND MAKE IT PRIMARY
	parted -s /dev/$STICK mkpart primary 1M 100%
	sleep 5

	##  FORMAT THAT PARTITION AS FAT32 (ALSO SETS LABEL TO A STATIC "X205TA" SO IT CAN BE REFERENCED IN THE GRUB.CFG)
	mkfs.vfat -n X205TA /dev/${STICK}1 > /dev/null 2>&1 || /bin/true

	$CLEAR1
	printf "  ${GREEN}[ OK ]${NC} Done formatting...\n"
}

##  COPIES THE EXTRACTED AND IMPROVED ISO TO THE SELECTED AND FORMATTED USB STICK
function copytousb {
	$CLEAR1
	echo "Copying files to USB... (step 4 of $TOTALSTEPS)"
	TEMPMOUNT=$(mktemp -d -p /tmp)
	mount /dev/${STICK}1 $TEMPMOUNT
	tar cf - --directory=$TEMPDIR . | ( cd $TEMPMOUNT; tar xf -)
	sync
	umount /dev/${STICK}1  > /dev/null 2>&1 || /bin/true
	rm -r $TEMPMOUNT
	$CLEAR1
	printf  "${GREEN}[ OK ]${NC} Done copying files to USB...\n"
	successfulusb
}

function whichdistro {
$CLEAR1
echo
echo "Of which distro would you like to create a bootable USB ?"
PS3='Enter: '
echo
options=("Ubuntu (>16.04) / Linux Mint 18 (Sarah) / ElementaryOS (Loki)" "Debian 9 (preferably netinstall alpha7)" "Arch Linux" "Antergos" "Manjaro" "Fedora" "Korora" "Quit")
select opt in "${options[@]}"
do
    case $opt in
        "Ubuntu (>16.04) / Linux Mint 18 (Sarah) / ElementaryOS (Loki)")
                DISTRO=ubuntu
                SQUASHFSDIR=casper
                SQUASHFSFILE=filesystem.squashfs
                $CLEAR1
		echo
                echo "Do you want to create a persistence-file so changes made while using the live-environment are saved ?"
                PS3='Enter: '
		echo
                options=("No (recommended)" "Yes" "Quit")
                select opt in "${options[@]}"
                do
                    case $opt in
                        "No (recommended)")
                        PERSISTENT=""
			break
                        ;;
                        "Yes")
                        $CLEAR1
			echo
                        read -p "How big (in MB) should the persistence-file be ? (max=4000MB; ~1000MB recommended): " PERSISTENTSIZE
                        if ! [[ "$PERSISTENTSIZE" =~ ^[0-9]+$ ]]; then
                            echo "Integers only, exiting..."
                            exit 4
                        fi
                        if [[ "$PERSISTENTSIZE" -gt 4000 ]]; then
                            echo "Persistent file too big, exiting... (max. 4000MB)"
                            exit 4
                        fi
                        PERSISTENT="persistent"
                        break
                        ;;
                        "Quit")
                        exit 4
                        ;;
                        *) echo invalid option;;
                    esac
                done
                break
            ;;
        "Debian 9 (preferably netinstall alpha7)")
                DISTRO=debian
                if [ ! $(md5sum $ISO|awk '{print $1}') == "3fe53635b904553b26588491e1473e99" ]; then
                dialog --colors --title "Warning !!!" --msgbox '\nI advice you to use the netinstall alpha7 Debian Stretch iso, newer isos break keyboard-support...\n\nhttp://cdimage.debian.org/cdimage/stretch_di_alpha7/amd64/iso-cd/debian-stretch-DI-alpha7-amd64-netinst.iso\n\n(use <ctrl + left mousebutton> to follow link)' 11 111
                fi
                break
            ;;
        "Arch Linux")
                DISTRO=arch
                SQUASHFSDIR=arch/x86_64
                SQUASHFSFILE=airootfs.sfs
                break
            ;;
        "Antergos")
                DISTRO=antergos
                SQUASHFSDIR=arch
                SQUASHFSFILE=root-image.sfs
                break
            ;;
        "Manjaro")
		DISTRO=manjaro
		$CLEAR1
		echo
		echo "Does the $DISTRO-iso has a x86 or x64 architecture ?"
                PS3='Enter: '
		echo
                options=("x86" "x64" "Quit")
                select opt in "${options[@]}"
                do
                    case $opt in
                        "x86")
                        ARCH="i686"
                        break
                        ;;
                        "x64")
                        ARCH="x86_64"
                        break
                        ;;
                        "Quit")
                        exit 4
                        ;;
                        *) echo invalid option;;
                    esac
                done
                SQUASHFSDIR=manjaro/$ARCH
                $CLEAR1
		echo
		echo "Which desktop environment does your Manjaro iso have ?"
		echo "(if the script fails with one of the desktop environments below, try again; choose 7; and type \"root\")"
		PS3='Enter: '
		echo
		options=("XFCE" "KDE" "LXQt" "MATE" "Cinnamon                                   " "Budgie" "Other" "Quit")
		select opt in "${options[@]}"
                do
                	case $opt in
                        	"XFCE")
                                	    SQUASHFSFILE=xfce-image.sqfs
                                        USR="/usr"
                                        break
                                        ;;
				"KDE")
                                        SQUASHFSFILE=kde-image.sqfs
                                        USR="/usr"
                                        break
                                        ;;
				"LXQt")
                                        SQUASHFSFILE=lxqt-image.sqfs
                                        USR="/usr"
                                        break
                                        ;;
				"MATE")
                                        SQUASHFSFILE=mate-image.sqfs
                                        USR="/usr"
                                        break
                                        ;;
				"Cinnamon                                   ")
                                        SQUASHFSFILE=cinnamon-image.sqfs
                                        USR="/usr"
                                        break
                                        ;;
				"Budgie")
                                        SQUASHFSFILE=budgie-image.sqfs
                                        USR="/usr"
                                        break
                                        ;;
				"Other")
					$CLEAR1
					echo "This option should support the cornucopia of different isos offered at"
					echo "https://sourceforge.net/projects/manjarolinux/files/community"
					echo
					echo "But beware, the script might fail at step 2 (unsquashing)"
					echo "if it does not recognize the right squashfsfile inside the iso"
					echo
					echo "Type (in lowercase) the desktop environment of your Manjaro iso below and hit enter:"
					echo
					read other_de
                                        SQUASHFSFILE=$other_de-image.sqfs
                                        USR="/usr"
                                        break
                                        ;;
				"Quit")
                                        exit 4
                                        ;;
				*) echo invalid option;;
			esac
		done
                break
            ;;
        "Fedora")
                DISTRO=fedora
                DISTRONAME=Fedora
                ROOTFS=rootfs.img
                SQUASHFSDIR=LiveOS
                SQUASHFSFILE=squashfs.img
                break
            ;;
        "Korora")
                DISTRO=fedora
                DISTRONAME=Korora
                ROOTFS=ext3fs.img
                SQUASHFSDIR=LiveOS
                SQUASHFSFILE=squashfs.img
                break
            ;;
        "Quit")
            exit 4
            ;;
        *) echo invalid option;;
    esac
done
}

##  LETS THE USER CHOOSE TO DIRECTLY COPY THE RESULTS TO A USB OR TO MAKE A ZIP (THAT CAN BE MANUALLY COPIED TO A USB STICK)
function ziporusb {
$CLEAR1
TEMPDIR=$(mktemp -d -p $CURRENTPATH)
echo
echo "Do you want to create a zip-file or a bootable USB ?"
PS3='Enter: '
echo
options=("Zip" "Usb" "Quit")
select opt in "${options[@]}"
do
    case $opt in
        "Zip")
		unzipiso
		if [ $DISTRO == "debian" ]; then
            addshit2debian
		else
            unsquash
            addshit2squash
            makesquash
        fi
		addshit2iso
		createzip
		break
            ;;
        "Usb")
		whichusb
		formatusb
		unzipiso
        if [ $DISTRO == "debian" ]; then
            addshit2debian
		else
            unsquash
            addshit2squash
            makesquash
		fi
		addshit2iso
		copytousb
		break
            ;;
        "Quit")
            exit 4
            ;;
        *) echo invalid option;;
    esac
done
}

function successfulzip {
$CLEAR1
removetempdir
dialog --colors --title "Success" --msgbox '\nDone creating the Live USB zip-file !\n\nRemember to run:\n\Zb/root/install-grub.sh\Zn\nafter installing linux\n\n(not necessary for *buntu)\n' 13 41
$CLEAR1
}

function successfulusb {
$CLEAR1
removetempdir
dialog --colors --title "Success" --msgbox '\nDone creating the Live USB !\n\nRemember to run:\n\Zb/root/install-grub.sh\Zn\nafter installing linux\n\n(not necessary for *buntu)\n' 13 32
$CLEAR1
}

function removetempdir {
SETTEMPDIR=${TEMPDIR:-}
if [ ! -z $SETTEMPDIR ]; then
rm -rf $SETTEMPDIR
fi
}

checkroot
checkfreespace
checkpartitiontype
checkprerequisites
zenityorparameter

if [ $OVERRIDE -eq "1" ];then
echo "Using overrides which you have set manually at the beginning of this script..."
sleep 5
else
whichdistro
fi

ziporusb

exit 0
