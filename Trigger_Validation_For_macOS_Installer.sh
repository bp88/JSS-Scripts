#!/bin/bash

# As part Gatekeeper, macOS runs a code signature validation scan on all apps when they
# are run the first time. This results in some really large apps taking 2-3 minutes
# before they can run. Some apps include: Xcode, Matlab, Mathematica, etc.
#
# The macOS installer app for Big Sur suffers from this and as a result if you try to
# run the "install macOS Big Sur.app" it will ultimately take 2 minutes or more while it scans.
# If you run the app through the GUI, the app will simply bounce in the dock.
# If you run the app through the CLI using "startosinstall", it will show no activity until the scan completes.
# There's no way to force macOS to scan a particular app for its code signature validation
# other than actually trying to run it.
#
# The below code is meant to be used as a workaround by triggering the --usage option
# in "startosinstall" which does not actually run an upgrade.
# macOS will start to scan "Install macOS Big Sur.app" silently in the background
#
# This code is designed to run immediately after "Install macOS Big Sur.app" has been
# installed. The idea is to make the user experience better so that when the user launches
# an OS upgrade whether through the GUI or a Self Service workflow relying on "startosinstall"
# there's no a 2-3 minute period of silence.
#
# File feedback with Apple so that they can improve this experience and macOS installer
# apps can be scanned immediately after install.
#
# This script makes use of Jamf Pro script parameters:
# Parameter 4: supply the full path to the installer (e.g. /Applications/Install macOS Big Sur.app)

# Path to macOS installer app
mac_os_installer_path="${4}"

if [[ -e "$mac_os_installer_path" ]]; then
    "$mac_os_installer_path"/Contents/Resources/startosinstall --usage &>/dev/null
fi

exit 0