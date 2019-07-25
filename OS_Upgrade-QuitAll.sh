#!/bin/bash

# Written by: Balmes Pavlov
# 3/14/17
#
# 3/28/17 Edit: Updated for 10.12.4 compatibility. Added an additional exit codes and modified script to take into account which startosinstall command
# to use as Apple has modified the options in 10.12.4. Also added functions to reduce code re-use.
#
# 9/26/17 Edit: Updated for 10.13 compatibility. Cleaned up additional code logic. Added FV2 authenticated restart.
#
# This script is meant to be used with Jamf Pro.
# It will make sure of the macOS Sierra installer app along with some JSS script parameters and is intended to be somewhat easy to modify if used with future OS deployments.
#
# Required: Parameter $4 is for the required free space. Enter space in gigabytes such as 20. In this case, 20 would equal 20 gigabytes.
#
# Required: Parameter $5 is for the app name (e.g. macOS Sierra) which should hopefully allow some flexibility for the admin in case this script continues to work with the next macOS release.
#
# Required: Parameter $6 is for the time estimate in minutes. Type out the time in minutes.
#
# Optional: Parameter $7 is for the custom trigger name of a policy that should be used to deploy the macOS installer app.
# If you do not fill this in and the macOS installer app has not be installed on the computer, the script will exit and warn the user.
# You can opt to not use this parameter, but just make sure to deploy the macOS installer app through other means if that's the route you choose to take.
#
# Optional: Parameter $8 is used to provide a minimum OS version required to upgrade from. For example, you cannot upgrade to 10.12 on a computer running anything lower than 10.7.5.
# This is optional but if used it should be in the format of 10.7.5. Note: Some versions of macOS are written as 10.12. To verify, run this command in Terminal: sw_vers -productVersion
#
# Optional: Parameter $9 is used to determine if you want to check if iCloud Drive is enabled. Type "YES" (no quotes, case-insensitive) if you want to check otherwise leave blank.
# This script will check if iCloud Drive is in use. The reason for this is that macOS Sierra has a iCloud Documents sync feature which will upload documents to iCloud Drive.
# You may want the user to disable iCloud Drive and then push out a configuration profile to disable the iCloud Documents sync feature.
# This way when they re-enable iCloud Drive they do not have the option of possibly turning that specific feature on.
#
# Required: Parameter $10 is used to determine the full macOS installer app path. Enter the full path (e.g. /Users/Shared/Installer macOS Sierra.app)
#
# Optional: Parameter $11 is used to determine the minimum macOS installer app version just in case you want a specific version of the installer app on the computer.
# This comes in handy in situations where the computer might have the macOS 10.12.2 installer, but you want the 10.12.3 installer at minimum on the computer.
# Why? Apple may have released a specific feature (e.g. disable iCloud Doc Sync via config profile in 10.12.4+) that is in a newer minor update
# that you want to make use of immediately after computer has been upgraded.
#
# Variable 
#
# In case you want to examine why the script may have failed, I've provided exit codes.
# Exit Codes
# 1: Missing JSS parameters that are required.
# 2: Minimum required OS value has been provided and the client's OS version is lower.
# 3: Invalid OS version value. Must be in form of 10.12.4
# 4: No power source connected.
# 5: macOS Installer app is missing "InstallESD.dmg" & "startosinstall". Due to 1) bad path has been provided, 2) app is corrupt and missing two big components, or 3) app is not installed.
# 6: iCloud Drive is enabled. User must disable it.
# 7: Invalid value provided for free disk space.
# 8: The minimum OS version required for the macOS installer app version on the client is greater than the macOS installer on the computer.
# 9: The startosinstall exit code was not 0 which means there has been a failure in the OS upgrade.
# 10: The minimum OS version in macOS installer app has been supplied, but we were unable to mount the disk image to determine the OS version. Consider not providing a minimum OS version for macOS installer app.
# 11: Insufficient free space on computer.
# 12: Function parameter not supplied.
# 13: Could not determine the OS version in the macOS app installer. It's possible that in a future OS version that Apple may change their app installer and this script would need to be re-modified.
# 14: Remote users are logged into computer. Not secure when using FV2 Authenticated Restart.
# 15: FV2 Authenticated Restart is only supported on 10.9 and higher.
# 16: FV2 Status is not Encrypted.
# 17: Logged in user is not on the list of the FileVault enabled users.
# 18: Password mismatch. User may have forgotten their password.
# 19: FileVault error with fdesetup. Authenticated restart unsuccessful.
# 20: Failed to quit all applications before running the installer.


# Variables to determine paths, OS version, disk space, and power connection. Do not edit.
available_free_space=$(/bin/df -g / | /usr/bin/tail -1 | /usr/bin/awk '{print $4}')
os_major_ver="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d . -f 2)"
os_minor_ver="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d . -f 3)"
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
jamf="/usr/local/bin/jamf"
power_source=$(/usr/bin/pmset -g ps | /usr/bin/grep "Power")

# JSS Script Parameters
needed_free_space="${4}"
app_name="${5}"
time="${6}"
custom_trigger_policy_name="${7}"
min_req_os="${8}"
min_req_os_maj="$(/bin/echo "$min_req_os" | /usr/bin/cut -d . -f 2)"
min_req_os_min="$(/bin/echo "$min_req_os" | /usr/bin/cut -d . -f 3)"
icloud_check="${9}"
mac_os_installer_path="${10}"
#mac_os_install_ver="$(/usr/bin/defaults read "$mac_os_installer_path"/Contents/Info.plist CFBundleShortVersionString)"
base_os_ver="$(/usr/libexec/PlistBuddy -c "print :'System Image Info':version" "$mac_os_installer_path"/Contents/SharedSupport/InstallInfo.plist)"
min_os_app_ver="${11}"
base_os_maj="$(/bin/echo "$base_os_ver" | /usr/bin/cut -d . -f 2)"

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
icloud_icon="/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Resources/iCloud Drive.app/Contents/Resources/iCloudDrive.icns"

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

insufficient_free_space_for_install_dialog="Your boot drive must have $needed_free_space gigabytes of free space available in order to install $app_name. It currently has $available_free_space gigabytes free. Please free up space and try again. If you need assistance, please contact $it_contact."
adequate_free_space_for_install_dialog="$app_name is currently downloading. The installation process will begin once the download is complete. Please close all applications."
no_ac_power="The computer is not plugged into a power source. Please plug it into a power source and start the installation again."
inprogress="The upgrade to $app_name is now in progress.  Quit all your applications. The computer will restart automatically. You can step away for about $time minutes. Do not shutdown or unplug from power during this process."
disable_icloud="iCloud Drive enabled on this computer and the installation cannot continue. Please disable it by going to the Apple menu > System Preferences > iCloud and unchecking iCloud Drive. Once it’s disabled, please start the installation again. You can re-enable iCloud Drive after the upgrade is completed. If you need assistance, please contact $it_contact."
download_error="The download of macOS has failed. Installation will not proceed. Please contact $it_contact."
upgrade_error="The installation of macOS has failed. Please contact $it_contact."
bad_os="This version of macOS cannot be upgraded from the current operating system you are running. Please contact $it_contact."
generic_error="An unexpected error has occurred. Please contact $it_contact."
already_upgraded="Your computer is already upgraded to $app_name. If there is a problem or you have questions, please contact $it_contact."
forgot_password="You made too many incorrect password attempts. Please contact $it_contact."
fv_error="An unexpected error with Filevault has occurred. Please contact $it_contact."

# Function that ensures required variables have been set
# These are variables that if left unset will break the script and/or result in weird dialog messages.
# Function requires parameters $1 and $2. $1 is the variable to check and $2 is the variable name.
checkParam (){
if [[ -z "$1" ]]; then
    /bin/echo "\$$2 is empty and required. Please fill in the JSS parameter correctly."
    "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
    exit 1
fi
}

checkParam "$needed_free_space" "needed_free_space"
checkParam "$app_name" "app_name"
checkParam "$time" "time"
checkParam "$mac_os_installer_path" "mac_os_installer_path"

# Check for unsupported OS if a minimum required OS value has been provided. Note: macOS Sierra requires OS 10.7.5 or higher.
# Also confirm that we are dealing with a valid OS version which is in the form of 10.12.4
if [[ -n "$min_req_os" ]]; then
    if [[ "$min_req_os" =~ ^[0-9]+[\.]{1}[0-9]+[\.]{0,1}[0-9]*$ ]]; then
        if [[ "$os_major_ver" -lt "$min_req_os_maj" ]]; then
            /bin/echo "Unsupported Operating System. Cannot upgrade 10.$os_major_ver.$os_minor_ver to $min_req_os"
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Unsupported OS" -description "$bad_os" -button1 "Exit" -defaultButton 1
            exit 2
        elif [[ "$os_major_ver" == "$min_req_os_maj" ]] && [[ "$os_minor_ver" -lt "$min_req_os_min" ]]; then
            /bin/echo "Unsupported Operating System. Cannot upgrade 10.$os_major_ver.$os_minor_ver to $min_req_os"
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Unsupported OS" -description "$bad_os" -button1 "Exit" -defaultButton 1
            exit 2
        fi
    else
        /bin/echo "Invalid Minimum OS version value."
        "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 3
    fi
else
    /bin/echo "Minimum OS app version has not been supplied. Skipping check."
fi

# Check for Power Source
if [[ "$power_source" = "Now drawing from 'Battery Power'" ]] || [[ "$power_source" != *"AC Power"* ]]; then
    /bin/echo "$no_ac_power"
    "$jamfHelper" -windowType utility -icon "$lowbatteryicon" -heading "Connect to Power Source" -description "$no_ac_power" -button1 "Exit" -defaultButton 1 &
    exit 4
else
    /bin/echo "Power source connected to computer."
fi

# Function that uses Python's LooseVersion comparison module to compare versions
# Source: https://macops.ca/easy-version-comparisons-with-python
compareLooseVersion (){
    /usr/bin/python - "$1" "$2" << EOF
import sys
from distutils.version import LooseVersion as LV
print LV(sys.argv[1]) >= LV(sys.argv[2])
EOF
}

# Function to initiate prompt for FileVault Authenticated Restart
# Based off code from Elliot Jordan's script: https://github.com/homebysix/jss-filevault-reissue/blob/master/reissue_filevault_recovery_key.sh
fvAuthRestart (){

# Check for remote users.
REMOTE_USERS=$(who | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | wc -l)
if [[ $REMOTE_USERS -gt 0 ]]; then
    /bin/echo "Remote users are logged in. Cannot complete."
    "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
    exit 14
fi

# Convert POSIX path of logo icon to Mac path for AppleScript
filevaulticon="$(/usr/bin/osascript -e 'tell application "System Events" to return POSIX file "'"$filevaulticon"'" as text')"

# Most of the code below is based on the JAMF reissueKey.sh script:
# https://github.com/JAMFSupport/FileVault2_Scripts/blob/master/reissueKey.sh

# Check the OS version as FV2 authrestart was introduced in 10.8.3.
# However, we are expecting OS 10.9 or higher.
if [[ "$os_major_ver" -lt 8 && "$os_minor_ver" -lt 3 ]]; then
    /bin/echo "OS version does not support FV2 authenticated restart."
    "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
    exit 15
fi

# Check to see if the encryption process is complete
FV_STATUS="$(/usr/bin/fdesetup status)"
if grep -q "Encryption in progress" <<< "$FV_STATUS"; then
    /bin/echo "The encryption process is still in progress. Cannot do FV2 authenticated restart."
    /bin/echo "$FV_STATUS"
    "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
    exit 16
elif grep -q "FileVault is Off" <<< "$FV_STATUS"; then
    /bin/echo "Encryption is not active. Cannot do FV2 authenticated restart."
    /bin/echo "$FV_STATUS"
    "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
    exit 16
elif ! grep -q "FileVault is On" <<< "$FV_STATUS"; then
    /bin/echo "Unable to determine encryption status. Cannot do FV2 authenticated restart."
    /bin/echo "$FV_STATUS"
    "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
    exit 16
fi

# Get the logged in user's name
logged_in_user="$(/usr/bin/python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')"

# This first user check sees if the logged in account is already authorized with FileVault 2
fv_users="$(/usr/bin/fdesetup list)"
if ! egrep -q "^${logged_in_user}," <<< "$fv_users"; then
    /bin/echo "$logged_in_user is not on the list of FileVault enabled users:"
    /bin/echo "$fv_users"
    "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
    exit 17
fi

################################ MAIN PROCESS #################################

# Get information necessary to display messages in the current user's context.
user_id=$(id -u "$logged_in_user")
if [[ "$os_major_ver" -le 9 ]]; then
    l_id=$(pgrep -x -u "$user_id" loginwindow)
    l_method="bsexec"
elif [[ "$os_major_ver" -gt 9 ]]; then
    l_id=$user_id
    l_method="asuser"
fi

# Get the logged in user's password via a prompt.
/bin/echo "Prompting $logged_in_user for their Mac password..."
user_pw="$(/bin/launchctl "$l_method" "$l_id" /usr/bin/osascript -e 'display dialog "Please enter the password you use to log in to your Mac:" default answer "" with title "FileVault Authentication Restart" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer with icon file "'"${filevaulticon//\"/\\\"}"'"' -e 'return text returned of result')"

# Thanks to James Barclay (@futureimperfect) for this password validation loop.
TRY=1
until /usr/bin/dscl /Search -authonly "$logged_in_user" "$user_pw" &>/dev/null; do
    (( TRY++ ))
    /bin/echo "Prompting $logged_in_user for their Mac password (attempt $TRY)..."
    user_pw="$(/bin/launchctl "$l_method" "$l_id" /usr/bin/osascript -e 'display dialog "Sorry, that password was incorrect. Please try again:" default answer "" with title "FileVault Authentication Restart" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer with icon file "'"${filevaulticon//\"/\\\"}"'"' -e 'return text returned of result')"
    if (( TRY >= 5 )); then
        /bin/echo "Password prompt unsuccessful after 5 attempts."
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -heading "FileVault Authentication Error" -description "$forgot_password" -button1 "Exit" -defaultButton 1 &
        exit 18
    fi
done
/bin/echo "Successfully prompted for Filevault password."

# Translate XML reserved characters to XML friendly representations.
user_pw=${user_pw//&/&amp;}
user_pw=${user_pw//</&lt;}
user_pw=${user_pw//>/&gt;}
user_pw=${user_pw//\"/&quot;}
user_pw=${user_pw//\'/&apos;}

/bin/echo "Setting up authenticated restart..."
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
    /bin/echo "$FDESETUP_OUTPUT"
    /bin/echo "[WARNING] fdesetup exited with return code: $FDESETUP_RESULT."
    /bin/echo "See this page for a list of fdesetup exit codes and their meaning:"
    /bin/echo "https://developer.apple.com/legacy/library/documentation/Darwin/Reference/ManPages/man8/fdesetup.8.html"
    exit 19
else
    /bin/echo "$FDESETUP_OUTPUT"
    /bin/echo "Computer will do a FileVault 2 authenticated restart."
fi

return 0
}

# Function to download macOS installer
downloadOSInstaller (){
    if [[ -n "$custom_trigger_policy_name" ]]; then
        "$jamfHelper" -windowType hud -lockhud -heading 'macOS Sierra Upgrade (1 of 2)' -description "$adequate_free_space_for_install_dialog" -icon "$downloadicon" &
        JHPID=$(/bin/echo "$!")
        
        "$jamf" policy -event "$custom_trigger_policy_name" -verbose -randomDelaySeconds 0
        
        /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
    else
        /bin/echo "Warning: Custom Trigger field to download macOS installer is empty. Cannot download macOS installer. Please ensure macOS installer app is already installed on the client."
    fi
    
    return 0
}

# Function to check macOS installer app has been installed and if not re-download and do a comparison check between OS installer app version required
checkOSInstaller (){
    # Not the most accurate check but if the InstallESD.dmg and startosinstall binary are not available chances are the installer is no good.
    if [[ ! -e "$mac_os_installer_path/Contents/SharedSupport/InstallESD.dmg" ]] || [[ ! -e "$mac_os_installer_path/Contents/Resources/startosinstall" ]]; then
        /bin/echo "Cannot find $mac_os_installer_path. Clearing JAMF Downloads/Waiting Room in case there's a bad download and trying again."
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

# Disable case-sensitive matching for test comparison
shopt -s nocasematch

if [[ "$icloud_check" = "YES" ]]; then
    
    # Check for iCloud Drive status
    
    # Purpose: to grab iCloud Drive status.
    # If Drive has been setup previously then values should be: "false" or "true"
    # If Drive has NOT been setup previously then values will be: "iCloud Account Enabled, Drive Not Enabled" or "iCloud Account Disabled"
    # Unsupported operating systems will have value: "OS Not Supported"
    # Results will be displayed for each username to allow the end user to understand which account on the computer has iCloud Drive enabled (99% most likely their own account).
    
    # Determine if OS is 10.10 or greater as iCloud Drive is only available on 10.10+
    # Note: Even though iCloud Drive is available on 10.10, I do not have a 10.10 VM to test with
    
    if [[ "$os_major_ver" -lt "11" ]]; then
        /bin/echo "Cannot check for iCloud Drive on this OS."
    else
        # Variable used to store the search path used by the /usr/bin/dscl command.
        dsclSearchPath="/Local/Default" 
        
        # Array of all users
        ListOfUsers=($(/usr/bin/dscl "$dsclSearchPath" list /Users UniqueID | /usr/bin/awk '$2 > 500 { print $1 }'))
        
        # Function to look up iCloud Drive value for a user
        # Requires a parameter $1 which is the username to check on the computer.
        generate (){
            # Lookup the user's name from the local directory
            firstname=$(/usr/bin/dscl "$dsclSearchPath" -read /Users/"$1" RealName | /usr/bin/tr -d '\n' | /usr/bin/awk '{print $2}')
            lastname=$(/usr/bin/dscl "$dsclSearchPath" -read /Users/"$1" RealName | /usr/bin/tr -d '\n' | /usr/bin/awk '{print $3}')
            
            # Concatenate the full name together into one variable.
            UserFullName="$(/bin/echo $firstname $lastname)"
            
            # Determine user home directory
            HomeDirectory=$(/usr/bin/dscl "$dsclSearchPath" -read /Users/"$1" NFSHomeDirectory | /usr/bin/awk '{ print $2 }')
            
            # Path to PlistBuddy
            plistBud="/usr/libexec/PlistBuddy"
            
            # Determine whether user is logged into iCloud
            if [[ -e "$HomeDirectory/Library/Preferences/MobileMeAccounts.plist" ]]; then
                iCloudStatus=$("$plistBud" -c "print :Accounts:0:LoggedIn" $HomeDirectory/Library/Preferences/MobileMeAccounts.plist 2> /dev/null )
                
                # Determine whether user has enabled Drive enabled. Value should be either "false" or "true"
                if [[ "$iCloudStatus" = "true" ]]; then
                    if [[ "$os_major_ver" = "12" ]]; then
                        DriveStatus=$("$plistBud" -c "print :Accounts:0:Services:2:Enabled" $HomeDirectory/Library/Preferences/MobileMeAccounts.plist 2> /dev/null )
                        if [[ -z "$DriveStatus" ]]; then
                            DriveStatus="iCloud Account Enabled, Drive Not Enabled"
                        fi
                    fi
                    if [[ "$os_major_ver" = "11" ]]; then
                        DriveStatus=$("$plistBud" -c "print :Accounts:0:Services:0:Enabled" $HomeDirectory/Library/Preferences/MobileMeAccounts.plist 2> /dev/null )
                        if [[ -z "$DriveStatus" ]]; then
                            DriveStatus="iCloud Account Enabled, Drive Not Enabled"
                        fi
                    fi
                fi
                if [[ "$iCloudStatus" = "false" ]] || [[ -z "$iCloudStatus" ]]; then
                    DriveStatus="iCloud Account Disabled"
                fi
            else
                DriveStatus="iCloud Account Disabled"
            fi
            
            /bin/echo "$1 - $DriveStatus"
        }
        
        # Loop to check to see who has iCloud Drive enabled
        for username in ${ListOfUsers[@]}; do
            value="$(generate "$username")"
            if [[ "$value" =~ "true" ]]; then
                "$jamfHelper" -windowType utility -icon "$icloud_icon" -heading "iCloud must be disabled" -description "Username \"$username\" has $disable_icloud" -button1 "Exit" -defaultButton 1 &
                exit 1
            fi
        done
    fi
fi

# Re-enable case-sensitive matching
shopt -u nocasematch

# Check for to make sure free disk space required is a positive integer
if [[ ! "$needed_free_space" =~ ^[0-9]+$ ]]; then
    /bin/echo "Enter a positive integer value (no decimals) for free disk space required."
    "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
    exit 7
elif [[ "$available_free_space" -lt "$needed_free_space" ]]; then
    /bin/echo "$insufficient_free_space_for_install_dialog"
    "$jamfHelper" -windowType utility -icon "$driveicon" -heading "Insufficient Free Space" -description "$insufficient_free_space_for_install_dialog" -button1 "Exit" -defaultButton 1 &
    exit 11
else
    /bin/echo "$available_free_space gigabytes found as free space on boot drive. Proceeding with install."
fi

# Function to check if a required minimum macOS app installer has been supplied
minOSReqCheck (){
    # Check to see if minimum required app installer's OS version has been supplied
    if [[ -n "$min_os_app_ver" ]]; then
        if [[ "$min_os_app_ver" =~ ^[0-9]+[\.]{1}[0-9]+[\.]{0,1}[0-9]*$ ]]; then
            
            CompareResult="$(compareLooseVersion "$base_os_ver" "$min_os_app_ver")"
            
            if [[ "$CompareResult" = "False" ]]; then
                /bin/echo "Minimum required macOS installer app version is greater than the version of the macOS installer on the client."
                /bin/echo "Attempting to download the latest macOS installer."
                    downloadOSInstaller
                
                if [[ "$?" = 0 ]]; then
                    CompareResult="$(compareLooseVersion "$base_os_ver" "$min_os_app_ver")"
                    
                    if [[ "$CompareResult" = "False" ]]; then
                            /bin/echo "Looks like the download attempt failed."
                            /bin/echo "Minimum required macOS installer app version is still greater than the version on the client."
                            /bin/echo "Please install the macOS installer app version that meets the minimum requirement set."
                            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
                            exit 8
                    fi
                fi
            elif [[ "$CompareResult" = "True" ]]; then
                /bin/echo "Minimum required macOS installer app version is greater than the version on the client."
            fi
        else
            /bin/echo "Invalid Minimum OS version value."
            "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 3
        fi
    elif [[ -z "$min_os_app_ver" ]]; then
        /bin/echo "Minimum OS app version has not been supplied. Skipping check."
        return 1
    fi
    
    return 0
}

# Function that determines what OS is on the macOS installer.app so that the appropriate startosinstall options are used as Apple has changed it with 10.12.4
# Supply a parameter $1 for this function that includes the macOS app installer you are using to upgrade.
installCommand (){
   
    CompareResult="$(compareLooseVersion "$base_os_ver" 10.12.4)"
    
    # The startosinstall tool has been updated in 10.12.4 to remove --volume the flag
    if [[ "$CompareResult" = "True" ]]; then

        if [[ $base_os_maj -ge 13 ]]; then
            /bin/echo "The OS version in the macOS installer app version is greater than 10.13. Running appropriate startosinstall command to initiate install."
            # Initiate the macOS High Sierra silent install
            # 30 second delay should give the jamf binary enough time to upload policy results to JSS
            # Left this the same as the previous command in case you want to force upgrades to do APFS. Modify the next line by adding: --converttoapfs YES
            # If Apple's installer does not upgrade the Mac to APFS, assume something about your Mac does not pass the "upgrade to APFS" logic.
            "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path" --rebootdelay 30 --nointeraction &
        else
            /bin/echo "The OS version in the macOS installer app version is greater than 10.12.4 but lower than 10.13. Running appropriate startosinstall command to initiate install."
            # Initiate the macOS Sierra silent install (this will also work for High Sierra)
            # 30 second delay should give the jamf binary enough time to upload policy results to JSS
            "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path" --rebootdelay 30 --nointeraction &
        fi
    elif [[ "$CompareResult" = "False" ]]; then
        /bin/echo "The OS version in the macOS installer app version is less than 10.12.4. Running appropriate startosinstall command to initiate install."
        
        # Initiate the macOS Seirra silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path"  --volume / --rebootdelay 30 --nointeraction &
    fi
}

# Function that goes through the install
# Takes parameter $1 which is optional and is simply meant to add additional text to the jamfHelper header
installOS (){
    # Prompt for user password for FV Authenticated Restart
    if [[ "$(/usr/bin/fdesetup supportsauthrestart)" = "true" ]] && [[ "$os_major_ver" -ge 12 ]]; then
        if [[ "$(/usr/bin/fdesetup status | /usr/bin/grep "FileVault is On.")" ]]; then
            fvAuthRestart
        fi
    else
        /bin/echo "Either FileVault authenticated restart is not supported on this Mac or the OS is older than 10.12. Skipping FV authenticated restart."
    fi
    
    # Update message letting end-user know upgrade is going to start.
    "$jamfHelper" -windowType hud -lockhud -heading "macOS Sierra Upgrade $1" -description "$inprogress" -icon "$mas_os_icon" &
    
    # Get the Process ID of the last command
    JHPID=$(/bin/echo "$!")
    
    # Run the os installer command
    installCommand
    
    # The macOS install process successfully exits with code 0
    # On the off chance, the installer fails, let's warn the user
    if [[ $? != 0 ]]; then
         /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
        "$jamfHelper" -windowType utility -icon "$alerticon" -heading "Installation Failure" -description "$upgrade_error" -button1 "Exit" -defaultButton 1 &
        exit 9
    fi
    exit 0
}

# Prompt all running applications to quit before running the installer
exitCode=$(osascript <<EOD
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
    tell the current application to display dialog "We were unable to close all applications." & return & "Please save your work, close all applications, and try again." buttons {"Quit"} default button 1 with icon 0
	if button returned of result = "Quit" then
		set exitCode to "Quit"
	end if
end try
EOD)

#   If not all applications were closed properly, log comment and exit
if [ $exitCode == "Quit" ]; then
	/bin/echo "Unable to close all applications before running installer"
	exit 20
fi	


if [[ ! -e "$mac_os_installer_path" ]]; then
        downloadOSInstaller
    
    # Make sure macOS installer app is on computer
    if [[ ! -e "$mac_os_installer_path" ]]; then
        /bin/echo "Installer does not exist."
        checkOSInstaller
    fi
    
    minOSReqCheck
    
    installOS "(2 of 2)"
else
    checkOSInstaller
    
    minOSReqCheck
    
    installOS ""
fi

exit 0
