#!/bin/bash

# Written by: Balmes Pavlov
# 3/28/17 Edit: Updated for 10.12.4 compatibility. Added an additional exit codes and modified script to take into account which startosinstall command
# to use as Apple has modified the options in 10.12.4. Also added functions to reduce code re-use.
#
# 9/26/17 Edit: Updated for 10.13 compatibility. Cleaned up additional code logic. Added FV2 authenticated restart.
#
# 2/27/19 Edit: Updated for 10.14 compatibility. Added support for additional packages. Added better logging of startosinstall failures by logging to /var/log/installmacos_<timestamp>.log. Removed iCloud checking.
#
# 3/27/19 Edit: Redirected some output that would appear in stdout. Resolved CoreStorage conversion detection. Made it explicit what user account is being asked for FV authentication.
#
# 10/28/19 Edit: Updated for 10.15 compatibility. Fixed an issue where variables were not being recalculated. Compartmentalized script further into functions. Reduced duplicate code where possible.
#               Added a few new features:
#               Function to quit all active apps (based on code from @dwshore: https://github.com/bp88/JSS-Scripts/pull/4#issue-301247270)
#               Function to check for expired certificates in the macOS installer app
#               Reduced the number of Jamf parameters required by capturing information from the macOS installer itself
#               Cleaned up documentation
#
# This script is meant to be used with Jamf Pro.
# It will make sure of the macOS Sierra, High Sierra, Mojave, or Catalina installer app along with some JSS script parameters and is intended to be somewhat easy to modify if used with future OS deployments.
# Required: Parameter $4 is used to determine the full macOS installer app path. Enter the full path (e.g. /Users/Shared/Installer macOS Sierra.app)
#
# Required: Parameter $5 is for the time estimate in minutes. Type out the time in minutes.
#
# Optional: Parameter $6 is for the custom trigger name of a policy that should be used to deploy the macOS installer app.
# If you do not fill this in and the macOS installer app has not be installed on the computer, the script will exit and warn the user.
# You can opt to not use this parameter, but just make sure to deploy the macOS installer app through other means if that's the route you choose to take.
#
# Optional: Parameter $7 is used if you want to add an additional install package to install after the OS upgrade completes.
# This is done through the "--installpackage" option which was introduced in the macOS High Sierra installer app.
# Read the following blog for more details on the caveats with this option: https://managingosx.wordpress.com/2017/11/17/customized-high-sierra-install-issues-and-workarounds/
#
# Optional: Parameter $8 is used to determine the minimum macOS installer app version just in case you want a specific version of the installer app on the computer.
# This comes in handy in situations where the computer might have the macOS 10.12.2 installer, but you want the 10.12.3 installer at minimum on the computer.
# Why? Apple may have released a specific feature (e.g. disable iCloud Doc Sync via config profile in 10.12.4+) that is in a newer minor update
# that you want to make use of immediately after computer has been upgraded.
#
#
# In case you want to examine why the script may have failed, I've provided exit codes.
# Exit Codes
# 1: Missing JSS parameters that are required.
# 2: Minimum required OS value has been provided and the client's OS version is lower.
# 3: Invalid OS version value. Must be in form of 10.12.4
# 4: No power source connected.
# 5: macOS Installer app is missing "InstallESD.dmg" & "startosinstall". Due to 1) bad path has been provided, 2) app is corrupt and missing two big components, or 3) app is not installed.
# 7: Invalid value provided for free disk space.
# 8: The minimum OS version required for the macOS installer app version on the client is greater than the macOS installer on the computer.
# 9: The startosinstall exit code was not 0 or 255 which means there has been a failure in the OS upgrade. See log at: /var/log/installmacos_{timestamp}.log and /var/log/install.log and /var/log/system.log
# 11: Insufficient free space on computer.
# 14: Remote users are logged into computer. Not secure when using FV2 Authenticated Restart.
# 16: FV2 Status is not Encrypted.
# 17: Logged in user is not on the list of the FileVault enabled users.
# 18: Password mismatch. User may have forgotten their password.
# 19: FileVault error with fdesetup. Authenticated restart unsuccessful.
# 20: Install package to run post-install during OS upgrade does not have a Product ID. Build distribution package using productbuild. More info: https://managingosx.wordpress.com/2017/11/17/customized-high-sierra-install-issues-and-workarounds/
# 21: CoreStorage conversion is in the middle of conversion. Only relevant on non-APFS. See results of: diskutil cs info /
# 22: Failed to unmount InstallESD. InstallESD.dmg may be mounted by the installer when it is launched through the GUI. However if you quit the GUI InstallAssistant, the app fails to unmount InstallESD which can cause problems on later upgrade attempts.
# 23: Expired certificate found in macOS installer app
# 24: Expired certificate found in one of packages inside macOS installer's InstallESD.dmg

# Variables to determine paths, OS version, disk space, and power connection. Do not edit.
os_major_ver="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d . -f 2)"
os_minor_ver="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d . -f 3)"
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
jamf="/usr/local/bin/jamf"
power_source=$(/usr/bin/pmset -g ps | /usr/bin/grep "Power")
installmacos_log="/var/log/installmacos"
logged_in_user="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')"

# JSS Script Parameters
mac_os_installer_path="${4}"
time="${5}"
custom_trigger_policy_name="${6}"
add_install_pkg="${7}"
min_os_app_ver="${8}"
app_name="$(echo "$mac_os_installer_path" | /usr/bin/awk '{ gsub(/.*Install macOS /,""); gsub(/.app/,""); print $0}')"
#mac_os_install_ver="$(/usr/bin/defaults read "$mac_os_installer_path"/Contents/Info.plist CFBundleShortVersionString)"

# Path to various icons used with JAMF Helper
# Feel free to adjust these icon paths
mas_os_icon="$mac_os_installer_path/Contents/Resources/InstallAssistant.icns"
downloadicon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericNetworkIcon.icns"
driveicon="/System/Library/PreferencePanes/StartupDisk.prefPane/Contents/Resources/StartupDiskPref.icns"
lowbatteryicon="/System/Library/CoreServices/Menu Extras/Battery.menu/Contents/Resources/LowBattery.icns"
alerticon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertCautionIcon.icns"
filevaulticon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FileVaultIcon.icns"

# iCloud icons may not be available on OS prior to 10.10.
# White iCloud icon
#icloud_icon="/System/Library/CoreServices/cloudphotosd.app/Contents/Resources/iCloud.icns"
# Blue iCloud icon
#icloud_icon="/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Resources/iCloud Drive.app/Contents/Resources/iCloudDrive.icns"

# Alternative Drive icon
#/System/Library/Extensions/IOSCSIArchitectureModelFamily.kext/Contents/Resources/USBHD.icns

# Messages for JAMF Helper to display
# Feel free to modify to your liking.
# Variables that you should edit.
# You can supply an email address or contact number for your end users to contact you. This will appear in JAMF Helper dialogs.
# If left blank, it will default to just "IT" which may not be as helpful to your end users.
it_contact="IT"

if [[ -z "$it_contact" ]]; then
    it_contact="IT"
fi

adequate_free_space_for_install_dialog="$app_name is currently downloading. The installation process will begin once the download is complete. Please close all applications."
no_ac_power="The computer is not plugged into a power source. Please plug it into a power source and start the installation again."
inprogress="The upgrade to $app_name is now in progress.  Quit all your applications. The computer will restart automatically and you may be prompted to enter your username and password. Once you have authenticated, you can step away for about $time minutes. Do not shutdown or unplug from power during this process."
download_error="The download of macOS has failed. Installation will not proceed. Please contact $it_contact."
upgrade_error="The installation of macOS has failed. If you haven't already, please try shutting down and powering back your computer, then try again. If failure persists, please contact $it_contact."
bad_os="This version of macOS cannot be upgraded from the current operating system you are running. Please contact $it_contact."
generic_error="An unexpected error has occurred. Please contact $it_contact."
already_upgraded="Your computer is already upgraded to $app_name. If there is a problem or you have questions, please contact $it_contact."
forgot_password="You made too many incorrect password attempts. Please contact $it_contact."
fv_error="An unexpected error with Filevault has occurred. Please contact $it_contact."
fv_proceed="Please wait until your computer has restarted as you may need to authenticate to let the installation proceed."
cs_error="An unexpected error with CoreStorage has occurred. Please contact $it_contact."

# Function that ensures required variables have been set
# These are variables that if left unset will break the script and/or result in weird dialog messages.
# Function requires parameters $1 and $2. $1 is the variable to check and $2 is the variable name.
checkParam (){
if [[ -z "$1" ]]; then
    echo "\$$2 is empty and required. Please fill in the JSS parameter correctly."
    "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
    exit 1
fi
}

checkPowerSource (){
# Check for Power Source
if [[ "$power_source" = "Now drawing from 'Battery Power'" ]] || [[ "$power_source" != *"AC Power"* ]]; then
    echo "$no_ac_power"
    "$jamfHelper" -windowType utility -icon "$lowbatteryicon" -heading "Connect to Power Source" -description "$no_ac_power" -button1 "Exit" -defaultButton 1 &
    exit 4
else
    echo "Power source connected to computer."
fi
}

# Function that uses Python's LooseVersion comparison module to compare versions
# Source: https://macops.ca/easy-version-comparisons-with-python
# compareLooseVersion (){
#     /usr/bin/python - "$1" "$2" << EOF
# import sys
# from distutils.version import LooseVersion as LV
# print LV(sys.argv[1]) >= LV(sys.argv[2])
# EOF
# }

# Function to compare macOS versions which usually come in the form of 10.12 or 10.12.3
compareLooseVersion (){
    first_ver="${1}"
    second_ver="${2}"
    
    first_ver_maj=$(echo $first_ver | /usr/bin/cut -d . -f 2)
    second_ver_maj=$(echo $second_ver | /usr/bin/cut -d . -f 2)
    
    first_ver_min=$(echo $first_ver | /usr/bin/cut -d . -f 3)
    [[ -z "$first_ver_min" ]] && first_ver_min="0"
    
    second_ver_min=$(echo $second_ver | /usr/bin/cut -d . -f 3)
    [[ -z "$second_ver_min" ]] && second_ver_min="0"
    
    if [[ $first_ver_maj -gt $second_ver_maj ]] || [[ $first_ver_maj -eq $second_ver_maj && $first_ver_min -ge $second_ver_min ]]; then
        echo "True"
        return 0
    fi
    
    echo "False"
}

# Function to initiate prompt for FileVault Authenticated Restart
# Based off code from Elliot Jordan's script: https://github.com/homebysix/jss-filevault-reissue/blob/master/reissue_filevault_recovery_key.sh
fvAuthRestart (){
    # Check for remote users.
    REMOTE_USERS=$(/usr/bin/who | /usr/bin/grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | /usr/bin/wc -l)
    if [[ $REMOTE_USERS -gt 0 ]]; then
        echo "Remote users are logged in. Cannot complete."
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
        exit 14
    fi
    
    # Convert POSIX path of logo icon to Mac path for AppleScript
    filevaulticon_as="$(/usr/bin/osascript -e 'tell application "System Events" to return POSIX file "'"$filevaulticon"'" as text')"
    
    # Most of the code below is based on the JAMF reissueKey.sh script:
    # https://github.com/JAMFSupport/FileVault2_Scripts/blob/master/reissueKey.sh
    
    # Check to see if the encryption process is complete
    fv_status="$(/usr/bin/fdesetup status)"
    if grep -q "Encryption in progress" <<< "$fv_status"; then
        echo "The encryption process is still in progress. Cannot do FV2 authenticated restart."
        echo "$fv_status"
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
        exit 16
    elif grep -q "FileVault is Off" <<< "$fv_status"; then
        echo "Encryption is not active. Cannot do FV2 authenticated restart."
        echo "$fv_status"
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
        exit 16
    elif ! grep -q "FileVault is On" <<< "$fv_status"; then
        echo "Unable to determine encryption status. Cannot do FV2 authenticated restart."
        echo "$fv_status"
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
        exit 16
    fi
    
    # Write out FileVault status
    echo "FileVault Status: $fv_status"
    
    # Get the logged in user's name
    logged_in_user="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')"
    
    # Check sees if the logged in account is an authorized FileVault 2 user
    fv_users="$(/usr/bin/fdesetup list)"
    if ! /usr/bin/egrep -q "^${logged_in_user}," <<< "$fv_users"; then
        echo "$logged_in_user is not on the list of FileVault enabled users:"
        echo "$fv_users"
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 -timeout 60 &
        exit 17
    fi
    
    # FileVault authenticated restart was introduced in 10.8.3
    # However prior to 10.12 it does not let you provide a value of "-1" to the option -delayminutes "-1"
    if [[ "$(/usr/bin/fdesetup supportsauthrestart)" != "true" ]] || [[ "$os_major_ver" -lt 12 ]]; then
        echo "Either FileVault authenticated restart is not supported on this Mac or the OS is older than 10.12. Skipping FV authenticated restart."
        echo "User may need to authenticate on reboot. Letting them know via JamfHelper prompt."
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Notice" -description "$fv_proceed" -button1 "Continue" -defaultButton 1 -timeout 60 &
        return 1
    fi
    
    ################################ MAIN PROCESS #################################
    
    # Get information necessary to display messages in the current user's context.
    user_id=$(/usr/bin/id -u "$logged_in_user")
    if [[ "$os_major_ver" -le 9 ]]; then
        l_id=$(pgrep -x -u "$user_id" loginwindow)
        l_method="bsexec"
    elif [[ "$os_major_ver" -gt 9 ]]; then
        l_id=$user_id
        l_method="asuser"
    fi
    
    # Get the logged in user's password via a prompt.
    echo "Prompting $logged_in_user for their Mac password..."
    #user_pw="$(/bin/launchctl "$l_method" "$l_id" /usr/bin/osascript -e 'display dialog "Please enter the password for the account you use to log in to your Mac:" default answer "" with title "FileVault Authentication Restart" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer with icon file "'"${filevaulticon_as//\"/\\\"}"'"' -e 'return text returned of result')"
    
    user_pw="$(/bin/launchctl "$l_method" "$l_id" /usr/bin/osascript << EOF
    return text returned of (display dialog "Please enter the password for the account \"$logged_in_user\" you use to log in to your Mac:" default answer "" with title "FileVault Authentication Restart" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer with icon file "${filevaulticon_as}")
    EOF
    )"
    # Thanks to James Barclay (@futureimperfect) for this password validation loop.
    TRY=1
    until /usr/bin/dscl /Search -authonly "$logged_in_user" "$user_pw" &>/dev/null; do
        (( TRY++ ))
        echo "Prompting $logged_in_user for their Mac password (attempt $TRY)..."
        user_pw="$(/bin/launchctl "$l_method" "$l_id" /usr/bin/osascript -e 'display dialog "Sorry, that password was incorrect. Please try again:" default answer "" with title "FileVault Authentication Restart" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer with icon file "'"${filevaulticon_as//\"/\\\"}"'"' -e 'return text returned of result')"
        if (( TRY >= 5 )); then
            echo "Password prompt unsuccessful after 5 attempts."
            "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Authentication Error" -description "$forgot_password" -button1 "Exit" -defaultButton 1 &
            exit 18
        fi
    done
    echo "Successfully prompted for Filevault password."
    
    # Translate XML reserved characters to XML friendly representations.
    user_pw=${user_pw//&/&amp;}
    user_pw=${user_pw//</&lt;}
    user_pw=${user_pw//>/&gt;}
    user_pw=${user_pw//\"/&quot;}
    user_pw=${user_pw//\'/&apos;}
    
    echo "Setting up authenticated restart..."
    FDESETUP_OUTPUT="$(/usr/bin/fdesetup authrestart -delayminutes -1 -verbose -inputplist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Username</key>
    <string>$logged_in_user</string>
    <key>Password</key>
    <string>$user_pw</string>
</dict>
</plist>
EOF
)"
    
    # Test success conditions.
    FDESETUP_RESULT=$?
    
    # Clear password variable.
    unset user_pw
    
    if [[ $FDESETUP_RESULT -ne 0 ]]; then
        echo "$FDESETUP_OUTPUT"
        echo "[WARNING] fdesetup exited with return code: $FDESETUP_RESULT."
        echo "See this page for a list of fdesetup exit codes and their meaning:"
        echo "https://developer.apple.com/legacy/library/documentation/Darwin/Reference/ManPages/man8/fdesetup.8.html"
        exit 19
    else
        echo "$FDESETUP_OUTPUT"
        echo "Computer will do a FileVault 2 authenticated restart."
    fi
    
    return 0
}

# Function to download macOS installer
downloadOSInstaller (){
    # Need to do an inventory update to make sure Jamf can put the computer in scope to initiate the download policy again
    "$jamf" recon
    
    if [[ -n "$custom_trigger_policy_name" ]]; then
        "$jamfHelper" -windowType hud -lockhud -heading "$app_name (1 of 2)" -description "$adequate_free_space_for_install_dialog" -icon "$downloadicon" &
        JHPID=$(echo "$!")
        
        "$jamf" policy -event "$custom_trigger_policy_name" -randomDelaySeconds 0
        
        /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
    else
        echo "Warning: Custom Trigger field to download macOS installer is empty. Cannot download macOS installer. Please ensure macOS installer app is already installed on the client."
    fi
    
    return 0
}

# Function to check macOS installer app has been installed and if not re-download and do a comparison check between OS installer app version required
checkOSInstaller (){
    # Not the most accurate check but if the InstallESD.dmg and startosinstall binary are not available chances are the installer is no good.
    if [[ ! -e "$mac_os_installer_path/Contents/SharedSupport/InstallESD.dmg" ]] || [[ ! -e "$mac_os_installer_path/Contents/Resources/startosinstall" ]]; then
        echo "Cannot find $mac_os_installer_path. Clearing JAMF Downloads/Waiting Room in case there's a bad download and trying again."
        /bin/rm -rf "/Library/Application Support/JAMF/Downloads/"
        /bin/rm -rf "/Library/Application Support/JAMF/Waiting Room/"
        
        downloadOSInstaller
        
        # Final check to see if macOS installer app is on computer
        if [[ ! -e "$mac_os_installer_path/Contents/SharedSupport/InstallESD.dmg" ]] || [[ ! -e "$mac_os_installer_path/Contents/Resources/startosinstall" ]]; then
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Download Failure" -description "$download_error" -button1 "Exit" -defaultButton 1 &
            exit 5
        fi
        
        return 0
    fi
}

# Check CoreStorage Conversion State
checkCSConversionState (){
    /usr/sbin/diskutil cs info / 2>/dev/null
    cs_status=$?
    
    if [[ "$cs_status" = 1 ]]; then
        echo "/ is not a CoreStorage disk. Proceeding."
        return 0
    fi
    
    if [[ "$(/usr/sbin/diskutil cs info / | /usr/bin/awk '/Conversion State:/ { print $3 }')" = "Converting" ]]; then
        echo "CoreStorage Conversion is in the middle of converting. macOS installer will fail in this state. Stopping upgrade."
        "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$cs_error" -button1 "Exit" -defaultButton 1 &
        exit 21
    fi
}

# If user previously opened install macOS app, it may have mounted InstallESD and not unmounted it.
checkForMountedInstallESD (){
    # Unmount InstallESD if mounted
    # In some circumstances when Install macOS.app is launched, it auto mounts but never unmounts when the app is closed.
    # This may cause errors in startosinstall which is why we need to unmount the disk image
    # Future note: re-write to check output from hdiutil info -plist / to see any mounted InstallESD volumes
    
    vol_name="${1}"
    
    if [[ -d "$vol_name" ]]; then
        /usr/bin/hdiutil detach -force "$vol_name"
        if [[ $? != 0 ]]; then
            echo "Failed to unmount $vol_name"
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 22
        fi
    fi
}

checkForFreeSpace (){
    # Check for to make sure free disk space required is a positive integer
    if [[ ! "$needed_free_space" =~ ^[0-9]+$ ]]; then
        echo "Enter a positive integer value (no decimals) for free disk space required."
        "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 7
    fi
    
    available_free_space=$(/bin/df -g / | /usr/bin/awk '(NR == 2){print $4}')
    
    # Checking for two conditions: 1) enough space to download the download installer, and
    # 2) the installer is on disk but there is not enough space for what the installer needs to proceed
    if [[ "$available_free_space" -lt 20 ]] || [[ "$available_free_space" -lt "$needed_free_space" ]]; then
        echo "$insufficient_free_space_for_install_dialog"
        "$jamfHelper" -windowType utility -icon "$driveicon" -heading "Insufficient Free Space" -description "$insufficient_free_space_for_install_dialog" -button1 "Exit" -defaultButton 1 &
        exit 11
    else
        echo "$available_free_space gigabytes found as free space on boot drive. Proceeding with install."
    fi
}

# From https://github.com/munki/munki/blob/master/code/client/munkilib/osinstaller.py 
# Set a secret preference to tell the osinstaller process to exit instead of restart
# this is the equivalent of:
# defaults write /Library/Preferences/.GlobalPreferences IAQuitInsteadOfReboot -bool YES
#
# This preference is referred to in a framework inside the Install macOS.app:
# Contents/Frameworks/OSInstallerSetup.framework/Versions/A/
#     Frameworks/OSInstallerSetupInternal.framework/Versions/A/
#     OSInstallerSetupInternal
# It might go away in future versions of the macOS installer.
disableInstallAssistantRestartPref (){
    /usr/bin/defaults write /Library/Preferences/.GlobalPreferences IAQuitInsteadOfReboot -bool YES
}

deleteInstallAssistantRestartPref (){
    /usr/bin/defaults delete /Library/Preferences/.GlobalPreferences IAQuitInsteadOfReboot
}

checkMinReqOSValue (){
    # Check for unsupported OS if a minimum required OS value has been provided. Note: macOS Sierra requires OS 10.7.5 or higher.
    # Also confirm that we are dealing with a valid OS version which is in the form of 10.12.4
    if [[ -n "$min_req_os" ]]; then
        if [[ "$min_req_os" =~ ^[0-9]+[\.]{1}[0-9]+[\.]{0,1}[0-9]*$ ]]; then
            if [[ "$os_major_ver" -lt "$min_req_os_maj" ]]; then
                echo "Unsupported Operating System. Cannot upgrade 10.$os_major_ver.$os_minor_ver to $min_req_os"
                "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Unsupported OS" -description "$bad_os" -button1 "Exit" -defaultButton 1
                exit 2
            elif [[ "$os_major_ver" -eq "$min_req_os_maj" ]] && [[ "$os_minor_ver" -lt "$min_req_os_min" ]]; then
                echo "Unsupported Operating System. Cannot upgrade 10.$os_major_ver.$os_minor_ver to $min_req_os"
                "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Unsupported OS" -description "$bad_os" -button1 "Exit" -defaultButton 1
                exit 2
            fi
        else
            echo "Invalid Minimum OS version value."
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 3
        fi
    else
        echo "Minimum OS app version has not been supplied. Skipping check."
    fi
}

# Function to check if a required minimum macOS app installer has been supplied
minOSReqCheck (){
    # Check to see if minimum required app installer's OS version has been supplied
    if [[ -n "$min_os_app_ver" ]]; then
        if [[ "$min_os_app_ver" =~ ^[0-9]+[\.]{1}[0-9]+[\.]{0,1}[0-9]*$ ]]; then
            
            CompareResult="$(compareLooseVersion "$(/usr/libexec/PlistBuddy -c "print :'System Image Info':version" "$mac_os_installer_path"/Contents/SharedSupport/InstallInfo.plist 2>/dev/null)" "$min_os_app_ver")"
            
            if [[ "$CompareResult" = "False" ]]; then
                echo "Minimum required macOS installer app version is greater than the version of the macOS installer on the client."
                echo "Attempting to download the latest macOS installer."
                downloadOSInstaller
                
                if [[ "$?" = 0 ]]; then
                    CompareResult="$(compareLooseVersion "$(/usr/libexec/PlistBuddy -c "print :'System Image Info':version" "$mac_os_installer_path"/Contents/SharedSupport/InstallInfo.plist 2>/dev/null)" "$min_os_app_ver")"
                    
                    if [[ "$CompareResult" = "False" ]]; then
                        echo "Looks like the download attempt failed."
                        echo "Minimum required macOS installer app version is still greater than the version on the client."
                        echo "Please install the macOS installer app version that meets the minimum requirement set."
                        "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
                        exit 8
                    fi
                fi
            elif [[ "$CompareResult" = "True" ]]; then
                echo "Minimum required macOS installer app version is greater than the version on the client."
            fi
        else
            echo "Invalid Minimum OS version value."
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 3
        fi
    fi
    
    echo "Minimum OS app version has not been supplied. Skipping check."
    
    return 0
}

# Function to check that the additional post-install package is available is a proper distribution-style package with a product id
checkPostInstallPKG (){
    if [[ -z "$add_install_pkg" ]]; then
        return 0
    elif [[ "$(compareLooseVersion 10.13 $base_os_ver)" = True ]] && [[ -n "$add_install_pkg" ]]; then
        echo "A post-OS upgrade install package was detected but the macOS installer does not support it so it won't be used."
        
        if [[ -e "$add_install_pkg" ]]; then
            /bin/rm -f "$add_install_pkg"
            echo "$add_install_pkg has been deleted."
        fi
        if [[ -e "$add_install_pkg".cache.xml ]]; then
            /bin/rm -f "$add_install_pkg".cache.xml
            echo "$add_install_pkg.cache.xml has been deleted."
        fi
        return 0
    fi
    
    file_name="$(echo "$add_install_pkg" | /usr/bin/awk -F / '{ print $NF }')"
    
    # Expand package to check that Distribution file includes a product id
    /usr/sbin/pkgutil --expand "$add_install_pkg" /tmp/"$file_name"
    
    # Check Distribution file for a product id
    /bin/cat /tmp/"$file_name"/Distribution | /usr/bin/grep "<product id=\"" &>/dev/null
    
    if [[ $? = 0 ]]; then
        /bin/rm -rf /tmp/"$file_name"
        return 0
    else
        echo "Install package does not have a Product ID in its Distribution file. Build distribution package using productbuild."
        echo "Either use a proper distribution pkg with a product id or leave the Jamf parameter empty."
        /bin/rm -rf /tmp/"$file_name"
        exit 20
    fi
}

# Function to validate certificates of macOS installer app and the packages contained within InstallESD.pkg
# This function will only fail if a certificate is found and is found to be expired
validateAppExpirationDate (){
    # Capture current directory to return back to it later
    current_dir="$(/bin/pwd)"
    
    # Setup temporary folder to extract certificates to since codesign does not let us specify an output path
    current_time="$(/bin/date +%s)"
    temp_path="/tmp/codesign_$current_time"
    /bin/mkdir -p "$temp_path"
    /usr/bin/cd "$temp_path"
    
    # Extract certificates from app bundle
    /usr/bin/codesign -dvvvv --extract-certificates "$mac_os_installer_path"
    
    # Ensure we were able to extract certificates from installer app
    if [[ $? != 0 ]]; then
        echo "Could not extract certificates from $mac_os_installer_path"
        echo "Will proceed without validating contents of $mac_os_installer_path"
        return 1
    fi
    
    # Loop through all codesign files
    for code in $(/usr/bin/find . -iname codesign\*); do
        # Analyze expiration date of certificate
        # Format of date e.g.: Apr 12 22:34:35 2021 GMT
        # Variable to extract expiration date
        expiration_date_string=$(/usr/bin/openssl x509 -enddate -noout -inform DER -in "$code" | /usr/bin/awk -F'=' '{print $2}' | /usr/bin/tr -s ' ')
        
        # Variable to convert expiration date string into epoch seconds
        expiration_date_epoch=$(/bin/date -jf "%b %d %H:%M:%S %Y %Z" "expiration_date_string" +"%s")
        
        if [[ $expiration_date_epoch -lt $current_time ]]; then
            echo "A certificate for the installer application $mac_os_installer_path has expired. Please download a new macOS installer app with a valid certificate."
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 23
        fi
    done
    
    # Potential statuses given by pkgutil --check-signature
    # Not all of these are checked against but leaving here for documentation purposes
    expired_pkgutil="Status: signed by a certificate that has since expired"
    valid_pkgutil="Status: signed by a certificate trusted by Mac OS X"
    untrusted_pkgutil="Status: signed by untrusted certificate"
    signed_pkgutil="Status: signed Apple Software"
    unsigned_pkgutil="Status: no signature"
    
    # Mount volume
    /usr/bin/hdiutil attach -nobrowse -quiet "$mac_os_installer_path"/Contents/SharedSupport/InstallESD.dmg -
    
    # Ensure DMG mounted successfully
    if [[ "$exit_status" != 0 ]]; then
        echo "Unable to mount "$mac_os_installer_path"/Contents/SharedSupport/InstallESD.dmg to validate certificate."
        echo "Will proceed without validating contents of "$mac_os_installer_path"/Contents/SharedSupport/InstallESD.dmg."
        return 1
    fi
    
    # Determine the name of the mounted volume based on source image-path
    mounted_volumes=$(/usr/bin/hdiutil info -plist)
    
    finished="false"
    c=0
    i=0
    while [[ "$finished" == "false" ]]; do
        if [[ "$(/usr/libexec/PlistBuddy -c "print :images:"$c":image-path" /dev/stdin <<<$mounted_volumes 2>&1)" == *"Does Not Exist"* ]]; then
            finished="true"
        fi
        if [[ "$(/usr/libexec/PlistBuddy -c "print :images:"$c":image-path" /dev/stdin <<<$mounted_volumes 2>&1)" == "$mac_os_installer_path/Contents/SharedSupport/InstallESD.dmg" ]]; then
            while [[ "$finished" == "false" ]]; do
                if [[ "$(/usr/libexec/PlistBuddy -c "print :images:"$c":system-entities:"$i":mount-point" /dev/stdin <<<$mounted_volumes 2>&1)" == "/Volumes/"* ]]; then
                    volume_name="$(/usr/libexec/PlistBuddy -c "print :images:"$c":system-entities:"$i":mount-point" /dev/stdin <<<$mounted_volumes 2>&1)"
                    echo "$volume_name"
                    finished="true"
                else
                    i=$((i + 1))
                    echo $i
                fi
            done
        else
            c=$((c + 1))
            echo $c
        fi
    done
    
    
    # Loop through all packages and determine if any of them have expired certificates
    IFS="
"
    for pkg in $(/usr/bin/find "$volume_name" -iname \*.pkg); do
        pkg_status="$(/usr/sbin/pkgutil --check-signature "$pkg" | /usr/bin/awk '/Status:/{gsub(/   /,""); print $0}')"
        if [[ "$pkg_status" == "$expired_pkgutil" ]]; then
            echo "$pkg has expired. Please download a new macOS installer with a valid certificate."
            exit 24
        fi
    done
    
    unset IFS
    
    # Unmount volume
    /usr/bin/hdiutil detach -force "$volume_name"
    
    # Remove temporary working path
    /bin/rm -rf "$temp_path"
    
    # Return back to previous current directory
    /usr/bin/cd "$current_dir"
}


# Function that determines what OS is in the macOS installer.app so that the appropriate startosinstall options are used as Apple has changed it with 10.12.4
# Supply a parameter $1 for this function that includes the macOS app installer you are using to upgrade.
installCommand (){
#     disableInstallAssistantRestartPref
    
    JHPID="$1"
    log="$2"
    
    # The startosinstall tool has been updated in various forms. The commands below take advantage of those updates.
    if [[ "$(compareLooseVersion $base_os_ver 10.15)" = True ]] && [[ ! -e "$add_install_pkg" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.15. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Catalina silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense --forcequitapps --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.15)" = True ]] && [[ -e "$add_install_pkg" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.15. Running appropriate startosinstall command to initiate install with an additional install package to run post-OS install."
        # Initiate the macOS Catalina silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense --installpackage "$add_install_pkg" --forcequitapps --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.14)" = True ]] && [[ ! -e "$add_install_pkg" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.14. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Mojave silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.14)" = True ]] && [[ -e "$add_install_pkg" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.14. Running appropriate startosinstall command to initiate install with an additional install package to run post-OS install."
        # Initiate the macOS Mojave silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense --installpackage "$add_install_pkg" --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.13)" = True ]] && [[ ! -e "$add_install_pkg" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.13. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS High Sierra silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        # Left this the same as the previous command in case you want to force upgrades to do APFS. Modify the next line by adding: --converttoapfs YES
        # If Apple's installer does not upgrade the Mac to APFS, assume something about your Mac does not pass the "upgrade to APFS" logic.
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path" --rebootdelay 30 --agreetolicense --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.13)" = True ]] && [[ -e "$add_install_pkg" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.13. Running appropriate startosinstall command to initiate install with an additional install package to run post-OS install."
        # Initiate the macOS High Sierra silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        # Left this the same as the previous command in case you want to force upgrades to do APFS. Modify the next line by adding: --converttoapfs YES
        # If Apple's installer does not upgrade the Mac to APFS, assume something about your Mac does not pass the "upgrade to APFS" logic.
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path" --rebootdelay 30 --nointeraction --installpackage "$add_install_pkg" --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.12.4)" = True ]]; then
        echo "The OS version in the macOS installer app version is greater than 10.12.4 but lower than 10.13. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Sierra silent install (this will also work for High Sierra)
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path" --rebootdelay 30 --nointeraction --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.12)" = True ]]; then
        echo "The OS version in the macOS installer app version is less than 10.12.4. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Seirra silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$log" "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path"  --volume / --rebootdelay 30 --nointeraction --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$log" &
    else
        echo "The OS version in the macOS installer app version is less than 10.12. Running appropriate startosinstall command to initiate install."
    fi
    
#    deleteInstallAssistantRestartPref
}

# Function that goes through the install
# Takes parameter $1 which is optional and is simply meant to add additional text to the jamfHelper header
installOS (){
    # Prompt for user password for FV authenticated restart if supported to avoid installation stalling at FV login window
    fvAuthRestart
    
    # Update message letting end-user know upgrade is going to start.
    "$jamfHelper" -windowType hud -lockhud -heading "$app_name $1" -description "$inprogress" -icon "$mas_os_icon" &
    
    # Get the Process ID of the last command
    JHPID=$(echo "$!")
    
    # Generate log name
    log="${installmacos_log}_$(/bin/date +%y%m%d%H%M%S)".log
    
    # Run the os installer command
    installCommand "$JHPID" "$log"
    
    # The macOS install process successfully exits with code 0
    # On the off chance, the installer fails, let's warn the user
    if [[ "$(/usr/bin/tail -n 1 $log | /usr/bin/cut -d : -f 2)" != 0 ]] && [[ "$(/usr/bin/tail -n 1 $log | /usr/bin/cut -d : -f 2)" != 255 ]]; then
        /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
        echo "startosinstall did not succeed. See log at: $log and /var/log/install.log and /var/log/system.log"
        "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Installation Failure" -description "$upgrade_error" -button1 "Exit" -defaultButton 1 &
        exit 9
    fi
    
    if [[ "$(/usr/bin/tail -n 2 $log | /usr/bin/head -n 1)" = "An error occurred installing macOS." ]] || [[ "$(/usr/bin/tail -n 2 $log | /usr/bin/head -n 1)" = "Helper tool crashed..." ]]; then
        /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
        echo "startosinstall did not succeed. See log at: $log and /var/log/install.log and /var/log/system.log"
        "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Installation Failure" -description "$upgrade_error" -button1 "Exit" -defaultButton 1 &
        exit 9
    fi
    
    # Quit Self Service
    /usr/bin/killall "Self Service"
    
    # /sbin/shutdown -r now &
    
    exit 0
}

quitAllApps (){
    # Prompt all running applications to quit before running the installer
    if [[ -z "$logged_in_user" ]]; then
        echo "No user is logged in. No apps to close."
        return 0
    fi
    
    # Get the user id of the logged in user
    user_id=$(/usr/bin/id -u "$logged_in_user")
    
    if [[ "$os_major_ver" -le 9 ]]; then
        l_id=$(pgrep -x -u "$user_id" loginwindow)
        l_method="bsexec"
    elif [[ "$os_major_ver" -gt 9 ]]; then
        l_id=$user_id
        l_method="asuser"
    fi
    
    exitCode="$(/bin/launchctl $l_method $l_id /usr/bin/osascript <<EOD
tell application "System Events" to set the visible of every process to true
set white_list to {"Finder", "Self Service"}
try
    tell application "Finder"
        set process_list to the name of every process whose visible is true
    end tell
    repeat with i from 1 to (number of items in process_list)
        set this_process to item i of the process_list
        if this_process is not in white_list then
            tell application this_process
                quit
            end tell
        end if
    end repeat
on error
    tell the current application to display dialog "We were unable to close all applications." & return & "Please save your work and close all opened applications." buttons {"Try Again","Quit"} default button 1 with icon 0
    if button returned of result = "Quit" then
        set exitCode to "Quit"
    else if button returned of result = "Try Again" then
        set exitCode to "Try Again"
    end if
end try
EOD)"

    # If not all applications were closed properly, log comment and exit
    if [[ "$exitCode" == "Quit" ]]; then
        echo "Unable to close all applications before running installer"
        exit 25
    elif [[ "$exitCode" == "Try Again" ]]; then
        # Try to quit apps again
        quitAllApps
    fi
    
    return 0
}


# Run through a few pre-download checks
checkParam "$time" "time"
checkParam "$mac_os_installer_path" "mac_os_installer_path"
checkPowerSource
checkCSConversionState
checkForFreeSpace

# Ensure that macOS installer app is downloaded
if [[ ! -e "$mac_os_installer_path" ]]; then
    downloadOSInstaller
    
    heading="(2 of 2)"
    
    # Make sure macOS installer app is on computer
    if [[ ! -e "$mac_os_installer_path" ]]; then
        echo "An unsuccessfull attempt was made to download the macOS installer. Attempting to download again."
    fi
fi

checkOSInstaller

# Variables reliant on installer being on disk
min_req_os="$(/usr/libexec/PlistBuddy -c "print :LSMinimumSystemVersion" "$mac_os_installer_path"/Contents/Info.plist 2>/dev/null)"
min_req_os_maj="$(echo "$min_req_os" | /usr/bin/cut -d . -f 2)"
min_req_os_min="$(echo "$min_req_os" | /usr/bin/cut -d . -f 3)"
available_free_space=$(/bin/df -g / | /usr/bin/awk '(NR == 2){print $4}')
required_space="$(/usr/bin/du -hsg "$mac_os_installer_path/Contents/SharedSupport" | /usr/bin/awk '{print $1}')"
needed_free_space="$(($required_space * 4))"
base_os_ver="$(/usr/libexec/PlistBuddy -c "print :'System Image Info':version" "$mac_os_installer_path"/Contents/SharedSupport/InstallInfo.plist 2>/dev/null)"
base_os_maj="$(echo "$base_os_ver" | /usr/bin/cut -d . -f 2)"
insufficient_free_space_for_install_dialog="Your boot drive must have $needed_free_space gigabytes of free space available in order to install $app_name. It currently has $available_free_space gigabytes free. Please free up space and try again. If you need assistance, please contact $it_contact."

# Run through a few post-download checks
checkForFreeSpace
checkMinReqOSValue
validateAppExpirationDate
checkForMountedInstallESD "/Volumes/InstallESD"
checkForMountedInstallESD "/Volumes/OS X Install ESD"
checkPostInstallPKG
quitAllApps

minOSReqCheck

installOS "$heading"

exit 0