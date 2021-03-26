#!/bin/zsh

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
# Parameter 6: Optional. Number of seconds dialog should remain up for Apple Silicon Macs.
#              Provides opportunity for user to perform update via Software Update
#              preference pane. Default: 1 hour
# Parameter 7: Optional. Contact email, number, or department name used in messaging.
#              Default: IT
# Parameter 8: Optional. Set your own custom icon. Default is Apple Software Update icon.
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
# 15: Insufficient space to perform update.

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
        DeferralDate="$(/usr/libexec/PlistBuddy -c "print :"$BundleID":date" "$DeferralPlist" 2>/dev/null)"
        # Set deferral date
        if [[ -n "$DeferralDate" ]] && [[ ! "$DeferralDate" == *"File Doesn't Exist"* ]]; then
            # PlistBuddy command example
            # /usr/libexec/PlistBuddy -c "set :"$BundleID":date '07/04/2019 11:21:51 +0000'" "$DeferralPlist"
            /usr/libexec/PlistBuddy -c "set :"$BundleID":date $DeferralValue" "$DeferralPlist" 2>/dev/null
        else
            # PlistBuddy command example
            # /usr/libexec/PlistBuddy -c "add :"$BundleID":date date '07/04/2019 11:21:51 +0000'" "$DeferralPlist"
            /usr/libexec/PlistBuddy -c "add :"$BundleID":date date $DeferralValue" "$DeferralPlist" 2>/dev/null
        fi
    elif [[ "$DeferralType" == "count" ]]; then
        DeferralCount="$(/usr/libexec/PlistBuddy -c "print :"$BundleID":count" "$DeferralPlist" 2>/dev/null)"
        # Set deferral count
        if [[ -n "$DeferralCount" ]] && [[ ! "$DeferralCount" == *"File Doesn't Exist"* ]]; then
            /usr/libexec/PlistBuddy -c "set :"$BundleID":count $DeferralValue" "$DeferralPlist" 2>/dev/null
        else
            /usr/libexec/PlistBuddy -c "add :"$BundleID":count integer $DeferralValue" "$DeferralPlist" 2>/dev/null
        fi
    else
        echo "Incorrect deferral type used"
        exit 14
    fi
}

# Set path where deferral plist will be placed
DeferralPlistPath="/Library/Application Support/JAMF"
[[ ! -d "$DeferralPlistPath" ]] && /bin/mkdir -p "$DeferralPlistPath"

OSMajorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 1)"
OSMinorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 2)"
OSPatchVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 3)"
ArchType="$(/usr/bin/arch)"
DeferralPlist="$DeferralPlistPath/com.custom.deferrals.plist"
BundleID="com.apple.SoftwareUpdate"
DeferralType="count"
DeferralValue="${4}"
TimeOutinSecForForcedCLI="${5}"
TimeOutinSecForForcedGUI="${6}"
ITContact="${7}"
AppleSUIcon="${8}"

# Set default values
[[ -z "$DeferralValue" ]] && DeferralValue=3
[[ -z "$TimeOutinSecForForcedCLI" ]] && TimeOutinSecForForcedCLI="900"
[[ -z "$TimeOutinSecForForcedGUI" ]] && TimeOutinSecForForcedGUI="3600"
[[ -z "$ITContact" ]] && ITContact="IT"

CurrentDeferralValue="$(/usr/libexec/PlistBuddy -c "print :"$BundleID":count" "$DeferralPlist" 2>/dev/null)"

# Set up the deferral value if it does not exist already
if [[ -z "$CurrentDeferralValue" ]] || [[ "$CurrentDeferralValue" == *"File Doesn't Exist"* ]]; then
    setDeferral "$BundleID" "$DeferralType" "$DeferralValue" "$DeferralPlist"
    CurrentDeferralValue="$(/usr/libexec/PlistBuddy -c "print :"$BundleID":count" "$DeferralPlist" 2>/dev/null)"
fi

jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
jamf="/usr/local/bin/jamf"

# Path to temporarily store list of software updates. Avoids having to re-run the softwareupdate command multiple times.
ListOfSoftwareUpdates="/tmp/ListOfSoftwareUpdates"

# If non-existent path has been supplied, set appropriate Software Update icon depending on OS version
if [[ ! -e "$AppleSUIcon" ]]; then
    if [[ "$OSMajorVersion" -ge 11 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -gt 13 ]]; then
        AppleSUIcon="/System/Library/PreferencePanes/SoftwareUpdate.prefPane/Contents/Resources/SoftwareUpdate.icns"
    elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -eq 13 ]]; then
        AppleSUIcon="/System/Library/CoreServices/Install Command Line Developer Tools.app/Contents/Resources/SoftwareUpdate.icns"
    elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 8 && "$OSMinorVersion" -le 12 ]]; then
        AppleSUIcon="/System/Library/CoreServices/Software Update.app/Contents/Resources/SoftwareUpdate.icns"
    elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -lt 8 ]]; then
        AppleSUIcon="/System/Library/CoreServices/Software Update.app/Contents/Resources/Software Update.icns"
    fi
fi

# Path to the alert caution icon
AlertIcon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AlertStopIcon.icns"

## Verbiage For Messages ##
# Message to guide user to Software Update process
if [[ "$OSMajorVersion" -ge 11 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 14 ]]; then
    #SUGuide="by clicking on the Apple menu, clicking System Preferences and clicking Software Update to install any available updates."
    SUGuide="by navigating to:

 > System Preferences > Software Update"
else
    #SUGuide="by opening up the App Store located in the Applications folder and clicking on the Updates tab to install any available updates."
    SUGuide="by navigating to:

 > App Store > Updates tab"
fi

# Message to let user to contact IT
ContactMsg="There seems to have been an error installing the updates. You can try again $SUGuide

If the error persists, please contact $ITContact."

# Message to display when computer is running off battery
NoACPower="The computer is currently running off battery and is not plugged into a power source."

# Standard Update Message
StandardUpdatePrompt="There is a software update available for your Mac that requires a restart. Please click Continue to proceed to Software Update to run this update. If you are unable to start the process at this time, you may choose to postpone by one day.

Attempts left to postpone: $CurrentDeferralValue

You may install macOS software updates at any time $SUGuide"

# Forced Update Message
ForcedUpdatePrompt="There is a software update available for your Mac that requires you to restart. You have already postponed updates the maximum number of times.

Please save your work and click 'Update' otherwise this message will disappear and the computer will restart automatically."

# Forced Update Message for Apple Silicon
ForcedUpdatePromptForAS="There is a software update available for your Mac that requires you to restart. You have already postponed updates the maximum number of times.

Please save your work and install macOS software updates $SUGuide.

Failure to complete the update will result in the computer shutting down."

# Shutdown Warning Message
HUDWarningMessage="Please save your work and quit all other applications. This computer will be shutting down soon."

# Message shown when running CLI updates
HUDMessage="Please save your work and quit all other applications. macOS software updates are being installed in the background. Do not turn off this computer during this time.

This message will go away when updates are complete and closing it will not stop the update process.

If you feel too much time has passed, please contact $ITContact.

"
#Out of Space Message
NoSpacePrompt="Please clear up some space by deleting files and then attempt to do the update $SUGuide.

If this error persists, please contact $ITContact."

## Functions ##
powerCheck() {
    # This is meant to be used when doing CLI update installs.
    # Updates through the GUI can already determine its own requirements to proceed with
    # the update process.
    # Let's wait 5 minutes to see if computer gets plugged into power.
    for (( i = 1; i <= 5; ++i )); do
        if [[ "$(/usr/bin/pmset -g ps | /usr/bin/grep "Battery Power")" = "Now drawing from 'Battery Power'" ]] && [[ $i = 5 ]]; then
            echo "$NoACPower"
        elif [[ "$(/usr/bin/pmset -g ps | /usr/bin/grep "Battery Power")" = "Now drawing from 'Battery Power'" ]]; then
            /bin/sleep 60
        else
            return 0
        fi
    done
    exit 11
}


updateCLI() {
    # Behavior of softwareupdate has changed in Big Sur
    # -ia seems to download updates and not actually install them.
    # Use -iaR for updates to be installed.
    # This also means that the script will restart/shutdown immediately
    if [[ "$OSMajorVersion" -ge 11 ]]; then
        /usr/sbin/softwareupdate -iaR --verbose 1>> "$ListOfSoftwareUpdates" 2>> "$ListOfSoftwareUpdates" &
    else
        # Install all software updates
        /usr/sbin/softwareupdate -ia --verbose 1>> "$ListOfSoftwareUpdates" 2>> "$ListOfSoftwareUpdates" &
    fi
    
    ## Get the Process ID of the last command run in the background ($!) and wait for it to complete (wait)
    # If you don't wait, the computer may take a restart action before updates are finished
    SUPID=$(echo "$!")
    
    wait $SUPID
    
    SU_EC=$?
    
    echo $SU_EC
    
    return $SU_EC
}


updateRestartAction() {
    # On T2 hardware, we need to shutdown on certain updates
    # Verbiage found when installing updates that require a shutdown:
    #   To install these updates, your computer must shut down. Your computer will automatically start up to finish installation.
    #   Installation will not complete successfully if you choose to restart your computer instead of shutting down.
    #   Please call halt(8) or select Shut Down from the Apple menu. To automate the shutdown process with softwareupdate(8), use --restart.
    if [[ "$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -E "Please call halt")" || "$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -E "your computer must shut down")" ]] && [[ "$SEPType" ]]; then
        if [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -eq 13 && "$OSPatchVersion" -ge 4 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 14 ]] || [[ "$OSMajorVersion" -ge 11 ]]; then
            # Resetting the deferral count
            setDeferral "$BundleID" "$DeferralType" "$DeferralValue" "$DeferralPlist"
            
            echo "Restart Action: Shutdown/Halt"
            
            /sbin/shutdown -h now
            exit 0
        fi
    fi
    # Resetting the deferral count
    setDeferral "$BundleID" "$DeferralType" "$DeferralValue" "$DeferralPlist"
    
    # If no shutdown is required then let's go ahead and restart
    echo "Restart Action: Restart"
    
    /sbin/shutdown -r now
    exit 0
}


updateGUI() {
    # Update through the GUI
    if [[ "$OSMajorVersion" -ge 11 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 14 ]]; then
        /bin/launchctl $LMethod $LID /usr/bin/open "/System/Library/CoreServices/Software Update.app"
    elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 8 && "$OSMinorVersion" -le 13 ]]; then
        /bin/launchctl $LMethod $LID /usr/bin/open macappstore://showUpdatesPage
    fi
}


fvStatusCheck() {
    # Check to see if the encryption process is complete
    FVStatus="$(/usr/bin/fdesetup status)"
    if [[ $(/usr/bin/grep -q "Encryption in progress" <<< "$FVStatus") ]]; then
        echo "The encryption process is still in progress."
        echo "$FVStatus"
        exit 13
    fi
}


runUpdates() {
    "$jamfHelper" -windowType hud -lockhud -title "Apple Software Update" -description "$HUDMessage""START TIME: $(/bin/date +"%b %d %Y %T")" -icon "$AppleSUIcon" &>/dev/null &
    
    ## We'll need the pid of jamfHelper to kill it once the updates are complete
    JHPID=$(echo "$!")
    
    ## Run the command to insall software updates
    SU_EC="$(updateCLI)"
    
    ## Kill the jamfHelper. If a restart is needed, the user will be prompted. If not the hud will just go away
    /bin/kill -s KILL "$JHPID" &>/dev/null
    
    # softwareupdate does not exit with error when insufficient space is detected
    # which is why we need to get ahead of that error
    if [[ "$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -E "Not enough free disk space")" ]]; then
        SpaceError=$(echo "$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -E "Not enough free disk space" | /usr/bin/tail -n 1)")
        AvailableFreeSpace=$(/bin/df -g / | /usr/bin/awk '(NR == 2){print $4}')
        
        echo "$SpaceError"
        echo "Disk has $AvailableFreeSpace GB of free space."
        
        "$jamfHelper" -windowType utility -icon "$AlertIcon" -title "Apple Software Update Error" -description "$SpaceError Your disk has $AvailableFreeSpace GB of free space. $NoSpacePrompt" -button1 "OK" &
        return 15
    fi
    
    if [[ "$SU_EC" -eq 0 ]]; then
        updateRestartAction
    else
        echo "/usr/bin/softwareupdate failed. Exit Code: $SU_EC"
        
        "$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Apple Software Update" -description "$ContactMsg" -button1 "OK" &
        return 12
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


# Function to determine the last activity of softwareupdated
checkSoftwareUpdateDEndTime(){
    # Last activity for softwareupdated
    LastSULogEndTime="$(/usr/bin/log stats --process 'softwareupdated' | /usr/bin/awk '/end:/{ gsub(/^end:[ \t]*/, "", $0); print}')"
    LastSULogEndTimeInEpoch="$(/bin/date -jf "%a %b %d %T %Y" "$LastSULogEndTime" +"%s")"
    
    # Add a buffer period of time to last activity end time for softwareupdated
    # There can be 2-3 minute gaps of inactivity 
    # Buffer period = 3 minutes/180 seconds
    let LastSULogEndTimeInEpochWithBuffer=$LastSULogEndTimeInEpoch+120
    
    echo "$LastSULogEndTimeInEpochWithBuffer"
}

# Store list of software updates in /tmp which gets cleared periodically by the OS and on restarts
/usr/sbin/softwareupdate -l 2>&1 > "$ListOfSoftwareUpdates"

UpdatesNoRestart=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -i recommended | /usr/bin/grep -v -i restart | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//' | /usr/bin/sed -e 's/^Title:\ *//')
RestartRequired=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -i restart | /usr/bin/grep -v '\*' | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//' | /usr/bin/sed -e 's/^Title:\ *//')

# Determine Secure Enclave version
SEPType="$(/usr/sbin/system_profiler SPiBridgeDataType | /usr/bin/awk -F: '/Model Name/ { gsub(/.*: /,""); print $0}')"

# Determine currently logged in user
LoggedInUser="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')"

# Determine logged in user's UID
LoggedInUserID=$(/usr/bin/id -u "$LoggedInUser")

# Determine launchctl method we will need to use to launch osascript under user context
if [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -le 9 ]]; then
    LID=$(/usr/bin/pgrep -x -u "$LoggedInUserID" loginwindow)
    LMethod="bsexec"
else
    LID=$LoggedInUserID
    LMethod="asuser"
fi

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
            HELPER=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Apple Software Update" -description "$StandardUpdatePrompt" -button1 "Continue" -button2 "Postpone" -cancelButton "2" -defaultButton 2 -timeout "$TimeOutinSecForForcedCLI")
            echo "Jamf Helper Exit Code: $HELPER"
            
            # If they click "Update" then take them to the software update preference pane
            if [ "$HELPER" -eq 0 ]; then
                updateGUI
            fi
            
            exit 0
        else
            powerCheck
            # We've reached point where updates need to be forced.
            if [[ "$ArchType" == "arm64" ]]; then
                # For Apple Silicon Macs, behavior needs to be changed:
                # Ask the user to install update through GUI with shutdown warning if not completed within X time
                # After X time has passed, check to see if update is in progress.
                # If not in progress, force shutdown.
                
                # Capture start time for forced update via GUI
                ForceUpdateStartTimeInEpoch="$(/bin/date -jf "%a %b %d %T %Z %Y" "$(/bin/date)" +"%s")"
                
                # Calculate scheduled end time for forced update via GUI
                let ForceUpdateScheduledEndTimeInEpoch=$ForceUpdateStartTimeInEpoch+$TimeOutinSecForForcedGUI
                
                # If someone is logged in and they run out of deferrals, prompt them to install updates that require a restart via GUI with warning that shutdown will occur.
                HELPER=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Apple Software Update" -description "$ForcedUpdatePromptForAS" -button1 "Update" -defaultButton 1 -timeout "$TimeOutinSecForForcedGUI" -countdown -alignCountdown "right")
                echo "Jamf Helper Exit Code: $HELPER"
                
                # If they click "Update" then take them to the software update preference pane
                if [ "$HELPER" -eq 0 ]; then
                    updateGUI
                fi
                
                echo "Waiting until time out period for forced GUI install has passed."
                
                # Wait until the time out period for forced GUI installs has passed
                while [[ "$(/bin/date -jf "%a %b %d %T %Z %Y" "$(/bin/date)" +"%s")" -lt "$ForceUpdateScheduledEndTimeInEpoch" ]]; do
                    sleep 60
                done
                
                echo "Time out period for forced GUI install has passed."
                echo "Waiting until softwareupdated is no longer logging any activity."
                
                # Compare end time of last activity of softwareupdated and if more than buffer period time has passed, proceed with shutdown
                while [[ "$(/bin/date -jf "%a %b %d %T %Z %Y" "$(/bin/date)" +"%s")" -lt "$(checkSoftwareUpdateDEndTime)" ]]; do
                    sleep 15
                done
                
                echo "softwareupdated is no longer logging activity."
                
                # Let user know shutdown is taking place
                "$jamfHelper" -windowType hud -icon "$AppleSUIcon" -title "Apple Software Update" -description "$HUDWarningMessage" -button1 "Shut Down" -defaultButton 1 -timeout "60" -countdown -alignCountdown "right" &
                echo "Jamf Helper Exit Code: $HELPER"
                
                # Shutdown computer
                /sbin/shutdown -h now
            else
                # For Intel Macs, an attempt to continue using CLI to install updates will be made
                # If someone is logged in and they run out of deferrals, force install updates that require a restart via CLI
                # Prompt users to let them initiate the CLI update via Jamf Helper dialog
                HELPER=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Apple Software Update" -description "$ForcedUpdatePrompt" -button1 "Update" -defaultButton 1 -timeout "$TimeOutinSecForForcedCLI" -countdown -alignCountdown "right")
                echo "Jamf Helper Exit Code: $HELPER"
                # Either they clicked "Updates" or
                # Someone tried to quit jamfHelper or the jamfHelper screen timed out
                # The Timer is already 0, run the updates automatically, the end user has been warned!
                if [[ "$HELPER" -eq "0" ]] || [[ "$HELPER" -eq "239" ]]; then
                    runUpdates
                    RunUpdates_EC=$?
                    
                    if [[ $RunUpdates_EC -ne 0 ]]; then
                        exit $RunUpdates_EC
                    fi
                fi
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
