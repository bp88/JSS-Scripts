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
# 10/2/20 Edit: Updated for macOS 11 compatibility. Due to some issues, I had to comment out the quit all active apps function and code.
#               macOS 11 installer has changed enough that checking for expired certificates is not feasible like it was with prior installers.
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
# Optional: Parameter $9 is used to provide the contact email, number or name of the IT department for the end user to reach out to should issues arise.
# The phrase will be "Please contact <insert info from parameter 9>"
#
#
# In case you want to examine why the script may have failed, I've provided exit codes.
# Exit Codes
# 1: Missing JSS parameters that are required.
# 2: Minimum required OS value has been provided and the client's OS version is lower.
# 3: Invalid OS version value. Must be in form of 10.12.4
# 4: No power source connected.
# 5: macOS Installer app is missing "InstallESD.dmg" & "startosinstall". Due to 1) bad path has been provided, 2) app is corrupt and missing two big components, or 3) app is not installed.
# 6: macOS Installer app is missing Info.plist
# 7: Invalid value provided for free disk space.
# 8: The minimum OS version required for the macOS installer app version on the client is greater than the macOS installer on the computer.
# 9: The startosinstall exit code was not 0 or 255 which means there has been a failure in the OS upgrade. See log at: /var/log/installmacos_{timestamp}.log and /var/log/install.log and /var/log/system.log
# 11: Insufficient free space on computer.
# 14: Remote users are logged into computer. Not secure when using FV2 Authenticated Restart.
# 16: FV2 Status is either not Encrypted, in progress or something other than Off.
# 17: Logged in user is not on the list of the FileVault enabled users.
# 18: Password mismatch. User may have forgotten their password.
# 19: FileVault error with fdesetup. Authenticated restart unsuccessful.
# 20: Install package to run post-install during OS upgrade does not have a Product ID. Build distribution package using productbuild. More info: https://managingosx.wordpress.com/2017/11/17/customized-high-sierra-install-issues-and-workarounds/
# 21: CoreStorage conversion is in the middle of conversion. Only relevant on non-APFS. See results of: diskutil cs info /
# 22: Failed to unmount InstallESD. InstallESD.dmg may be mounted by the installer when it is launched through the GUI. However if you quit the GUI InstallAssistant, the app fails to unmount InstallESD which can cause problems on later upgrade attempts.
# 23: Expired certificate found in macOS installer app
# 24: Expired certificate found in one of packages inside macOS installer's InstallESD.dmg
# 25: Could not determine plist value. Plistbuddy returned an empty value.
# 26: Could not determine OS version in the app installer's base image.
# 27: Could not determine plist value. Plistbuddy is trying to read from a file that does not exist.
# 28: Could not mount SharedSupport.dmg
# 29: Could not read the mobile asset xml from the mounted SharedSupport.dmg
# 30: Could not read the OS version from the base image info.plist.
# 31: Invalid OS version value retrieved from the base image info.plist.

# Variables to determine paths, OS version, disk space, and power connection. Do not edit.
os_ver="$(/usr/bin/sw_vers -productVersion)"
os_major_ver="$(echo $os_ver | /usr/bin/cut -d . -f 1)"
os_minor_ver="$(echo $os_ver | /usr/bin/cut -d . -f 2)"
os_patch_ver="$(echo $os_ver | /usr/bin/cut -d . -f 3)"
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
approved_min_os_app_ver="${8}"
it_contact="${9}"
app_name="$(echo "$mac_os_installer_path" | /usr/bin/awk '{ gsub(/.*Install /,""); gsub(/.app/,""); print $0}')"
#mac_os_install_ver="$(/usr/bin/defaults read "$mac_os_installer_path"/Contents/Info.plist CFBundleShortVersionString)"

# Path to various icons used with JAMF Helper
# Feel free to adjust these icon paths
mas_os_icon="$mac_os_installer_path/Contents/Resources/InstallAssistant.icns"
downloadicon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericNetworkIcon.icns"
lowbatteryicon="/System/Library/CoreServices/PowerChime.app/Contents/Resources/battery_icon.png"
alerticon="/System/Library/CoreServices/Problem Reporter.app/Contents/Resources/ProblemReporter.icns"
filevaulticon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/FileVaultIcon.icns"

if [[ "$os_major_ver" -ge 11 ]]; then
    driveicon="/System/Library/PreferencePanes/StartupDisk.prefPane/Contents/Resources/StartupDisk.icns"
else
    driveicon="/System/Library/PreferencePanes/StartupDisk.prefPane/Contents/Resources/StartupDiskPref.icns"
fi

# iCloud icons may not be available on OS prior to 10.10.
# White iCloud icon
#icloud_icon="/System/Library/CoreServices/cloudphotosd.app/Contents/Resources/iCloud.icns"
# Blue iCloud icon
#icloud_icon="/System/Library/PrivateFrameworks/CloudDocsDaemon.framework/Versions/A/Resources/iCloud Drive.app/Contents/Resources/iCloudDrive.icns"

# Alternative icons
# driveicon="/System/Library/Extensions/IOSCSIArchitectureModelFamily.kext/Contents/Resources/USBHD.icns"
# lowbatteryicon="/System/Library/CoreServices/Menu Extras/Battery.menu/Contents/Resources/LowBattery.icns" # Last existed in 10.13
# lowbatteryicon="/System/Library/CoreServices/Installer Progress.app/Contents/Resources/LowBatteryEmpty.tiff"
# lowbatteryicon="/System/Library/PrivateFrameworks/EFILogin.framework/Versions/A/Resources/EFIResourceBuilder.bundle/Contents/Resources/battery_empty@2x.png"
# lowbatteryicon="/System/Library/PrivateFrameworks/EFILogin.framework/Versions/A/Resources/EFIResourceBuilder.bundle/Contents/Resources/battery_dead@2x.png"

# Messages for JAMF Helper to display
# Feel free to modify to your liking.
# Variables that you should edit.
# You can supply an email address or contact number for your end users to contact you. This will appear in JAMF Helper dialogs.
# If left blank, it will default to just "IT" which may not be as helpful to your end users.

if [[ -z "$it_contact" ]]; then
    it_contact="IT"
fi

download_in_progress_dialog="$app_name is currently downloading. The installation process will begin once the download is complete. Please close all applications."
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
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 1
    fi
}

checkPowerSource (){
    # Check for Power Source
    if [[ "$power_source" = "Now drawing from 'Battery Power'" ]] || [[ "$power_source" != *"AC Power"* ]]; then
        echo "$no_ac_power"
        "$jamfHelper" -windowType utility -icon "$lowbatteryicon" -title "Connect to Power Source" -description "$no_ac_power" -button1 "Exit" -defaultButton 1 &
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
    
    first_ver_maj="$(echo $first_ver | /usr/bin/cut -d . -f 1)"
    second_ver_maj="$(echo $second_ver | /usr/bin/cut -d . -f 1)"
    
    first_ver_min="$(echo $first_ver | /usr/bin/cut -d . -f 2)"
    [[ -z "$first_ver_min" ]] && first_ver_min="0"
    
    second_ver_min="$(echo $second_ver | /usr/bin/cut -d . -f 2)"
    [[ -z "$second_ver_min" ]] && second_ver_min="0"
    
    first_ver_patch="$(echo $first_ver | /usr/bin/cut -d . -f 3)"
    [[ -z "$first_ver_patch" ]] && first_ver_patch="0"
    
    second_ver_patch="$(echo $second_ver | /usr/bin/cut -d . -f 3)"
    [[ -z "$second_ver_patch" ]] && second_ver_patch="0"
    
    if [[ $first_ver_maj -gt $second_ver_maj ]] ||
       [[ $first_ver_maj -eq $second_ver_maj && $first_ver_min -ge $second_ver_min ]] ||
       [[ $first_ver_maj -eq $second_ver_maj && $first_ver_min -eq $second_ver_min && $first_ver_patch -gt $second_ver_patch ]]; then
        echo "True"
        return 0
    fi
    
    echo "False"
}

checkForPlistValue (){
    # Pass only 1 value
    # This function is meant to account for non-standard PlistBuddy behavior when sending output to 2>/dev/null
    # If path to plist does not exist, output will be: "File Doesn't Exist, Will Create: XXXXXXX"
    # If plist key does not exist, output will be empty.
    
    # Originally this function was meant to exit the script. However with bash, if this
    # function is called in a variable as part of a subprocess and an error is encountered
    # the script never exists like it's supposed to
    # This is why you see a lot of repeat code whenever this function is called.
    
    # Check to make sure only one value has been passed
    if [[ "$#" -ne 1 ]]; then
        echo "Pass only 1 value to checkForPlistValue function."
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        return 25
    fi
    
    value="${1}"
    
    if [[ -z "$value" ]]; then
        return 25
    elif [[ "$value" =~ "File Doesn't Exist, Will Create:" ]]; then
        return 27
    fi
}

# Function to initiate prompt for FileVault Authenticated Restart
# Based off code from Elliot Jordan's script: https://github.com/homebysix/jss-filevault-reissue/blob/master/reissue_filevault_recovery_key.sh
fvAuthRestart (){
    # Check for remote users.
    REMOTE_USERS=$(/usr/bin/who | /usr/bin/grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | /usr/bin/wc -l)
    if [[ $REMOTE_USERS -gt 0 ]]; then
        echo "Remote users are logged in. Cannot complete."
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -title "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
        exit 14
    fi
    
    # Convert POSIX path of logo icon to Mac path for AppleScript
    filevaulticon_as="$(/usr/bin/osascript -e 'tell application "System Events" to return POSIX file "'"$filevaulticon"'" as text')"
    
    # Most of the code below is based on the JAMF reissueKey.sh script:
    # https://github.com/JAMFSupport/FileVault2_Scripts/blob/master/reissueKey.sh
    
    # Check to see if the encryption process is complete
    fv_status="$(/usr/bin/fdesetup status)"
    
    # Write out FileVault status
    echo "FileVault Status: $fv_status"
    
    if grep -q "Encryption in progress" <<< "$fv_status"; then
        echo "The encryption process is still in progress. Cannot do FV2 authenticated restart."
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -title "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
        exit 16
    elif grep -q "FileVault is Off" <<< "$fv_status"; then
        echo "Encryption is not active. Cannot do FV2 authenticated restart. Proceeding with script."
        return 0
    elif ! grep -q "FileVault is On" <<< "$fv_status"; then
        echo "Unable to determine encryption status. Cannot do FV2 authenticated restart."
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -title "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 &
        exit 16
    fi
    
    # Check if user is logged in
    if [[ -z "$logged_in_user" ]]; then
        echo "No user is logged in. Cannot do FV2 authenticated restart. Proceeding with script."
        return 0
    fi
    
    # Check if the logged in account is an authorized FileVault 2 user
    fv_users="$(/usr/bin/fdesetup list)"
    if ! /usr/bin/egrep -q "^${logged_in_user}," <<< "$fv_users"; then
        echo "$logged_in_user is not on the list of FileVault enabled users:"
        echo "$fv_users"
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -title "FileVault Error" -description "$fv_error" -button1 "Exit" -defaultButton 1 -timeout 60 &
        exit 17
    fi
    
    # FileVault authenticated restart was introduced in 10.8.3
    # However prior to 10.12 it does not let you provide a value of "-1" to the option -delayminutes "-1"
    if [[ "$(/usr/bin/fdesetup supportsauthrestart)" != "true" ]] || [[ "$os_major_ver" -eq 10 && "$os_minor_ver" -lt 12 ]]; then
        echo "Either FileVault authenticated restart is not supported on this Mac or the OS is older than 10.12. Skipping FV authenticated restart."
        echo "User may need to authenticate on reboot. Letting them know via JamfHelper prompt."
        "$jamfHelper" -windowType utility -icon "$filevaulticon" -title "FileVault Notice" -description "$fv_proceed" -button1 "Continue" -defaultButton 1 -timeout 60 &
        return 1
    fi
    
    ################################ MAIN PROCESS #################################
    
    # Get information necessary to display messages in the current user's context.
    user_id=$(/usr/bin/id -u "$logged_in_user")
    if [[ "$os_major_ver" -eq 10 && "$os_minor_ver" -le 9 ]]; then
        l_id=$(/usr/bin/pgrep -x -u "$user_id" loginwindow)
        l_method="bsexec"
    elif [[ "$os_major_ver" -ge 11 || "$os_major_ver" -eq 10 && "$os_minor_ver" -gt 9 ]]; then
        l_id="$user_id"
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
            "$jamfHelper" -windowType utility -icon "$filevaulticon" -title "FileVault Authentication Error" -description "$forgot_password" -button1 "Exit" -defaultButton 1 &
            exit 18
        fi
    done
    echo "Successfully prompted for Filevault password."
    
    # Translate XML reserved characters to XML friendly representations.
    user_pw_xml=${user_pw//&/&amp;}
    user_pw_xml=${user_pw_xml//</&lt;}
    user_pw_xml=${user_pw_xml//>/&gt;}
    user_pw_xml=${user_pw_xml//\"/&quot;}
    user_pw_xml=${user_pw_xml//\'/&apos;}
    
    echo "Setting up authenticated restart..."
    FDESETUP_OUTPUT="$(/usr/bin/fdesetup authrestart -delayminutes -1 -verbose -inputplist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Username</key>
    <string>$logged_in_user</string>
    <key>Password</key>
    <string>$user_pw_xml</string>
</dict>
</plist>
EOF
)"
    
    # Test success conditions.
    fdesetup_result=$?
    
    # Clear password variable.
    unset user_pw_xml
    
    if [[ $fdesetup_result -ne 0 ]]; then
        echo "$FDESETUP_OUTPUT"
        echo "[WARNING] fdesetup exited with return code: $fdesetup_result."
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
        "$jamfHelper" -windowType hud -lockhud -title "$app_name (1 of 2)" -description "$download_in_progress_dialog" -icon "$downloadicon" &
        JHPID=$(echo "$!")
        
        "$jamf" policy -event "$custom_trigger_policy_name" -randomDelaySeconds 0
        
        if [[ $? -ne 0 ]]; then
            /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
            echo "Jamf policy did not complete successfully."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$download_error" -button1 "Exit" -defaultButton 1 &
            exit 25
        fi
        
        /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
    else
        echo "Warning: Custom Trigger field to download macOS installer is empty. Cannot download macOS installer. Please ensure macOS installer app is already installed on the client."
    fi
    
    return 0
}

redownloadOSInstaller (){
    echo "Clearing JAMF Downloads/Waiting Room in case there's a bad download and trying again."
    /bin/rm -rf "/Library/Application Support/JAMF/Downloads/"
    /bin/rm -rf "/Library/Application Support/JAMF/Waiting Room/"
    
    echo "Clearing $$mac_os_installer_path in case application path is incomplete."
    /bin/rm -rf "$mac_os_installer_path"
    
    downloadOSInstaller
    
    return $?
}

checkOSInstallerVersion (){
    installer_app_version="$(/usr/libexec/PlistBuddy -c "print :CFBundleShortVersionString" "$mac_os_installer_path"/Contents/Info.plist 2>/dev/null)"
    
    # Confirm that value returned by plistbuddy is valid
    checkForPlistValue "$installer_app_version"
    
    if [[ $? -eq 25 ]]; then
        echo "Plistbuddy returned an empty value."
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 25
    elif [[ $? -eq 27 ]]; then
        echo "Plistbuddy is trying to read from a file that does not exist."
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 27
    fi
    
    if [[ -z "$installer_app_version" ]]; then
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Download Failure" -description "$download_error" -button1 "Exit" -defaultButton 1 &
        exit 6
    fi
    
    echo "$installer_app_version"
}


# Function to check macOS installer app has been installed and if not re-download and do a comparison check between OS installer app version required
checkOSInstaller (){
    count=0
    
    # Loop through basic check to confirm full installer is on device
    # If installer components are missing, attempt to download installer again
    for i in {1..2}; do
        # For macOS 11, if the SharedSupport.dmg and startosinstall binary are not available chances are the installer is no good.
        if [[ ! -e "$mac_os_installer_path/Contents/SharedSupport/SharedSupport.dmg" ]] || [[ ! -e "$mac_os_installer_path/Contents/Resources/startosinstall" ]]; then
            ((count++))
        fi
        # For macOS 10.15 or lower, if the InstallESD.dmg and startosinstall binary are not available chances are the installer is no good.
        if [[ ! -e "$mac_os_installer_path/Contents/SharedSupport/InstallESD.dmg" ]] || [[ ! -e "$mac_os_installer_path/Contents/Resources/startosinstall" ]]; then
            ((count++))
        fi
        if [[ $count -eq $((2*$i)) ]]; then
            redownloadOSInstaller
        fi
    done
    
    if [[ $count -eq 4 ]]; then
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Download Failure" -description "$download_error" -button1 "Exit" -defaultButton 1 &
        exit 5
    fi
    
    return 0
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
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$cs_error" -button1 "Exit" -defaultButton 1 &
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
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 22
        fi
    fi
}

checkForFreeSpace (){
    # Set default value for $needed_free_space to 25GB
    [[ -z "$needed_free_space" ]] && local needed_free_space="25"
    
    available_free_space=$(/bin/df -g / | /usr/bin/awk '(NR == 2){print $4}')
    insufficient_free_space_for_install_dialog="Your boot drive must have $needed_free_space gigabytes of free space available in order to install $app_name. It currently has $available_free_space gigabytes free. Please free up space and try again. If you need assistance, please contact $it_contact."
    
    # Check for to make sure free disk space required is a positive integer
    if [[ ! "$needed_free_space" =~ ^[0-9]+$ ]]; then
        echo "Enter a positive integer value (no decimals) for free disk space required."
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 7
    fi
    
    # Checking for two conditions: 1) enough space to download the download installer, and
    # 2) the installer is on disk but there is not enough space for what the installer needs to proceed
    if [[ "$available_free_space" -lt 25 ]] || [[ "$available_free_space" -lt "$needed_free_space" ]]; then
        echo "$insufficient_free_space_for_install_dialog"
        "$jamfHelper" -windowType utility -icon "$driveicon" -title "Insufficient Free Space" -description "$insufficient_free_space_for_install_dialog" -button1 "Exit" -defaultButton 1 &
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

checkMinReqOSVer (){
    # Check to make sure the computer is running the minimum supported OS as determined by the OS installer. Note: macOS Sierra requires OS 10.7.5 or higher.
    # Also confirm that we are dealing with a valid OS version which is in the form of 10.12.4
    
    if [[ -n "$min_req_os" ]]; then
        if [[ "$min_req_os" =~ ^[0-9]+[\.]{1}[0-9]+[\.]{0,1}[0-9]*$ ]]; then
            if [[ "$(compareLooseVersion $os_ver $min_req_os)" == "False" ]]; then
                echo "Unsupported Operating System. Cannot upgrade $os_major_ver.$os_minor_ver.$os_patch_ver to $min_req_os"
                "$jamfHelper" -windowType utility -icon "$alerticon" -title "Unsupported OS" -description "$bad_os" -button1 "Exit" -defaultButton 1
                exit 2
            else
                echo "Computer meets the minimum required OS to upgrade. Proceeding."
            fi
        else
            echo "Invalid Minimum OS version value."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 3
        fi
    else
        echo "Minimum OS app version has not been supplied. Skipping check."
    fi
}

# Function to check if a required minimum macOS app installer has been supplied
meetsApprovedMinimumOSInstallerVersion (){
    if [[ "$approved_min_os_app_ver" =~ ^[0-9]+[\.]{1}[0-9]+[\.]{0,1}[0-9]*$ ]]; then
        CompareResult="$(compareLooseVersion "$base_os_ver" "$approved_min_os_app_ver")"
        
        if [[ "$CompareResult" = "False" ]]; then
            echo "The macOS installer app version is $base_os_ver. The system admin has set a minimum version requirement of $approved_min_os_app_ver for macOS installers."
            echo "Minimum required macOS installer app version is greater than the version of the macOS installer on the client."
            echo "Please install the macOS installer app version that meets the minimum requirement set."
            echo "Alternatively, you can modify or remove the minimum macOS installer app version requirement."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 8
        elif [[ "$CompareResult" = "True" ]]; then
            echo "Minimum required macOS installer app version is greater than the version on the client."
        fi
    else
        echo "Invalid Minimum OS version value."
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 3
    fi
}

# Function to check that the additional post-install package is available is a proper distribution-style package with a product id
validatePostInstallPKG (){
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
    
    if [[ $? -eq 0 ]]; then
        /bin/rm -rf /tmp/"$file_name"
        return 0
    else
        echo "Install package does not have a Product ID in its Distribution file. Build distribution package using productbuild."
        echo "Either use a proper distribution pkg with a product id or leave the Jamf parameter empty."
        /bin/rm -rf /tmp/"$file_name"
        exit 20
    fi
}


mountVolume (){
    # Pass 1 argument containing path to disk image to determine its volume name
    disk_image="${1}"
    
    # Mount volume
    /usr/bin/hdiutil attach -nobrowse -quiet "$disk_image"
    
    # Ensure DMG mounted successfully
    if [[ "$?" != 0 ]]; then
        echo "Unable to mount "$disk_image"."
        
        return 1
    fi
}

determineVolumeName (){
    # Pass 1 argument containing path to disk image to determine its volume name
    disk_image="${1}"
    
    # Determine the name of the mounted volume based on source image-path
    mounted_volumes=$(/usr/bin/hdiutil info -plist)
    
    finished="false"
    c=0
    i=0
    while [[ "$finished" == "false" ]]; do
        if [[ "$(/usr/libexec/PlistBuddy -c "print :images:"$c":image-path" /dev/stdin <<<$mounted_volumes 2>&1)" == *"Does Not Exist"* ]]; then
            finished="true"
        fi
        if [[ "$(/usr/libexec/PlistBuddy -c "print :images:"$c":image-path" /dev/stdin <<<$mounted_volumes 2>&1)" == "$disk_image" ]]; then
            while [[ "$finished" == "false" ]]; do
                if [[ "$(/usr/libexec/PlistBuddy -c "print :images:"$c":system-entities:"$i":mount-point" /dev/stdin <<<$mounted_volumes 2>&1)" == "/Volumes/"* ]]; then
                    mounted_volume_name="$(/usr/libexec/PlistBuddy -c "print :images:"$c":system-entities:"$i":mount-point" /dev/stdin <<<$mounted_volumes 2>&1)"
                    
                    # Confirm that value returned by plistbuddy is valid
                    checkForPlistValue "$mounted_volume_name"
                    
                    if [[ $? -eq 25 ]]; then
                        echo "Plistbuddy returned an empty value."
                        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
                        exit 25
                    elif [[ $? -eq 27 ]]; then
                        echo "Plistbuddy is trying to read from a file that does not exist."
                        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
                        exit 27
                    fi
                    
                    echo "$mounted_volume_name"
                    finished="true"
                else
                    i=$((i + 1))
                    # echo $i
                fi
            done
        else
            c=$((c + 1))
            # echo $c
        fi
    done
}


# Function to validate certificates of macOS installer app and the packages contained within InstallESD.pkg
# This function will only fail if a certificate is found and is found to be expired
validateAppExpirationDate (){
    # Function will only work on macOS installers lower than macOS 11/10.16 as the contents of the image that is laid down is different
    if [[ "$installer_app_major_ver" -ge 16 ]]; then
        echo "Skipping app expiration date validation as this macOS installer is running $installer_app_ver."
        return 0
    fi
    
    # Capture current directory to return back to it later
    current_dir="$(/bin/pwd)"
    
    # Setup temporary folder to extract certificates to since codesign does not let us specify an output path
    current_time="$(/bin/date +%s)"
    temp_path="/tmp/codesign_$current_time"
    /bin/mkdir -p "$temp_path"
    cd "$temp_path"
    
    # Extract certificates from app bundle
    /usr/bin/codesign -dvvvv --extract-certificates "$mac_os_installer_path"
    
    # Ensure we were able to extract certificates from installer app
    if [[ $? != 0 ]]; then
        echo "Could not extract certificates from $mac_os_installer_path"
        echo "Will proceed without validating contents of $mac_os_installer_path"
        return 1
    fi
    
    # Loop through all codesign files
    for code in $(/usr/bin/find "$temp_path" -iname codesign\* -mindepth 1); do
        # Analyze expiration date of certificate
        # Format of date e.g.: Apr 12 22:34:35 2021 GMT
        # Variable to extract expiration date
        expiration_date_string=$(/usr/bin/openssl x509 -enddate -noout -inform DER -in "$code" | /usr/bin/awk -F'=' '{print $2}' | /usr/bin/tr -s ' ')
        
        # Variable to convert expiration date string into epoch seconds
        expiration_date_epoch=$(/bin/date -jf "%b %d %H:%M:%S %Y %Z" "$expiration_date_string" +"%s")
        
        if [[ $expiration_date_epoch -lt $current_time ]]; then
            echo "A certificate for the installer application $mac_os_installer_path has expired. Please download a new macOS installer app with a valid certificate."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 23
        fi
        
        # Delete codesign file
        /bin/rm -f "$code"
    done
    
    echo "Certificates for the application $mac_os_installer_path are valid."
    echo "Proceeding to check certificates of packages inside InstallESD.dmg"
    
    # Potential statuses given by pkgutil --check-signature
    # Not all of these are checked against but leaving here for documentation purposes
    expired_pkgutil="Status: signed by a certificate that has since expired"
    valid_pkgutil="Status: signed by a certificate trusted by Mac OS X"
    untrusted_pkgutil="Status: signed by untrusted certificate"
    signed_pkgutil="Status: signed Apple Software"
    unsigned_pkgutil="Status: no signature"
    
    # Mount volume
    mountVolume "$mac_os_installer_path/Contents/SharedSupport/InstallESD.dmg"
    
    # Clean up if mount failed
    if [[ $? -ne 0 ]]; then
        echo "Unable to mount "$mac_os_installer_path"/Contents/SharedSupport/InstallESD.dmg to validate certificate."
        echo "Will proceed without validating contents of "$mac_os_installer_path"/Contents/SharedSupport/InstallESD.dmg."
        
        # Remove temporary working path
        /bin/rm -rf "$temp_path"
        
        # Return back to previous current directory
        cd "$current_dir"
        
        return 1
    fi
    
    # Determine the name of the mounted volume based on source image-path
    volume_name="$(determineVolumeName "$mac_os_installer_path/Contents/SharedSupport/InstallESD.dmg")"
    
    # Loop through all packages and determine if any of them have expired certificates
    IFS="
"
    for pkg in $(/usr/bin/find "$volume_name" -iname \*.pkg); do
        pkg_status="$(/usr/sbin/pkgutil --check-signature "$pkg" | /usr/bin/awk '/Status:/{gsub(/   /,""); print $0}')"
        if [[ "$pkg_status" == "$expired_pkgutil" ]]; then
            echo "$pkg has expired. Please download a new macOS installer with a valid certificate."
            
            # Remove temporary working path
            /bin/rm -rf "$temp_path"
            
            # Return back to previous current directory
            cd "$current_dir"
            
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 24
        fi
    done
    
    unset IFS
    
    # Unmount volume
    /usr/bin/hdiutil detach -force "$volume_name"
    
    # Remove temporary working path
    /bin/rm -rf "$temp_path"
    
    # Return back to previous current directory
    cd "$current_dir"
}


# Function that determines what OS is in the macOS installer.app so that the appropriate startosinstall options are used as Apple has changed it with 10.12.4
# Supply a parameter $1 for this function that includes the macOS app installer you are using to upgrade.
installCommand (){
#     disableInstallAssistantRestartPref
    
    JHPID="$1"
    install_log="$2"
    running_apple_silicon="$3"
    
    if [[ "$running_apple_silicon" == 1 ]]; then
        # Installer for macOS Big Sur introduce ability to pass credentials through new options
        # Required for authorizing installations on Apple Silicon and volume ownership
        # --user, an admin user to authorize installation.
        # --stdinpass, collect a password from stdin without interaction.
        
        if [[ -z "$user_pw" ]]; then
            # User ID of the logged in user
            user_id=$(/usr/bin/id -u "$logged_in_user")
            
            # Determine appropriate launchctl option to use
            if [[ "$os_major_ver" -eq 10 && "$os_minor_ver" -le 9 ]]; then
                l_id=$(/usr/bin/pgrep -x -u "$user_id" loginwindow)
                l_method="bsexec"
            elif [[ "$os_major_ver" -ge 11 || "$os_major_ver" -eq 10 && "$os_minor_ver" -gt 9 ]]; then
                l_id="$user_id"
                l_method="asuser"
            fi
            
            # Applescript path to macOS installer app icon
            mas_os_icon_as="$(/usr/bin/osascript -e 'tell application "System Events" to return POSIX file "'"$mas_os_icon"'" as text')"
            
            # Kill Jamf Helper window temporarily to avoid hiding upcoming AppleScript dialog
            /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
            
            # Get the logged in user's password via a prompt.
            echo "Prompting $logged_in_user for their Mac password..."
            
            user_pw="$(/bin/launchctl "$l_method" "$l_id" /usr/bin/osascript << EOF
            return text returned of (display dialog "Please enter the password for the account \"$logged_in_user\" you use to log in to your Mac:" default answer "" with title "macOS OS Install Authentication" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer with icon file "${mas_os_icon_as}")
EOF
            )"
            # Thanks to James Barclay (@futureimperfect) for this password validation loop.
            TRY=1
            until /usr/bin/dscl /Search -authonly "$logged_in_user" "$user_pw" &>/dev/null; do
                (( TRY++ ))
                echo "Prompting $logged_in_user for their Mac password (attempt $TRY)..."
                user_pw="$(/bin/launchctl "$l_method" "$l_id" /usr/bin/osascript -e 'display dialog "Sorry, that password was incorrect. Please try again:" default answer "" with title "macOS Install Authentication" giving up after 86400 with text buttons {"OK"} default button 1 with hidden answer with icon file "'"${mas_os_icon_as//\"/\\\"}"'"' -e 'return text returned of result')"
                if (( TRY >= 5 )); then
                    echo "Password prompt unsuccessful after 5 attempts."
                    "$jamfHelper" -windowType utility -icon "$alerticon" -title "Authentication Error" -description "$forgot_password" -button1 "Exit" -defaultButton 1 &
                    exit 18
                fi
            done
            echo "Successfully prompted for user password."
        fi
        
        vol_owner_options="--user $logged_in_user --stdinpass <<<$user_pw"
    fi
    
    # Make use install package
    [[ -e "$add_install_pkg" ]] && installpkg_option="--installpackage $add_install_pkg"
    
    # The startosinstall tool has been updated in various forms. The commands below take advantage of those updates.
    if [[ "$(compareLooseVersion $base_os_ver 11.0)" = True ]] && [[ "$running_apple_silicon" == "1" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to macOS 11. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Big Sur silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        # On Apple Silicon, the "--user" and either "--passprompt" or "--stdinpass" need to be used.
        # An attempt was made to use --stdinpass but that resulted in the password being logged in the install log due to use of /usr/bin/script
        # /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense ${installpkg_option} --forcequitapps --pidtosignal "$JHPID" --user "$logged_in_user" --stdinpass <<<"$user_pw"; echo "Exit Code:$?" >> "$install_log" &
        #
        # Settled on using an embedded Expect script so that the password can be passed interactively using --passprompt.
        /usr/bin/expect -d <(/bin/cat <<EOD
        # Disable timeout
        set timeout -1
        
        # Run startosinstall command via /usr/bin/script
        spawn /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense --forcequitapps ${installpkg_option} --pidtosignal "$JHPID" --user "$logged_in_user" --passprompt;
        
        # Look for "Password: " prompt
        expect ".*Password: "
        
        # Send password to interactive prompt
        send -- "$user_pw\n"
        
        # Allow startosinstall to finish running
        interact
        
        # Wait until the spawned process finishes and capture the exit code in variable $value
        lassign [wait] pid spawnid os_error_flag value
        
        # Exit with exit code value from spawned process
        exit "$value"
EOD
)
        # Capture exit code and send it to the install log
        echo "Exit Code:$?" >> "$install_log"
        
        # Clear password variable
        unset "$user_pw"
    elif [[ "$(compareLooseVersion $base_os_ver 11.0)" = True ]] && [[ "$running_apple_silicon" == "0" ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to macOS 11. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Big Sur silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense ${installpkg_option} --forcequitapps --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$install_log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.15)" = True ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.15. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Catalina silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense ${installpkg_option} --forcequitapps --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$install_log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.14)" = True ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.14. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Mojave silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --rebootdelay 30 --agreetolicense ${installpkg_option} --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$install_log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.13)" = True ]]; then
        echo "The embedded OS version in the macOS installer app is greater than or equal to 10.13. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS High Sierra silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        # Left this the same as the previous command in case you want to force upgrades to do APFS. Modify the next line by adding: --converttoapfs YES
        # If Apple's installer does not upgrade the Mac to APFS, assume something about your Mac does not pass the "upgrade to APFS" logic.
        /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path" --rebootdelay 30 --agreetolicense ${installpkg_option} --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$install_log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.12.4)" = True ]]; then
        echo "The OS version in the macOS installer app version is greater than 10.12.4 but lower than 10.13. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Sierra silent install (this will also work for High Sierra)
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path" --rebootdelay 30 --nointeraction --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$install_log" &
    elif [[ "$(compareLooseVersion $base_os_ver 10.12)" = True ]]; then
        echo "The OS version in the macOS installer app version is less than 10.12.4. Running appropriate startosinstall command to initiate install."
        # Initiate the macOS Seirra silent install
        # 30 second delay should give the jamf binary enough time to upload policy results to JSS
        /usr/bin/script -q -t 1 "$install_log" "$mac_os_installer_path/Contents/Resources/startosinstall" --applicationpath "$mac_os_installer_path"  --volume / --rebootdelay 30 --nointeraction --pidtosignal "$JHPID"; echo "Exit Code:$?" >> "$install_log" &
    else
        echo "The OS version in the macOS installer app version is less than 10.12. Running appropriate startosinstall command to initiate install."
    fi
    
#    deleteInstallAssistantRestartPref
}

# Function that goes through the install
# Takes parameter $1 which is optional and is simply meant to add additional text to the jamfHelper header
installOS (){
    heading="${1}"
    
    # Prompt for user password for FV authenticated restart if supported to avoid installation stalling at FV login window
    fvAuthRestart
    
    # Check for volume owners which is relevant for Macs running on Apple Silicon
    confirmVolumeOwner
    
    # Capture return on confirmVolumeOwner
    running_apple_silicon="$(echo $?)"
    
    # Update message letting end-user know upgrade is going to start.
    "$jamfHelper" -windowType hud -lockhud -title "$app_name$heading" -description "$inprogress" -icon "$mas_os_icon" -windowPosition  &
    
    # Get the Process ID of the last command
    JHPID=$(echo "$!")
    
    # Generate log name
    install_log="${installmacos_log}_$(/bin/date +%y%m%d%H%M%S)".log
    
    # Run the os installer command
    installCommand "$JHPID" "$install_log" "$running_apple_silicon"
    
    # The macOS install process successfully exits with code 0
    # On the off chance the installer fails, let's warn the user
    if [[ "$(/usr/bin/tail -n 1 $install_log | /usr/bin/cut -d : -f 2)" != 0 ]] && [[ "$(/usr/bin/tail -n 1 $install_log | /usr/bin/cut -d : -f 2)" != 255 ]]; then
        /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
        echo "startosinstall did not succeed. See log at: $install_log and /var/log/install.log and /var/log/system.log"
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Installation Failure" -description "$upgrade_error" -button1 "Exit" -defaultButton 1 &
        exit 9
    fi
    
    if [[ "$(/usr/bin/tail -n 2 $install_log | /usr/bin/head -n 1)" = "An error occurred installing macOS." ]] || [[ "$(/usr/bin/tail -n 2 $install_log | /usr/bin/head -n 1)" = "Helper tool crashed..." ]]; then
        /bin/kill -s KILL "$JHPID" > /dev/null 1>&2
        echo "startosinstall did not succeed. See log at: $install_log and /var/log/install.log and /var/log/system.log"
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Installation Failure" -description "$upgrade_error" -button1 "Exit" -defaultButton 1 &
        exit 9
    fi
    
    # Quit Self Service
    /usr/bin/killall "Self Service"
    
    # Create launch daemon to update inventory post-OS upgrade
    createReconAfterUpgradeLaunchDaemon
    
    # /sbin/shutdown -r now &
    
    exit 0
}

# Function to attempt to quit all active applications
# quitAllApps (){
#     # Prompt all running applications to quit before running the installer
#     if [[ -z "$logged_in_user" ]]; then
#         echo "No user is logged in. No apps to close."
#         return 0
#     fi
#     
#     # Get the user id of the logged in user
#     user_id=$(/usr/bin/id -u "$logged_in_user")
#     
#     if [[ "$os_major_ver" -eq 10 && "$os_minor_ver" -le 9 ]]; then
#         l_id=$(/usr/bin/pgrep -x -u "$user_id" loginwindow)
#         l_method="bsexec"
#     elif [[ "$os_major_ver" -ge 11 || "$os_major_ver" -eq 10 && "$os_minor_ver" -gt 9 ]]; then
#         l_id=$user_id
#         l_method="asuser"
#     fi
#     
#     exitCode="$(/bin/launchctl $l_method $l_id /usr/bin/osascript <<EOD
# tell application "System Events" to set the visible of every process to true
# set white_list to {"Finder", "Self Service"}
# try
#     tell application "Finder"
#         set process_list to the name of every process whose visible is true
#     end tell
#     repeat with i from 1 to (number of items in process_list)
#         set this_process to item i of the process_list
#         if this_process is not in white_list then
#             tell application this_process
#                 quit
#             end tell
#         end if
#     end repeat
# on error
#     tell the current application to display dialog "We were unable to close all applications." & return & "Please save your work and close all opened applications." buttons {"Try Again","Quit"} default button 1 with icon 0
#     if button returned of result = "Quit" then
#         set exitCode to "Quit"
#     else if button returned of result = "Try Again" then
#         set exitCode to "Try Again"
#     end if
# end try
# EOD)"
# 
#     If not all applications were closed properly, log comment and exit
#     if [[ "$exitCode" == "Quit" ]]; then
#         echo "Unable to close all applications before running installer"
#         exit 25
#     elif [[ "$exitCode" == "Try Again" ]]; then
#         Try to quit apps again
#         quitAllApps
#     fi
#     
#     return 0
# }

# Implement a self-deleting launch daemon to perform a Jamf Pro recon on first boot
createReconAfterUpgradeLaunchDaemon (){
    # This launch daemon will self-delete after successfully completing a Jamf recon
    # Launch Daemon Label and Path
    local launch_daemon="com.custom.postinstall.jamfrecon"
    local launch_daemon_path="/Library/LaunchDaemons/$launch_daemon".plist
    
    # Creating launch daemon
    echo "<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$launch_daemon</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/zsh</string>
		<string>-c</string>
		<string>/usr/local/bin/jamf recon &amp;&amp; /bin/rm -f /Library/LaunchDaemons/$launch_daemon.plist &amp;&amp; /bin/launchctl bootout system/$launch_daemon;</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>60</integer>
</dict>
</plist>" > "$launch_daemon_path"
    
    # Set proper permissions on launch daemon
    if [[ -e "$launch_daemon_path" ]]; then
        /usr/sbin/chown root:wheel "$launch_daemon_path"
        /bin/chmod 644 "$launch_daemon_path"
    fi
}

determineBaseOSVersion (){
    # This needs to be re-worked because of chances in the macOS 11 installer
    # Determine version of the OS included in the installer
    if [[ "$installer_app_major_ver" -ge 16 ]]; then
        # Variable to determine mount failure status
        mount_failure="false"
        
        # Mount volume
        /usr/bin/hdiutil attach -nobrowse -quiet "$mac_os_installer_path"/Contents/SharedSupport/SharedSupport.dmg
        
        # Determine whether SharedSupport.dmg was mounted
        if [[ $? -ne 0 ]]; then
            mount_failure="true"
            
            # Attempt a re-download of the OS installer
            redownloadOSInstaller
            
            # Attempt to mount volume one more time
            /usr/bin/hdiutil attach -nobrowse -quiet "$mac_os_installer_path"/Contents/SharedSupport/SharedSupport.dmg
            
            # Determine whether SharedSupport.dmg was mounted
            if [[ $? -ne 0 ]]; then
                mount_failure="true"
            else
                mount_failure="false"
            fi
        fi
        
        if [[ "$mount_failure" == "true" ]]; then
            echo "Failed to mount SharedSupport.dmg"
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 28
        fi
        
        # Path to mobile asset xml which contains path to zip containing base OS image
        mobile_asset_xml="/Volumes/Shared Support/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml"
        
        # Relative path to mobile asset
        mobile_asset="$(/usr/libexec/PlistBuddy -c "print :Assets:0:__RelativePath" "$mobile_asset_xml" 2>/dev/null)"
        
        if [[ $? -ne 0 ]]; then
            echo "Could not read mobile asset xml from SharedSupport.dmg."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 29
        fi
        
        # Confirm that value returned by plistbuddy is valid
        checkForPlistValue "$mobile_asset"
        
        if [[ $? -eq 25 ]]; then
            echo "Plistbuddy returned an empty value."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 25
        elif [[ $? -eq 27 ]]; then
            echo "Plistbuddy is trying to read from a file that does not exist."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 27
        fi
        
        # Path to base image zip
        base_image_zip="/Volumes/Shared Support/$mobile_asset"
        
        # Extract plist containing OS version to stdout
        #/usr/bin/unzip -j "$base_image_zip" "Info.plist" -d "/private/tmp"
        base_image_info_plist="$(/usr/bin/unzip -pj "$base_image_zip" "Info.plist")"
        
        # Determine base OS image version
        base_os_ver="$(/usr/libexec/PlistBuddy -c "print :MobileAssetProperties:OSVersion" /dev/stdin <<<"$base_image_info_plist" 2>/dev/null)"
        
        # Confirm that a value could be retrieved from plist
        if [[ $? -ne 0 ]]; then
            echo "Could not read the OS version from Info.plist within the base image zip: $base_image_zip."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 30
        fi
        
        # Confirm that a value containing a valid version could be retrieved from plist
        if [[ ! "$base_os_ver" =~ ^[0-9]+[\.]{1}[0-9]+[\.]{0,1}[0-9]*$ ]]; then
            echo "Invalid version value retrieved from Info.plist within the base image zip: $base_image_zip."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 31
        fi
        
        # Confirm that value returned by plistbuddy is valid
        checkForPlistValue "$base_os_ver"
        
        if [[ $? -eq 25 ]]; then
            echo "Plistbuddy returned an empty value."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 25
        elif [[ $? -eq 27 ]]; then
            echo "Plistbuddy is trying to read from a file that does not exist."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 27
        fi
        
        # Do not forget to detach and unmount volume
        # Determine volume name of disk image
        volume_name="$(determineVolumeName "$mac_os_installer_path"/Contents/SharedSupport/SharedSupport.dmg)"
        
        # Unmount volume
        /usr/bin/hdiutil detach -force "$volume_name" &>/dev/null
    else
        # Determine base OS image version
        base_os_ver="$(/usr/libexec/PlistBuddy -c "print :'System Image Info':version" "$mac_os_installer_path"/Contents/SharedSupport/InstallInfo.plist 2>/dev/null)"
        
        # Confirm that value returned by plistbuddy is valid
        checkForPlistValue "$base_os_ver"
        
        if [[ $? -eq 25 ]]; then
            echo "Plistbuddy returned an empty value."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 25
        elif [[ $? -eq 27 ]]; then
            echo "Plistbuddy is trying to read from a file that does not exist."
            "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
            exit 27
        fi
    fi
    
    # Ensure $base_os_ver is not empty
    if [[ -z "$base_os_ver" ]]; then
        echo "Could not determine OS version in the app installer's base image."
        "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
        exit 26
    fi
    
    echo "$base_os_ver"
}

confirmVolumeOwner (){
    logged_in_user_uuid="$(/usr/bin/dscl . read /Users/$logged_in_user GeneratedUID 2>/dev/null | /usr/bin/awk '{print $2}')"
    
    # Variable to determine architecture of Mac
    platform=$(/usr/bin/arch)
    
    # Variable to hold state on whether to proceed with install 0=no, 1=yes
    running_apple_silicon="0"
    
    # Exit if not running on Apple Silicon
    # Otherwise confirm that logged in user is volume owner
    if [[ "$platform" != "arm64" ]]; then
        echo "Architecture: $platform. No need to check for volume owners.</result>"
    else
        # Determine number of APFS users
        total_apfs_users=$(/usr/sbin/diskutil apfs listUsers / | /usr/bin/awk '/\+\-\-/ {print $2}' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
        
        # Get APFS User information in plist format
        apfs_users_plist=$(/usr/sbin/diskutil apfs listUsers / -plist)
        
        # Loop through all APFS Crypto Users to determine if logged in user is  volume owner
        for (( n=0; n<$total_apfs_users; n++ )); do
            # Determine APFS Crypto User UUID
            apfs_crypto_user_uuid=$(/usr/libexec/PlistBuddy -c "print :Users:"$n":APFSCryptoUserUUID" /dev/stdin <<<$apfs_users_plist)
            
            # Determine APFS Crypto User Type
            apfs_crypto_user_type=$(/usr/libexec/PlistBuddy -c "print :Users:"$n":APFSCryptoUserType" /dev/stdin <<<$apfs_users_plist)
            
            # Determine if APFS Crypto User is MDM Recovery/Bootstrap Token Key
            if [[ "$apfs_crypto_user_type" == "MDMRecovery" ]]; then
                echo "$apfs_crypto_user_uuid is the MDM Bootstrap Token External Key crypto user."
                # Maybe in the future, it may be useful to check against this crypto user type
            fi
            
            # Compare logged in user's uuid from list of APFS Crypto Users
            if [[ "$logged_in_user_uuid" == "$apfs_crypto_user_uuid" ]]; then
                # Determine volume owner status for APFS Crypto User
                user_volume_owner_status=$(/usr/libexec/PlistBuddy -c "print :Users:"$n":VolumeOwner" /dev/stdin <<<$apfs_users_plist)
                
                if [[ "$user_volume_owner_status" = true ]]; then
                    echo "Logged In User: $logged_in_user is a volumer owner."
                    running_apple_silicon="1"
                    break
                else
                    echo "Logged In User: $logged_in_user is not a volumer owner."
                    continue
                fi
                
                break
            else
                echo "no match"
                continue
            fi
        done
        
        if [[ "$running_apple_silicon" -eq "1" ]]; then
            echo "proceed with install"
        else
            echo "this install cannot take place. user is not a volume owner."
        fi
    fi
    
    echo "$running_apple_silicon"
    return "$running_apple_silicon"
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
    
    heading=" (2 of 2)"
    
    # Make sure macOS installer app is on computer
    if [[ ! -e "$mac_os_installer_path" ]]; then
        echo "An unsuccessfull attempt was made to download the macOS installer. Attempting to download again."
    fi
fi

checkOSInstaller

# Determine OS installer version
installer_app_ver="$(checkOSInstallerVersion)"

# Confirm that value returned by plistbuddy is valid
checkForPlistValue "$installer_app_ver"

if [[ $? -eq 25 ]]; then
    echo "Plistbuddy returned an empty value."
    "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
    exit 25
elif [[ $? -eq 27 ]]; then
    echo "Plistbuddy is trying to read from a file that does not exist."
    "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
    exit 27
fi


installer_app_major_ver="$(echo $installer_app_ver | /usr/bin/cut -d . -f 1)"
installer_app_minor_ver="$(echo $installer_app_ver | /usr/bin/cut -d . -f 2)"
installer_app_patch_ver="$(echo $installer_app_ver | /usr/bin/cut -d . -f 3)"

# Variables reliant on installer being on disk
min_req_os="$(/usr/libexec/PlistBuddy -c "print :LSMinimumSystemVersion" "$mac_os_installer_path"/Contents/Info.plist 2>/dev/null)"

# Confirm that value returned by plistbuddy is valid
checkForPlistValue "$min_req_os"

if [[ $? -eq 25 ]]; then
    echo "Plistbuddy returned an empty value."
    "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
    exit 25
elif [[ $? -eq 27 ]]; then
    echo "Plistbuddy is trying to read from a file that does not exist."
    "$jamfHelper" -windowType utility -icon "$alerticon" -title "Error" -description "$generic_error" -button1 "Exit" -defaultButton 1 &
    exit 27
fi


min_req_os_maj="$(echo "$min_req_os" | /usr/bin/cut -d . -f 1)"
min_req_os_min="$(echo "$min_req_os" | /usr/bin/cut -d . -f 2)"
min_req_os_patch="$(echo "$min_req_os" | /usr/bin/cut -d . -f 3)"
[[ -z "$min_req_os_patch" ]] && min_req_os_patch="0"
required_space="$(/usr/bin/du -hsg "$mac_os_installer_path/Contents/SharedSupport" | /usr/bin/awk '{print $1}')"
needed_free_space="$(($required_space * 4))"

# Run through a few post-download checks
checkForFreeSpace
checkMinReqOSVer
validateAppExpirationDate
checkForMountedInstallESD "/Volumes/InstallESD"
checkForMountedInstallESD "/Volumes/OS X Install ESD"
validatePostInstallPKG
# quitAllApps


if [[ -n "$approved_min_os_app_ver" ]]; then
    echo "Minimum OS app version has been supplied. Performing check."
    
    # Determine the OS version included in the OS installer app
    determineBaseOSVersion
    
    # Ensure the OS version included in the OS installer app is higher than the approved minimum OS version
    meetsApprovedMinimumOSInstallerVersion
fi

installOS "$heading"

exit 0