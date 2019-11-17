#!/bin/bash

# This script will reset printing system
# Build off work from http://www.cnet.com/news/what-does-the-reset-print-system-routine-in-os-x-do/
# and other posts on jamfnation.com
#
# For macOS 10.15, I recommend you use:
# /System/Library/Frameworks/ApplicationServices.framework/Frameworks/PrintCore.framework/Versions/A/printtool --reset

# Stop CUPS
/bin/launchctl stop org.cups.cupsd

# Backup Installed Printers Property List
if [[ -e "/Library/Printers/InstalledPrinters.plist" ]]; then
    /bin/mv /Library/Printers/InstalledPrinters.plist /Library/Printers/InstalledPrinters.plist.bak
fi

# Backup the CUPS config file
if [[ -e "/etc/cups/cupsd.conf" ]]; then
    /bin/mv /etc/cups/cupsd.conf /etc/cups/cupsd.conf.bak
fi

# Restore the default config by copying it
if [[ ! -e "/etc/cups/cupsd.conf" ]]; then
    /bin/cp /etc/cups/cupsd.conf.default /etc/cups/cupsd.conf
fi

# Backup the printers config file
if [[ -e "/etc/cups/printers.conf" ]]; then
    /bin/mv /etc/cups/printers.conf /etc/cups/printers.conf.bak
fi

# Start CUPS
/bin/launchctl start org.cups.cupsd

# Remove all printers
/usr/bin/lpstat -p | /usr/bin/cut -d' ' -f2 | /usr/bin/xargs -I{} /usr/sbin/lpadmin -x {}

exit 0