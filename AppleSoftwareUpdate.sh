#!/bin/bash

# This script is meant to be used with Jamf Pro and makes use of Jamf Helper.
# The idea behind this script is that it alerts the user that there are required OS
# updates that need to be installed. Rather than forcing updates to take place through the
# command line using "softwareupdate", the user is encouraged to use the GUI to update.
# In recent OS versions, Apple has done a poor job of testing command line-based workflows
# of updates and failed to account for scenarios where users may or may not be logged in.
# The update process through the GUI has not suffered from these kind of issues. The
# script will allow end users to postpone/defer updates X amount of times and then will
# give them one last change to postpone.
# This script should work rather reliably going back to 10.12 and maybe further, but at
# this point the real testing has only been done on 10.14.
# Please note, that this script does NOT cache updates in advance. The reason for this is
# that sometimes Apple releases updates that get superseded in a short time frame.
# This can result in downloaded updates that are in the /Library/Updates path that cannot
# be removed in 10.14+ due to System Integrity Protection.
#
# JAMF Pro Script Parameters:
# Parameter 4: Optional. Number of postponements allowed. Default: 3
# Parameter 5: Optional. Number of seconds dialog should remain up. Default: 900 seconds
#
# Here is the expected workflow with this script:
# If no user is logged in, the script will install updates through the command line and
#    shutdown/restart as required.
# If a user is logged in and there are updates that require a restart, the user will get
#    prompted to update or to postpone.
# If a user is logged in and there are no updates that require a restart, the updates will
#    get installed in the background (unless either Safari or iTunes are running.)
#
# There are a few exit codes in this script that may indicate points of failure:
# 11: No power source detected while doing CLI update.
# 12: Software Update failed.
# 13: FV encryption is still in progress.
# 14: Incorrect deferral type used.

# Potential feature improvement
# Allow user to postpone to a specific time with a popup menu of available times

###### ACTUAL WORKING CODE  BELOW #######
setDeferral (){
    # Notes: PlistBuddy "print" will print stderr to stdout when file is not found.
    #   File Doesn't Exist, Will Create: /path/to/file.plist
    # There is some unused code here with the idea that at some point in the future I can
    # extend functionality of this script to support hard and relative dates.
    BundleID="${1}"
    DeferralType="${2}"
    DeferralValue="${3}"
    DeferralPlist="${4}"

    if [[ "$DeferralType" == "date" ]]; then
        DeferralDate="$(/usr/libexec/PlistBuddy -c "print :$BundleID:date" "$DeferralPlist" 2>/dev/null)"
        # Set deferral date
        if [[ -n "$DeferralDate" ]] && [[ ! "$DeferralDate" =~ "File Doesn't Exist" ]]; then
            # /usr/libexec/PlistBuddy -c "set :$BundleID:date '07/04/2019 11:21:51 +0000'" "$DeferralPlist"
            /usr/libexec/PlistBuddy -c "set :$BundleID:date $DeferralValue" "$DeferralPlist" 2>/dev/null
        else
            # /usr/libexec/PlistBuddy -c "add :$BundleID:date date '07/04/2019 11:21:51 +0000'" "$DeferralPlist"
            /usr/libexec/PlistBuddy -c "add :$BundleID:date date $DeferralValue" "$DeferralPlist" 2>/dev/null
        fi
    elif [[ "$DeferralType" == "count" ]]; then
        DeferralCount="$(/usr/libexec/PlistBuddy -c "print :$BundleID:count" "$DeferralPlist" 2>/dev/null)"
        # Set deferral count
        if [[ -n "$DeferralCount" ]] && [[ ! "$DeferralCount" =~ "File Doesn't Exist" ]]; then
            /usr/libexec/PlistBuddy -c "set :$BundleID:count $DeferralValue" "$DeferralPlist" 2>/dev/null
        else
            /usr/libexec/PlistBuddy -c "add :$BundleID:count integer $DeferralValue" "$DeferralPlist" 2>/dev/null
        fi
    else
        echo "Incorrect deferral type used"
        exit 14
    fi
}


OSMajorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 2)"
OSMinorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 3)"
DeferralPlist="/Library/Application Support/JAMF/com.custom.deferrals.plist"
BundleID="com.apple.SoftwareUpdate"
DeferralType="count"
DeferralValue="${4}"

if [[ -z "$DeferralValue" ]]; then
    DeferralValue=3
fi

CurrentDeferralValue="$(/usr/libexec/PlistBuddy -c "print :$BundleID:count" "$DeferralPlist" 2>/dev/null)"

# Set up the deferral value if it does not exist already
if [[ -z "$CurrentDeferralValue" ]] || [[ "$CurrentDeferralValue" =~ "File Doesn't Exist" ]]; then
    setDeferral "$BundleID" "$DeferralType" "$DeferralValue" "$DeferralPlist"
    CurrentDeferralValue="$(/usr/libexec/PlistBuddy -c "print :$BundleID:count" "$DeferralPlist" 2>/dev/null)"
fi

jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
jamf="/usr/local/bin/jamf"
TimeOutinSec="${5}"

if [[ -z "$DeferralValue" ]]; then
    TimeOutinSec="900"
fi

# Path to temporarily store list of software updates. Avoids having to re-run the softwareupdate command multiple times.
ListOfSoftwareUpdates="/tmp/ListOfSoftwareUpdates"

#  Set appropriate Software Update icon depending on OS version
if [[ "$OSMajorVersion" -gt 13 ]]; then
    AppleSUIcon="/System/Library/CoreServices/Software Update.app/Contents/Resources/SoftwareUpdate.icns"
elif [[ "$OSMajorVersion" -eq 13 ]]; then
    AppleSUIcon="/System/Library/CoreServices/Install Command Line Developer Tools.app/Contents/Resources/SoftwareUpdate.icns"
elif [[ "$OSMajorVersion" -ge 8 ]] && [[ "$OSMajorVersion" -le 12 ]]; then
    AppleSUIcon="/System/Library/CoreServices/Software Update.app/Contents/Resources/SoftwareUpdate.icns"
elif [[ "$OSMajorVersion" -lt 8 ]]; then
    AppleSUIcon="/System/Library/CoreServices/Software Update.app/Contents/Resources/Software Update.icns"
fi

## Verbiage For Messages ##
# Message to guide user to Software Update process
if [[ "$OSMajorVersion" -ge 14 ]]; then
    #SUGuide="by clicking on the Apple menu, clicking System Preferences and clicking Software Update to install any available updates."
    SUGuide="by navigating to:

 > System Preferences > Software Update"
else
    #SUGuide="by opening up the App Store located in the Applications folder and clicking on the Updates tab to install any available updates."
    SUIGuide="by navigating to:

 > App Store > Updates tab"
fi

# Message to let user to contact IT
ITContact=""

if [[ -z "$ITContact" ]]; then
    ITContact="IT"
fi

ContactMsg="There seems to have been an error installing the updates. You can try again $SUGuide

If the error persists, please contact $ITContact."

# Message to display when computer is running off battery
no_ac_power="The computer is currently running off battery and is not plugged into a power source."

# Standard Update Message
StandardUpdatePrompt="There is an OS update available for your Mac. Please click Continue to proceed to Software Update to run this update. If you are unable to start the process at this time, you may choose to postpone by one day.

Attempts left to postpone: $CurrentDeferralValue

You may install macOS software updates at any time $SUGuide"

# Forced Update Message
ForcedUpdatePrompt="There are software updates available for your Mac that require you to restart. You have already postponed updates the maximum number of times.

Please save your work and click 'Update' otherwise this message will disappear and the computer will restart automatically."

# Message shown when running CLI updates
HUDMessage="Please save your work and quit all other applications. macOS software updates are being installed in the background. Do not turn off this computer during this time.

This message will go away when updates are complete and closing it will not stop the update process.

If you feel too much time has passed, please contact $ITContact

"

## Functions ##
powerCheck (){
    # This is meant to be used when doing CLI update installs.
    # Updates through the GUI can already determine its own requirements to proceed with
    # the update process.
    # Let's wait 5 minutes to see if computer gets plugged into power.
    for (( i = 1; i <= 5; ++i )); do
        if [[ "$(/usr/bin/pmset -g ps | /usr/bin/grep "Battery Power")" = "Now drawing from 'Battery Power'" ]]; then
            echo "$no_ac_power"
            /bin/sleep 60
        else
            return 0
        fi
    done
    exit 11
}


updateCLI (){
  # Install all software updates. If OS is > 10.13.4, use softwareupdate's restart option.
  if [[ "$OSMajorVersion" -eq 13 ]] && [[ "$OSMinorVersion" -ge 4 ]] || [[ "$OSMajorVersion" -ge 14 ]]; then
    /usr/sbin/softwareupdate -ia -R >> "$ListOfSoftwareUpdates" 2>&1 &
  else
    /usr/sbin/softwareupdate -ia >> "$ListOfSoftwareUpdates" 2>&1 &
  fi

    ## Get the Process ID of the last command run in the background ($!) and wait for it to complete (wait)
    # If you don't wait, the computer may take a restart action before updates are finished
    SUPID=$(echo "$!")

    wait $SUPID

    SU_EC=$?

    ShutdownRequired=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -E "halt|shut down" | /usr/bin/wc -l | /usr/bin/awk '{ print $1 }')

    echo $SU_EC

    return $SU_EC
}


updateRestartAction (){
    # On T2 hardware, we need to shutdown on certain updates
    if [[ "$ShutdownRequired" == "1" ]] && [[ "$SEPType" ]]; then
        if [[ "$OSMajorVersion" -eq 13 ]] && [[ "$OSMinorVersion" -ge 4 ]] || [[ "$OSMajorVersion" -ge 14 ]]; then
            /sbin/shutdown -h now
            exit 0
        fi
    fi
    # If no shutdown is required then let's go ahead and restart
    /sbin/shutdown -r now
    exit 0
}


updateGUI (){
    # Update through the GUI
    if [[ "$OSMajorVersion" -ge 14 ]]; then
        /usr/bin/open "/System/Library/CoreServices/Software Update.app"
    elif [[ "$OSMajorVersion" -ge 8 ]] && [[ "$OSMajorVersion" -le 13 ]]; then
        /usr/bin/open macappstore://showUpdatesPage
    fi
}


fvStatusCheck (){
    # Check to see if the encryption process is complete
    FVStatus="$(/usr/bin/fdesetup status)"
    if [[ $(/usr/bin/grep -q "Encryption in progress" <<< "$FVStatus") ]]; then
        echo "The encryption process is still in progress."
        echo "$FVStatus"
        exit 13
    fi
}


runUpdates (){
    "$jamfHelper" -windowType hud -lockhud -title "Apple Software Update" -description "$HUDMessage""START TIME: $(/bin/date +"%b %d %Y %T")" -icon "$AppleSUIcon" &>/dev/null &

    ## We'll need the pid of jamfHelper to kill it once the updates are complete
    JHPID=$(echo "$!")

    ## Run the jamf policy to insall software updates
    SU_EC="$(updateCLI)"

    ## Kill the jamfHelper. If a restart is needed, the user will be prompted. If not the hud will just go away
    /bin/kill -s KILL "$JHPID" &>/dev/null

    if [[ "$SU_EC" == 0 ]]; then
        updateRestartAction
    else
        echo "/usr/bin/softwareupdate failed. Exit Code: $SU_EC"

        "$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Apple Software Updates" -description "$ContactMsg" -button1 "OK"
        exit 12
    fi

    exit 0
}

# Function to do best effort check if using presentation or web conferencing is active
checkForDisplaySleepAssertions() {
    Assertions="$(/usr/bin/pmset -g assertions | /usr/bin/awk '/NoDisplaySleepAssertion | PreventUserIdleDisplaySleep/ && match($0,/\(.+\)/) && ! /coreaudiod/ {gsub(/^\ +/,"",$0); print};')"

    # There are multiple types of power assertions an app can assert.
    # These specifically tend to be used when an app wants to try and prevent the OS from going to display sleep.
    # Scenarios where an app may not want to have the display going to sleep include, but are not limited to:
    #   Presentation (KeyNote, PowerPoint)
    #   Web conference software (Zoom, Webex)
    #   Screen sharing session
    # Apps have to make the assertion and therefore it's possible some apps may not get captured.
    # Some assertions can be found here: https://developer.apple.com/documentation/iokit/iopmlib_h/iopmassertiontypes
    if [[ "$Assertions" ]]; then
        echo "The following display-related power assertions have been detected:"
        echo "$Assertions"
        echo "Exiting script to avoid disrupting user while these power assertions are active."

        exit 0
    fi
}

# Store list of software updates in /tmp which gets cleared periodically by the OS and on restarts
/usr/sbin/softwareupdate -l > "$ListOfSoftwareUpdates" 2>&1

UpdatesNoRestart=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep recommended | /usr/bin/grep -v restart | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//')
RestartRequired=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep restart | /usr/bin/grep -v '\*' | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//')

# Determine Secure Enclave version
SEPType="$(/usr/sbin/system_profiler SPiBridgeDataType | /usr/bin/awk -F: '/Model Name/ { gsub(/.*: /,""); print $0}')"

# Determine currently logged in user
#LoggedInUser=$(python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
LoggedInUser="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')"

# Let's make sure FileVault isn't encrypting before proceeding any further
fvStatusCheck

# If there are no system updates, reset timer and exit script
if [[ "$UpdatesNoRestart" == "" ]] && [[ "$RestartRequired" == "" ]]; then
    echo "No updates at this time."
    setDeferral "$BundleID" "$DeferralType" "$DeferralValue" "$DeferralPlist"
    exit 0
fi

# If we get to this point, there are updates available.
# If there is no one logged in, let's try to run the updates.
if [[ "$LoggedInUser" == "" ]]; then
    powerCheck
    updateCLI &>/dev/null
    updateRestartAction
else
    checkForDisplaySleepAssertions

    # Someone is logged in. Prompt if any updates require a restart ONLY IF the update timer has not reached zero
    if [[ "$RestartRequired" != "" ]]; then
        if [[ "$CurrentDeferralValue" -gt 0 ]]; then
            # Reduce the timer by 1. The script will run again the next day
            let CurrTimer=$CurrentDeferralValue-1
            setDeferral "$BundleID" "$DeferralType" "$CurrTimer" "$DeferralPlist"

            # If someone is logged in and they have not canceled $DeferralValue times already, prompt them to install updates that require a restart and state how many more times they can press 'cancel' before updates run automatically.
            HELPER=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Apple Software Updates" -description "$StandardUpdatePrompt" -button1 "Continue" -button2 "Postpone" -cancelButton "2" -defaultButton 2 -timeout "$TimeOutinSec")
            echo "Jamf Helper Exit Code: $HELPER"

            # If they click "Update" then take them to the software update preference pane
            if [ "$HELPER" == "0" ]; then
                updateGUI
            fi

            exit 0
        else
            HELPER=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Apple Software Update" -description "$ForcedUpdatePrompt" -button1 "Update" -defaultButton 1 -timeout "$TimeOutinSec" -countdown -alignCountdown "right")
            echo "Jamf Helper Exit Code: $HELPER"
            # If they click Install Updates then run the updates
            # Looks like someone tried to quit jamfHelper or the jamfHelper screen timed out
            # The Timer is already 0, run the updates automatically, the end user has been warned!
            if [[ "$HELPER" == "0" ]] || [[ "$HELPER" == "239" ]]; then
                runUpdates
            fi
        fi
    fi
fi

# Install updates that do not require a restart
# Future Fix: Might want to see if Safari and iTunes are running as sometimes these apps sometimes do not require a restart but do require that the apps be closed
# A simple stop gap to see if either process is running.
if [[ "$UpdatesNoRestart" != "" ]] && [[ ! "$(/bin/ps -axc | /usr/bin/grep -e Safari$)" ]] && [[ ! "$(/bin/ps -axc | /usr/bin/grep -e iTunes$)" ]]; then
    powerCheck
    updateCLI &>/dev/null
fi

exit 0
