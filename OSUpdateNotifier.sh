#!/bin/bash

# This script is meant to be used with Jamf Pro and makes use of Jamf Helper.
# The idea behind this script is that it alerts the user that the OS they are running is
# no longer supported. Rather than forcing updates through, this allows you to control the
# pace of notifications the user receives to perform the OS upgrade. If the user opts to
# proceed with the upgrade, they will get taken to a second policy that you've configured
# to do the OS upgrade.
#
# There are three optional dates that you can supply that will dictate the notifications
# the user receives.
# Start Date: This provides a notification to the user but also allows them to delay when
#   they will receive the next reminder.
# Nag Date: This provides a notification to the user. The user cannot select when to be
#   reminded. This will be set based on the re-notification period set by the admin.
# End Date: This provides a notification to the user when the update can take place. Once
#   this date has been reached, you can set it so that the user has X amount of attempts
#   left before they are forced to upgrade. User will receive a notification every 24 hour
#   24 hours until deferrals have been exceeded.
#
# Dates can be supplied in either epoch seconds or string format (e.g. Sep 03 12:34:56 -0400 2019)
# The notifications are meant to get increasingly more forceful.
# Because the dates are optional, you can either supply no dates, some of the
# dates (e.g. Start And End Date only), or all of the dates at your discretion.
# What this means is that the user will only see the notification after that date has been
# reached. If no dates are supplied, the user will simply get the same notification as if
# a start date had been set.
# Each date needs to be greater than the previous; your Start date can't be set to a date
# after the End date.
#
# With each notification, the "More Info" button in the Jamf Helper will always open up a
# URL. This URL should provide the user will instructions on how to proceed to update.
# Because it's a URL, you could also provide a Self Service URL as well if you want with
# the assumption you have a detailed description.
#
# This script does try to account for the fact that it's Self Service-centric. That means
# there are a few checks in place to try and give the user the best chance to perform the
# upgrade:
# -Ensure a user is logged in.
# -Power source is connected
# -No app is opened that has a display sleep assertion active
# -Idle time of the computer
#
# Given the above overview, here are the Jamf script parameters:
# Parameter 4: Optional. Enter "major" or "minor" which will dictate if the script alerts
#   against a necessary major OS upgrade or minor OS update. If not set, the default
#   will be "minor."
# Parameter 5: Optional. The custom trigger name for a Jamf policy that will initiate the
#   major OS upgrade.
# Parameter 6: Required. Provide the policy kicking off this script a custom trigger name
#   and supply it here. This is used for situations when the user tries to quit
#   Jamf Helper notifications.
# Parameter 7: Optional. The Start Date at which point the logic in this script will
#   provide the end-user a notification with the option to set when they will receive the
#   next reminder. If not set, the user will start to receive notifications the second
#   time the script is run based on the re-notification period. Date can be supplied in
#   epoch seconds or string format (e.g. Sep 03 12:34:56 -0400 2019).
# Parameter 8: Optional. The Nag Date at which point the logic in this script will provide
#   the end-user a notification which they can dismiss. User cannot select when to be
#   reminded as this is determined by the renotification period.
# Parameter 9: Optional. The End Date at which point the logic in this script will provide
#   the end-user a notification which they can defer only X amount of times (defaults
#   to 3 times). The user will get reminded every 24 hours until those deferrals have
#   been exhausted.
# Parameter 10: Optional. The re-notification period before the user will get the
#   notification again. This becomes applicable when you're passed the Nag date. Default
#   to 60 minutes.
# Parameter 11: Optional. The time out period in seconds which determines how long the
#   Jamf Helper notification will stay up. Defaults to 90 minutes.
#
#
# Unfortunately, there are not enough Jamf parameters available to use for all the
# customizations allowed in this script. Due to this limitation, there are other variables
# in this script you can change under the section titled "Variables You Can Modify":
# MaxDeferralAttempts: Required. Determines the number of deferral attempts a user has
#   after the end date has been reached.
# MaxIdleTime: Required. Number of seconds in which a computer has been idle for too long
#   to expect someone to be sitting in front of it. Script will exit if computer has been
#   idle longer than this time.
# MoreInfoURL: Optional. A URL that points the user to a page on the macOS upgrade process.
#   If left blank, this will default to Apple's macOS upgrade/update page which have been
#   active since September 2016. You can optionally use a Self Service URL.
# DelayOptions: Required. A list of comma separated seconds to provide delay options to
#   the user. The seconds will show up in Jamf Helper as time values. 3600 = 1 Hour
# ITContact: Optional. Enter either an email address, phone number, or IT department name
#   for the end user to contact your team for assistance. Defaults to "IT" if left blank.
#
# Verbiage:
# I've written the verbiage with the idea that the end user would open up Self Service 
# to perform upgrade macOS. Maybe this doesn't work in your environment because you don't
# have a Self Service workflow. Or maybe there's just something else you want to change in
# the verbiage. Below are the variable names so that you can alter the verbiage to your
# liking should you want to. There is a bit of variable logic inside the verbiage so
# modify at your own risk.
#
# Variable Names for the notifications:
# ReminderNotification: The text used when Start date has been reached or if no Start
#   date has been supplied.
# NaggingNotification: The text used when Nag date has been reached.
# FinalNotification: The text used when End date has been reached but there are still
#   deferrals left.
# FinalCallNotificationForCLIUpdate: The text used during a CLI update when End date has 
#   been reached with no more deferrals left.
# FinalCallNotificationForGUIUpdate: The text used during a forced GUI update when End
#   date has been reached with no more deferrals left.
# ShutdownWarningMessage: The text used just before shutting down.
# BackgroundInstallMessage: The text used when CLI updates are being actively performed.
#
# There are a few exit codes in this script that may indicate points of failure:
# 10: Required parameter has been left empty.
# 11: Make sure Start date < Nag date < End date.
# 12: Insufficient space to perform update.
# 13: /usr/bin/softwareupdate failed.
# 15: Incorrect property list type used. Valid types include: "array" "dict" "string"
#     "data" "date" "integer" "real" "bool"
# 16: Invalid date entered.

########### Variables You Can Modify ###########
# The number of max deferral attempts a user can make after end date
# If left blank, will default to 3
MaxDeferralAttempts=""

# Max Idle Time
# If computer has been idle longer than this time, script will exit.
# If left blank, will default to 600 seconds (10 minutes)
MaxIdleTime=""

# Delay options to show user
# Enter time in seconds with commas separated (e.g "0, 3600, 14400, 86400")
# If left blank, will default to: Now, 1hr, 4hrs, 24hrs
DelayOptions=""

# Comma separated string of process names to ignore when evaluating display sleep assertions.
# If a process you've listed has a display sleep assertion, the script will resume which may result
# in valid display sleep assertions being ignored.
# E.g. "firefox,Google Chrome,Safari,Microsoft Edge,Opera,Amphetamine,caffeinate"
# If left blank, any Display Sleep assertion will be honored.
AssertionsToIgnore=""

# URL to provide upgrade instructions
# If left blank, it will default to
# https://www.apple.com/macos/how-to-upgrade/ (for major OS updates)
# https://support.apple.com/HT201541 (for minor OS updates)
MoreInfoURL=""

# Time out period for CLI installs
# This is useful for situations where you want there to be a shorter time out period than
# normal. If left blank, defaults to the regular default time out period.
TimeOutinSecForForcedCLI=""

# Contact information for IT
# If left blank, will default to "IT"
ITContact=""
########### End Of Variables You Can Modify ###########

########### Variables For Verbiage You Can Modify ###########
setNotificationMessages(){
if [[ "$UpdateAction" == "major" ]]; then
    addMajorText=" major "
    addMajorUpgradeText="upgrade"
    if [[ "$CustomTriggerNameForUpgradePolicy" ]]; then
        StepsToUpgrade="Finder > Applications > Self Service"
    else
        StepsToUpgrade=" > App Store > search for macOS"
    fi
else
    addMajorText=" "
    addMajorUpgradeText="update"
    if [[ "$OSMajorVersion" -ge 11 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 14 ]]; then
        #SUGuide="by clicking on the Apple menu, clicking System Preferences and clicking Software Update to install any available updates."
        StepsToUpgrade=" > System Preferences > Software Update"
    else
        #SUGuide="by opening up the App Store located in the Applications folder and clicking on the Updates tab to install any available updates."
        StepsToUpgrade=" > App Store > Updates tab"
    fi
fi

# Default Reminder notification
ReminderNotification="There is a${addMajorText}software $addMajorUpgradeText available for your Mac that should be installed at your earliest convenience. If you have any questions, please contact $ITContact.

You may install this macOS software $addMajorUpgradeText at any time by navigating to:

$StepsToUpgrade

Please make a selection and then click Proceed:"

# Default Nagging notification
NaggingNotification="There is a${addMajorText}software $addMajorUpgradeText available for your Mac that should be installed at your earliest convenience. Click Proceed to ensure your computer is in compliance with the latest security updates. If you have any questions, please contact $ITContact.

You may install this macOS software $addMajorUpgradeText at any time by navigating to:

$StepsToUpgrade"

# Default final notification
FinalNotification="There is a${addMajorText}software $addMajorUpgradeText available for your Mac that should be installed as soon as possible. It is required that you $addMajorUpgradeText this computer as soon as possible, but you can you postpone if necessary.

Attempts left to postpone: $(($MaxDeferralAttempts - $CurrentDeferralValue))

Please save your work and click Proceed to start the $addMajorUpgradeText. You may install this macOS software $addMajorUpgradeText at any time by navigating to:

$StepsToUpgrade

If you have any questions or concerns, please contact $ITContact."


# Default notification when no deferrals are left for Macs on Intel
FinalCallNotificationForCLIUpdate="There is a${addMajorText}software $addMajorUpgradeText available for your Mac that needs to be installed immediately. There are no opportunities left to postpone this $addMajorUpgradeText any further.

Please save your work and click Proceed otherwise this message will disappear and the computer will restart automatically.

If you have any questions or concerns, please contact $ITContact."

# Default notification when no deferrals are left for Macs on Apple Silicon
FinalCallNotificationForGUIUpdate="There is a${addMajorText}software $addMajorUpgradeText available for your Mac that needs to be installed immediately. There are no opportunities left to postpone this $addMajorUpgradeText any further.

Please save your work and $addMajorUpgradeText by navigating to:

$StepsToUpgrade

Failure to complete the $addMajorUpgradeText will result in this computer shutting down."

# Shutdown Warning Message
ShutdownWarningMessage="Please save your work and quit all other applications. This computer will be shutting down soon."

# Message shown when running CLI updates
BackgroundInstallMessage="Please save your work and quit all other applications. macOS is being ${addMajorUpgradeText}d in the background. Do not turn off this computer during this time.

This message will go away when the $addMajorUpgradeText is complete and closing it will not stop the update process.

If you feel too much time has passed, please contact $ITContact.

"
}

#Out of Space Message
NoSpacePrompt="Please clear up some space by deleting files and then attempt to do the update by navigating to:

$StepsToUpgrade

If this error persists, please contact $ITContact."

ContactMsg="There seems to have been an error installing the updates. You can try again by navigating to:

$StepsToUpgrade

If the error persists, please contact $ITContact."

########### End Of Variables You Can Modify ###########

###### ACTUAL WORKING CODE  BELOW #######
setPlistValue(){
    # Notes: PlistBuddy "print" will print stderr to stdout when file is not found.
    #   File Doesn't Exist, Will Create: /path/to/file.plist
    # There is some unused code here with the idea that at some point in the future I can
    # extend functionality of this script to support hard and relative dates.
    BundleID="${1}"
    Key="${2}"
    Type="${3}"
    Value="${4}"
    Plist="${5}"
    UsableTypes=("array" "dict" "string" "data" "date" "integer" "real" "bool") # 8
    
    # Ensure that a valid property list type was requested
    count=1
    total=${#UsableTypes[@]}
    for i in ${UsableTypes[@]}; do
        if [[ "$Type" == "$i" ]]; then
            break
        fi
        ((count++))
        if [[ "$count" > "$total" ]]; then
            echo "Incorrect property list type used. Valid types include:"
            echo '"array" "dict" "string" "data" "date" "integer" "real" "bool"'
            exit 15
        fi
    done
    
    # Possible types: https://developer.apple.com/library/archive/documentation/General/Conceptual/DevPedia-CocoaCore/PropertyList.html
    # Array, String, Data, Date, Integer, Boolean, Dictionary, Floating-point value
    # array, string, data, date, integer, bool,    dict,       real
    KeyValueExitCode="$(/usr/libexec/PlistBuddy -c "print :$BundleID:$Key" "$Plist" &>/dev/null ; echo $?)"
    
    if [[ "$KeyValueExitCode" == 0 ]]; then
        /usr/libexec/PlistBuddy -c "set :$BundleID:$Key $Value" "$Plist" 2>/dev/null
    else
        /usr/libexec/PlistBuddy -c "add :$BundleID:$Key $Type $Value" "$Plist" 2>/dev/null
    fi
}


readPlistValue(){
    # Notes: PlistBuddy "print" will print an error to stdout when file is not found.
    #   File Doesn't Exist, Will Create: /path/to/file.plist
    # It prints to stderr as well when file is not found:
    #   Print: Entry, ":key:sub_key1", Does Not Exist
    BundleID="${1}"
    Key="${2}"
    Plist="${3}"
    
    # KeyValue="$(/usr/libexec/PlistBuddy -c "print :$BundleID:$Key" "$Plist" 2>/dev/null)"
    KeyValueExitCode="$(/usr/libexec/PlistBuddy -c "print :$BundleID:$Key" "$Plist" &>/dev/null ; echo $?)"
    
    if [[ "$KeyValueExitCode" == 0 ]]; then
        KeyValue="$(/usr/libexec/PlistBuddy -c "print :$BundleID:$Key" "$Plist" 2>/dev/null)"
        echo "$KeyValue"
        return 0
    fi
    
    return 1
}

checkParam(){
if [[ -z "$1" ]]; then
    /bin/echo "\$$2 is empty and required. Please fill in the JSS parameter correctly."
    exit 10
fi
}

validateDate(){
    dateValue="${1}"
    paramName="${2}"
    
    # Check if date is empty
    [[ -z "$dateValue" ]] && echo "" && return 0
    
    # Check if date is an integer
    [[ "$dateValue" =~ ^[0-9]+$ ]] && echo "$dateValue" && return 0
    
    # Check if string can be converted to epoch seconds
    [[ "$(/bin/date -jf "%b %d %T %z %Y" "$dateValue" +"%s" &>/dev/null; echo $?)" == 0 ]] && echo "$(/bin/date -jf "%b %d %T %z %Y" "$dateValue" +"%s")" && return 0
    
    echo "The parameter $paramName has the value $dateValue which is not valid."
    echo "Dates need to be in either integer (epoch seconds) or time string format (MMM DD HH:MM:SS TZ YYYY) such as Sep 03 12:34:56 -0400 2019."
    exit 16
}


# Jamf Parameters
MinSupportedOSVersion="${4}"
UpdateAction="${4}"
CustomTriggerNameForUpgradePolicy="${5}"
CustomTriggerNameDeprecationPolicy="${6}"
StartDate="$(validateDate "${7}" "StartDate")"; [[ "$?" == 15 ]] && exit 16
NagDate="$(validateDate "${8}" "NagDate")"; [[ "$?" == 15 ]] && exit 16
EndDate="$(validateDate "${9}" "EndDate")"; [[ "$?" == 15 ]] && exit 16
RenotifyPeriod="${10}"
TimeOutinSec="${11}"

# Set the time out for CLI installs to be the same as the default time out period
[ -z "$TimeOutinSecForForcedCLI" ] && TimeOutinSecForForcedCLI="$TimeOutinSec"

# Set Upgrade Action to "minor" if not set to "major"
UpdateAction=$(echo $UpdateAction | /usr/bin/tr '[:upper:]' '[:lower:]')
[[ -z "$UpdateAction" || "$UpdateAction" != "major" ]] && UpdateAction="minor"

# Path to Jamf Helper and Jamf binary
jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
jamf="/usr/local/bin/jamf"

# OS version
OSMajorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 1)"
OSMinorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 2)"
OSPatchVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 3)"

# Determine architecture
ArchType="$(/usr/bin/arch)"

# Path to plist containing history on previous runs of script
DeprecationPlist="/Library/Application Support/JAMF/com.custom.deprecations.plist"
BundleID="com.apple.macOS.softwareupdates"
[[ "$UpdateAction" == "major" ]] && BundleID="com.apple.macOS.upgrade"

# Path to temporarily store list of software updates. Avoids having to re-run the softwareupdate command multiple times.
ListOfSoftwareUpdates="/tmp/ListOfSoftwareUpdates"

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

#  Set appropriate Software Update icon depending on OS version
if [[ "$OSMajorVersion" -ge 11 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -gt 13 ]]; then
    AppleSUIcon="/System/Library/PreferencePanes/SoftwareUpdate.prefPane/Contents/Resources/SoftwareUpdate.icns"
elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -eq 13 ]]; then
    AppleSUIcon="/System/Library/CoreServices/Install Command Line Developer Tools.app/Contents/Resources/SoftwareUpdate.icns"
elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 8 && "$OSMinorVersion" -le 12 ]]; then
    AppleSUIcon="/System/Library/CoreServices/Software Update.app/Contents/Resources/SoftwareUpdate.icns"
elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -lt 8 ]]; then
    AppleSUIcon="/System/Library/CoreServices/Software Update.app/Contents/Resources/Software Update.icns"
fi

# Set default values if parameters left empty
[ -z "$RenotifyPeriod" ] && RenotifyPeriod="3600" # 60 mins
[ -z "$TimeOutinSec" ] && TimeOutinSec="5400" # 90 mins
[ -z "$MaxDeferralAttempts" ] && MaxDeferralAttempts="3"
[ -z "$MaxIdleTime" ] && MaxIdleTime="600" # 10 mins
[ -z "$DelayOptions" ] && DelayOptions="0, 3600, 14400, 86400" # Now, 1hr, 4hrs, 24hrs
[ -z "$ITContact" ] && ITContact="IT"
if [[ -z "$MoreInfoURL" ]]; then
    if [[ "$UpdateAction" == "major" ]]; then
        MoreInfoURL="https://www.apple.com/macos/how-to-upgrade" # Apple macOS Upgrade page
    else
        MoreInfoURL="https://support.apple.com/HT201541" # Apple macOS Software Update page
    fi
fi

# Set Jamf Helper Title Text
[[ "$UpdateAction" == "major" ]] && JamfHelperTitle="macOS Upgrade" || JamfHelperTitle="macOS Software Update"

# Dates in String Format for plist output
[ -n "$StartDate" ] && StartDateString="$(date -r $StartDate +"%a %b %d %T %Z %Y")"
[ -n "$NagDate" ] && NagDateString="$(date -r $NagDate +"%a %b %d %T %Z %Y")"
[ -n "$EndDate" ] && EndDateString="$(date -r $EndDate +"%a %b %d %T %Z %Y")"

# Current time in Epoch seconds
CurrentRunEpochTime="$(/bin/date +"%s")"

# Current time in string format
CurrentRunTimeString="$(/bin/date -r $CurrentRunEpochTime +"%a %b %d %T %Z %Y")"

# Last time this script was run
LastRunEpochTime="$(readPlistValue "$BundleID" "LastRunEpochTime" "$DeprecationPlist")"

# Last time software update check ran
LastUpdateCheckEpochTime="$(readPlistValue "$BundleID" "LastUpdateCheckEpochTime" "$DeprecationPlist")"
[[ -z "$LastUpdateCheckEpochTime" ]] && LastUpdateCheckEpochTime="0"

# Next Reminder Time. If current time is not later than Reminder Time, we should not proceed.
NextReminderEpochTime="$(readPlistValue "$BundleID" "NextReminderEpochTime" "$DeprecationPlist")"
NextReminderTimeString="$(readPlistValue "$BundleID" "NextReminderTimeString" "$DeprecationPlist")"

# Number of times notifications have been ignored.
TimesIgnored="$(readPlistValue "$BundleID" "TimesIgnored" "$DeprecationPlist")"

# Current number of postponements left
CurrentDeferralValue="$(readPlistValue "$BundleID" "Deferral" "$DeprecationPlist")"
[ -z "$CurrentDeferralValue" ] && CurrentDeferralValue="0"

# The last start time the computer fell into a force update
ForceUpdateStartTimeInEpoch="$(readPlistValue "$BundleID" "ForceUpdateStartTimeInEpoch" "$DeprecationPlist")"
ForceUpdateStartTimeString="$(readPlistValue "$BundleID" "ForceUpdateStartTimeString" "$DeprecationPlist")"

# Number of times a display sleep assertion has been encountered
DisplaySleepAssertionsEncountered="$(readPlistValue "$BundleID" "DisplaySleepAssertionsEncountered" "$DeprecationPlist")"

# Check Required Jamf Parameters
checkParam "$CustomTriggerNameDeprecationPolicy" "CustomTriggerNameDeprecationPolicy"

# Name of process to check against when forcing an upgrade/update
[[ "$UpdateAction" == "major" ]] && ProcessToCheck="osinstallersetupd" || ProcessToCheck="softwareupdated"

# Instantiate Notification Messages
setNotificationMessages


# Function to check if user is logged in
checkForLoggedInUser(){
    if [[ -z "$LoggedInUser" ]]; then
        echo "No user logged in."
        
        # In macOS Big Sur, softwareupdate run from a launch daemon while no user is logged in seems to run
        if [[ "$RestartRequired" ]] && [[ "$ArchType" != "arm64" ]] && [[ "$OSMajorVersion" -ge 11 ]]; then
            echo "Attempting install of software updates while no user is logged in."
            
            # Capture value of CLI install of updates
            SU_EC="$(updateCLI)"
            
            if [[ "$SU_EC" -ne 0 ]]; then
                echo "Attempt to install software update(s) failed."
                echo "/usr/bin/softwareupdate failed. Exit Code: $SU_EC"
            fi
            
            # Refresh software update list now that updates have been installed silently in the background
            refreshSoftwareUpdateList
            
            exit 0
        fi
        
        exit 0
    fi
}

# Function to check for a power connection
checkPower(){
    # This is meant to be used when doing CLI update installs.
    # Updates through the GUI can already determine its own requirements to proceed with
    # the update process.
    # Let's wait 5 minutes to see if computer gets plugged into power.
    for (( i = 1; i <= 5; ++i )); do
        if [[ "$(/usr/bin/pmset -g ps | /usr/bin/grep "Battery Power")" = "Now drawing from 'Battery Power'" ]]; then
            echo "Computer is not currently connected to a power source."
            /bin/sleep 60
        else
            return 0
        fi
    done
    
    echo "Exiting script as computer is not connected to power."
    exit 0
}

# Function to get current time
getCurrentTime(){
    # Current time in Epoch seconds
    CurrentRunEpochTime="$(/bin/date +"%s")"
    
    # Current time in string format
    CurrentRunTimeString="$(/bin/date -r $CurrentRunEpochTime +"%a %b %d %T %Z %Y")"
}

# Function to set the next reminder time
setNextReminderTime(){
    TimeChosen="${1}"
    
    getCurrentTime
    
    # Record current run time as the last run time
    echo "Current Run Time: $CurrentRunTimeString"
    setPlistValue "$BundleID" "LastRunEpochTime" "integer" "$CurrentRunEpochTime" "$DeprecationPlist"
    setPlistValue "$BundleID" "LastRunTimeString" "string" "$CurrentRunTimeString" "$DeprecationPlist"
    
    # If no time was chosen, default to reminder period of 1 day
    [ -z "$TimeChosen" ] && TimeChosen="86400" # 24 Hours
    
    # Calculate total of Current time + Time Chosen in Epoch seconds
    NextReminderEpochTime="$(/usr/bin/bc -l <<< "$CurrentRunEpochTime + $TimeChosen")"
    
    # Next Run Time in string format
    NextReminderTimeString="$(/bin/date -r $NextReminderEpochTime +"%a %b %d %T %Z %Y")"
    echo "User will be reminded after: $NextReminderTimeString"
    
    # Record Next Reminder Time
    setPlistValue "$BundleID" "NextReminderEpochTime" "integer" "$NextReminderEpochTime" "$DeprecationPlist"
    setPlistValue "$BundleID" "NextReminderTimeString" "string" "$NextReminderTimeString" "$DeprecationPlist"
}

incrementTimesIgnored(){
    let TimesIgnored=$TimesIgnored+1
    
    setPlistValue "$BundleID" "TimesIgnored" "integer" "$TimesIgnored" "$DeprecationPlist"
}

openMoreInfoURL(){
    # Open More Info URL in web browser
    /usr/bin/sudo -u "$LoggedInUser" /usr/bin/open "$MoreInfoURL"
}

# Function to check for idle time
checkForHIDIdleTime(){
    HIDIdleTime="$(/usr/sbin/ioreg -c IOHIDSystem | /usr/bin/awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')"
    
    if [[ "$HIDIdleTime" -gt "$MaxIdleTime" ]]; then
        echo "Exiting script since the computer has been idle for $HIDIdleTime seconds."
        exit 0
    fi
}

# Function to do best effort check if using presentation or web conferencing is active
checkForDisplaySleepAssertions(){
    ActiveAssertions="$(/usr/bin/pmset -g assertions | /usr/bin/awk '/NoDisplaySleepAssertion | PreventUserIdleDisplaySleep/ && match($0,/\(.+\)/) && ! /coreaudiod/ {gsub(/^\ +/,"",$0); print};')"
    
    # There are multiple types of power assertions an app can assert.
    # These specifically tend to be used when an app wants to try and prevent the OS from going to display sleep.
    # Scenarios where an app may not want to have the display going to sleep include, but are not limited to:
    #   Presentation (KeyNote, PowerPoint)
    #   Web conference software (Zoom, Webex)
    #   Screen sharing session
    # Apps have to make the assertion and therefore it's possible some apps may not get captured.
    # Some assertions can be found here: https://developer.apple.com/documentation/iokit/iopmlib_h/iopmassertiontypes
    if [[ "$ActiveAssertions" ]]; then
        echo "The following display-related power assertions have been detected:"
        echo "$ActiveAssertions"
        
        # Track the number of display sleep assertions encountered
        [[ -z "$DisplaySleepAssertionsEncountered" ]] && DisplaySleepAssertionsEncountered="0"
        
        # Convert comma separated string into an array in zsh
        #AssertionsToIgnoreList=("${(@s/,/)AssertionsToIgnore}")
        
        # Capture current $IFS
        OIFS=$IFS
        # Set IFS to ,
        IFS=,
        
        # Loop through list of processes for assertions to ignore
        for Assertion in $AssertionsToIgnore; do
            if grep -i -q "$Assertion" <<< "$ActiveAssertions"; then
                echo "An ignored display sleep assertion has been detected: $Assertion"
                echo "All display sleep assertions are going to be ignored."
                return 0
            fi
        done
        
        # Reset IFS back
        IFS=$OIFS
        
        # Increment postponement by 1
        let DisplaySleepAssertionsEncountered=$DisplaySleepAssertionsEncountered+1
        
        # Update record of display sleep assertions that have been encountered
        setPlistValue "$BundleID" "DisplaySleepAssertionsEncountered" "integer" "$DisplaySleepAssertionsEncountered" "$DeprecationPlist"
        
        echo "Exiting script to avoid disrupting user while these power assertions are active."
        
        exit 0
    fi
}

# Function to check if user attempted to quit Jamf Helper
checkAttemptToQuit(){
    Value="${1}"
    
    # Jamf Helper was exited without making a choice
    if [[ "$Value" == "239" ]]; then
        echo "Jamf Helper was exited without making a choice."
        "$jamf" policy -event "$CustomTriggerNameDeprecationPolicy" &
        exit 0
    fi
}

# Function to make sure the Start date < Nag date < End date
compareDates(){
    Msg="Make sure Start date ($StartDateString) < Nag date ($NagDateString) < End date ($EndDateString)."
    
    # No need to compare if no dates have been specified
    [[ -z "$StartDate" && -z "$NagDate" && -z "$EndDate" ]] && return 0
    
    # No need to compare if 2 out of 3 dates have not been specified
    [[ -z "$StartDate" && -z "$NagDate" ]] && return 0
    [[ -z "$NagDate" && -z "$EndDate" ]] && return 0
    [[ -z "$StartDate" && -z "$EndDate" ]] && return 0
    
    # Check if Start date < Nag date < End date
    [[  "$StartDate" && "$NagDate" && "$EndDate" ]] && [[ "$StartDate" > "$NagDate" ]] && [[ "$StartDate" > "$EndDate" ]] && [[ "$NagDate" > "$EndDate" ]] && echo "$Msg" && exit 11
    
    # Check if Nag date < End date
    [[ "$NagDate" && "$EndDate" && "$NagDate" > "$EndDate" ]] && echo "$Msg" && exit 11
    
    # Check if Start date < Nag date
    [[ "$StartDate" && "$NagDate" && "$StartDate" > "$NagDate" ]] && echo "$Msg" && exit 11
    
    # Check if Start date < End date
    [[ "$StartDate" && "$EndDate" && "$StartDate" > "$EndDate" ]] && echo "$Msg" && exit 11
    
    return 0
}

isCurrentTimeLessThanStartDate(){
    # Check if current time is greater than the Start Date
    if [[ "$StartDate" && "$CurrentRunEpochTime" -lt "$StartDate" ]]; then
        echo "We have not yet reached the Start Date $StartDateString"
        exit 0
    fi
}

takeUpgradeAction(){
    # If no custom trigger has been provided, we can only reminder or nag user
    if [[ "$CustomTriggerNameForUpgradePolicy" ]]; then
        "$jamf" policy -event "$CustomTriggerNameForUpgradePolicy" -randomDelaySeconds 0
    else
        /usr/bin/open "macappstore://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?q=apple%20macos&mt=12"
    fi
}

incrementDeferralValue(){
    # Increment postponement by 1
    let CurrentDeferralValue=$CurrentDeferralValue+1
    
    # Record number of postponements
    setPlistValue "$BundleID" "Deferral" "integer" "$CurrentDeferralValue" "$DeprecationPlist"
}

isBeyondPointOfNoReturn(){
    # Check if we're passed the End Date and no deferral attempts are left
    if [[ "$NextReminderEpochTime" && "$EndDate" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" && "$CurrentRunEpochTime" -ge "$EndDate" ]] && [[ -z "$NextReminderEpochTime" && "$CurrentDeferralValue" -ge "$MaxDeferralAttempts" ]] || [[ "$EndDate" && "$CurrentRunEpochTime" -ge "$EndDate" ]] && [[ "$CurrentDeferralValue" -ge "$MaxDeferralAttempts" ]]; then
        # Check for power
        checkPower
        if [[ "$UpdateAction" == "major" && "$CustomTriggerNameForUpgradePolicy" ]]; then
            # Running OS upgrade policy
            "$jamf" policy -event "$CustomTriggerNameForUpgradePolicy" -randomDelaySeconds 0
        elif [[ "$UpdateAction" == "major" && -z "$CustomTriggerNameForUpgradePolicy" ]]; then
            # Relying on the user to perform OS upgrade manually
            forceGUISoftwareUpdate
        else
            # Forcing user to perform minor OS update
            forceGUISoftwareUpdate
        fi
        
        exit 0
    fi
}

isPassEndDate(){
    # If StartDate/NagDate have not been set and CurrentRunEpochTime is less than EndDate, exit
    if [[ -z "$StartDate" && -z "$NagDate" && "$EndDate" && "$CurrentRunEpochTime" -lt "$EndDate" ]]; then
        echo "Current time is $CurrentRunTimeString. End Date $EndDateString has not been reached."
        exit 0
    fi
    
    # Check if we're passed the End Date
    if [[ "$NextReminderEpochTime" && "$EndDate" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" && "$CurrentRunEpochTime" -ge "$EndDate" ]] || [[ -z "$NextReminderEpochTime" && "$EndDate" && "$CurrentRunEpochTime" -ge "$EndDate" ]]; then
        Helper=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "$JamfHelperTitle" -description "$FinalNotification" -button1 "Proceed" -button2 "Postpone" -cancelButton "2" -defaultButton 2 -timeout "$TimeOutinSec")
        echo "Jamf Helper Exit Code: $Helper"
        
        checkAttemptToQuit "$Helper"
        
        # Increment postponement
        incrementDeferralValue
        
        # Note for potential future improvement:
        # It's possible a user may click Update X times in a row and use up all their deferrals in one day.
        # To avoid that, count Proceed clicks only after 24 hours after passed since the last time a deferral value was set
        
        # User clicked More Info
        if [[ "$Helper" == 2 ]]; then
            # Set next reminder to 24 hour
            setNextReminderTime
            
            incrementTimesIgnored
            
            # Open More Info URL
            openMoreInfoURL
            
            exit 0
        fi
        
        # Set next reminder to 24 hours to provide user time to update via GUI
        setNextReminderTime
        
        updateGUI
        
        exit 0
    fi
}

isPassNagDate(){
    # If StartDate has not been set and CurrentRunEpochTime is less than NagDate, exit
    if [[ -z "$StartDate" && "$NagDate" && "$CurrentRunEpochTime" -lt "$NagDate" ]]; then
        echo "Current time is $CurrentRunTimeString. Nag Date $NagDateString has not been reached."
        exit 0
    fi
    
    # Append to the Nagging Notification message if an End Date has been supplied
    if [[ "$EndDate" ]]; then
        NaggingNotification="$NaggingNotification

After $EndDateString, an $addMajorUpgradeText will be required on this computer."
    fi
    
    # Check if we're passed the Nagging Date
    if [[ "$NextReminderEpochTime" && "$NagDate" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" && "$CurrentRunEpochTime" -ge "$NagDate" ]] || [[ -z "$NextReminderEpochTime" && "$NagDate" && "$CurrentRunEpochTime" -ge "$NagDate" ]]; then
        Helper=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "$JamfHelperTitle" -description "$NaggingNotification" -button1 "Proceed" -button2 "Postpone" -cancelButton "2" -defaultButton 2 -timeout "$TimeOutinSec")
        echo "Jamf Helper Exit Code: $Helper"
        
        checkAttemptToQuit "$Helper"
        
        # User clicked More Info
        if [[ "$Helper" == 2 ]]; then
            openMoreInfoURL
            
            # Set next reminder to renotify period
            setNextReminderTime "$RenotifyPeriod"
            exit 0
        fi
        
        # Set next reminder to 1 hour to provide user time to update via GUI
        setNextReminderTime "3600"
        
        # Opening Software Update
        updateGUI
        
        exit 0
    fi
}

isReadyForReminder(){
    # Switch variable to record whether next reminder has been changed
    NextReminderJustChanged="false"
    
    # If no reminder is set, set a reminder and record reminder change in a variable
    [[ -z "$NextReminderEpochTime" ]] && setNextReminderTime "$RenotifyPeriod" && NextReminderJustChanged="true"
    
# 
# [[ "$NextReminderEpochTime" && "$NagDate" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" && "$CurrentRunEpochTime" -ge "$NagDate" ]] ||
# [[ -z "$NextReminderEpochTime" && "$NagDate" && "$CurrentRunEpochTime" -ge "$NagDate" ]]
    
    # Provide a reminder notification at this point based on whether the following criteria is met:
    # Current time is greater than the next reminder time, or
    # We are passed the start date for reminders to get triggered
    if [[ "$NextReminderJustChanged" == "false" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" ]] || [[ "$NextReminderJustChanged" == "true" && "$StartDate" && "$CurrentRunEpochTime" -ge "$StartDate" ]]; then
        Helper="$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "$JamfHelperTitle" -description "$ReminderNotification" -showDelayOptions "$DelayOptions" -button1 "Proceed" -button2 "More Info" -cancelButton "2" -defaultButton 1 -timeout "$TimeOutinSec")"
        echo "Jamf Helper Exit Code: $Helper"
        
        TimeChosen="${Helper%?}"; echo "TimeChosen: $TimeChosen"
        ButtonClicked="${Helper: -1}"; echo "ButtonClicked: $ButtonClicked"
        
        # Check if Helper is 239
        # Regardless of button pressed, ButtonClicked will always be either  "1" or "2"
        # if TimeChosen is empty then TimeChosen will be "nil" and it means user opted to start upgrade immediately ("0")
        # if TimeChosen is not empty then TimeChosen will be delay value (e.g. "3600, 14400, 86400").
        
        checkAttemptToQuit "$Helper"
        
        # User decided to ask for More Info
        if [[ "$ButtonClicked" == "2" ]]; then
            echo "User opted to get more info."
            openMoreInfoURL
            
            incrementTimesIgnored
            
            # Restarting policy now that the user has more info
            # Expectation is for user to pick time and click Proceed
#             "$jamf" policy -event "$CustomTriggerNameDeprecationPolicy"
#             exit 0
        fi
        
        # User decided to proceed with OS update immediately or dialog timed out
        if [[ "$ButtonClicked" == "1" ]] && [[ -z "$TimeChosen" ]]; then
            echo "User selected to start OS update immediately."
            
            # Set next reminder time for 1 hour to allow installer to run
            setNextReminderTime "3600"
            
            updateGUI
            
            exit 0
        fi
        
        # Set next reminder time
        setNextReminderTime "$TimeChosen"
    fi
}

updateGUI(){
    # If dealing with major OS upgrades, take different action vs showing Software Update page
    if [[ "$UpdateAction" == "major" ]]; then
        takeUpgradeAction
    else
        # Update through the GUI for minor OS updates
        if [[ "$OSMajorVersion" -ge 11 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 14 ]]; then
            /bin/launchctl $LMethod $LID /usr/bin/open "/System/Library/CoreServices/Software Update.app"
        elif [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 8 && "$OSMinorVersion" -le 13 ]]; then
            /bin/launchctl $LMethod $LID /usr/bin/open macappstore://showUpdatesPage
        fi
    fi
}

checkLogEndTime(){
    # Determine whether we are doing a major or minor update
    # The process "osinstallersetupd" is monitored when performing major updates
    # The process "softwareupdated" is monitored when performing minor updates
    
    # Last time of activity for softwareupdated/osinstallersetupd
    LastLogEndTime="$(/usr/bin/log stats --process "$ProcessToCheck" | /usr/bin/awk '/end:/{ gsub(/^end:[ \t]*/, "", $0); print}')"
    LastLogEndTimeInEpoch="$(/bin/date -jf "%a %b %d %T %Y" "$LastLogEndTime" +"%s")"
    
    # Add a buffer period of time to last activity end time for softwareupdated
    # There can be 2-3 minute gaps of inactivity 
    # Buffer period = 3 minutes/180 seconds
    let LastLogEndTimeInEpochWithBuffer=$LastLogEndTimeInEpoch+180
    
    echo "$LastLogEndTimeInEpochWithBuffer"
}

refreshSoftwareUpdateList(){
    # Restart the softwareupdate daemon to ensure latest updates are being picked up
    /bin/launchctl kickstart -k system/com.apple.softwareupdated
    
    # Allow a few seconds for daemon to startup
    /bin/sleep 3
    
    # Store list of software updates in /tmp which gets cleared periodically by the OS and on restarts
    /usr/sbin/softwareupdate -l 2>&1 > "$ListOfSoftwareUpdates"
    
    setPlistValue "$BundleID" "LastUpdateCheckEpochTime" "integer" "$CurrentRunEpochTime" "$DeprecationPlist"
    
    # Variables to capture whether updates require a restart or not
    UpdatesNoRestart=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -i recommended | /usr/bin/grep -v -i restart | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//' | /usr/bin/sed -e 's/^Title:\ *//')
    RestartRequired=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -i restart | /usr/bin/grep -v '\*' | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//' | /usr/bin/sed -e 's/^Title:\ *//')
}

checkForSoftwareUpdates(){
    # To avoid checking for updates at every check-in
    # Track the last time an update was checked
    # If update was performed within X hours, do not check for updates
    
    # Exit if script is for major updates
    [[ "$UpdateAction" == "major" ]] && return 0
    
    # Compare the difference between now and the last time the script was run
    # If more than 4 hours have passed, check for updates again
    let TimeDiff=$CurrentRunEpochTime-$LastUpdateCheckEpochTime
    if [[ ! -e "$ListOfSoftwareUpdates" ]] || [[ $TimeDiff -gt 14400 ]] || [[ $LastUpdateCheckEpochTime -eq 0 ]]; then
        refreshSoftwareUpdateList
    fi
    
    # Variables to capture whether updates require a restart or not
    UpdatesNoRestart=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -i recommended | /usr/bin/grep -v -i restart | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//' | /usr/bin/sed -e 's/^Title:\ *//')
    RestartRequired=$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -i restart | /usr/bin/grep -v '\*' | /usr/bin/cut -d , -f 1 | /usr/bin/sed -e 's/^[[:space:]]*//' | /usr/bin/sed -e 's/^Title:\ *//')
    
    # Install updates that do not require a restart
    # A simple stop gap to see if either Safari or iTunes process is running.
    if [[ "$UpdatesNoRestart" && -z "$RestartRequired" ]]; then
        if [[ "$(/bin/ps -axc | /usr/bin/grep -e Safari$)" ]]; then
            echo "Safari is running. Will not attempt to install software update that does not require restart."
            exit 0
        fi
        if [[ "$(/bin/ps -axc | /usr/bin/grep -e iTunes$)" ]]; then
            echo "iTunes is running. Will not attempt to install software update that does not require restart."
            exit 0
        fi
        
        echo "Attempting install of software update that does not require restart."
        
        # Capture value of CLI install of updates
        SU_EC="$(updateCLI)"
        
        if [[ "$SU_EC" -ne 0 ]]; then
            echo "Attempt to install software update(s) that did not require restart failed."
            echo "/usr/bin/softwareupdate failed. Exit Code: $SU_EC"
        fi
        
        # Refresh software update list now that updates have been installed silently in the background
        refreshSoftwareUpdateList
        
        exit 0
    fi
    
    # Exit if no updates are available
    if [[ -z "$RestartRequired" ]] && [[ -z "$UpdatesNoRestart" ]]; then
        echo "No updates available."
        
        # Reset deferrals to 0
        setPlistValue "$BundleID" "Deferral" "integer" "0" "$DeprecationPlist"
        
        # Reset Display Sleep Assertions Encountered to 0
        setPlistValue "$BundleID" "DisplaySleepAssertionsEncountered" "integer" "0" "$DeprecationPlist"
        exit 0
    fi
}

forceGUISoftwareUpdate(){
    # This function aims to force an upgrade/update through the GUI
    # Ask the user to install update through GUI with shutdown warning if not completed within X time
    # After X time has passed, check to see if update is in progress.
    # If not in progress, force shutdown.
    
    # For Apple Silicon Macs, this is necessary since CLI install of updates is not possible
    # The same goes for OS upgrades where the user is expected to install macOS upgrade outside of Jamf
    
    # -Since ForceUpdateScheduledEndTimeInEpoch is based on recorded value
    # Make sure the difference between the current time and ForceUpdateScheduledEndTimeInEpoch is greater than 30 minutes (1800 seconds)
    # otherwise user will not have enough time to perform GUI update
    # -Check against an empty ForceUpdateScheduledEndTimeInEpoch
    # Possible reasons it may not exist include:
    #   ForceUpdateStartTimeInEpoch value was reset
    #   Script was interrupted and never finished
    if [[ -z "$ForceUpdateStartTimeInEpoch" ]] || [[ "$ForceUpdateStartTimeInEpoch" -eq 0 ]] || [[ "$(($((ForceUpdateStartTimeInEpoch+$TimeOutinSec))-$CurrentRunEpochTime))" -lt 1800 ]]; then
        # Determine the current start time in epoch seconds for forced update via GUI
        ForceUpdateStartTimeInEpoch="$(/bin/date -jf "%a %b %d %T %Z %Y" "$(/bin/date)" +"%s")"
        ForceUpdateStartTimeString="$(/bin/date -r $ForceUpdateStartTimeInEpoch +"%a %b %d %T %Z %Y")"
        
        echo "Start Time For Force Update: $ForceUpdateStartTimeString"
        
        # Record the start time for forced update via GUI the plist 
        setPlistValue "$BundleID" "ForceUpdateStartEpochTime" "integer" "$ForceUpdateStartEpochTime" "$DeprecationPlist"
        setPlistValue "$BundleID" "ForceUpdateStartTimeString" "integer" "$ForceUpdateStartTimeString" "$DeprecationPlist"
    fi
    
    # If the IT admin provided a time out period less than 1 hour, reset to 1 hour to
    # provide user time to perform update/upgrade.
    [[ "$TimeOutinSec" -lt 3600 ]] && TimeOutinSec="3600"
    
    # Calculate scheduled end time for forced update via GUI
    let ForceUpdateScheduledEndTimeInEpoch=$ForceUpdateStartTimeInEpoch+$TimeOutinSec
    
    # If someone is logged in and they run out of deferrals, prompt them to install updates that require a restart via GUI with warning that shutdown will occur.
    Helper=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "$JamfHelperTitle" -description "$FinalCallNotificationForGUIUpdate" -button1 "Proceed" -defaultButton 1 -timeout "$TimeOutinSec" -countdown -alignCountdown "right")
    echo "Jamf Helper Exit Code: $Helper"
    
    checkAttemptToQuit "$Helper"
    
    # If they click "Update" then take them to the software update preference pane
    if [ "$Helper" -eq 0 ]; then
        updateGUI
    fi
    
    echo "Waiting until time out period for forced GUI install has passed."
    
    # Wait until the time out period for forced GUI installs has passed
    while [[ "$(/bin/date +"%s")" -lt "$ForceUpdateScheduledEndTimeInEpoch" ]]; do
        sleep 60
    done
    
    echo "Time out period for forced GUI install has passed."
    
    echo "Waiting until $ProcessToCheck is no longer logging any activity."
    
    # Compare end time of last activity of softwareupdated/osinstallersetupd and if more than buffer period time has passed, proceed with shutdown
    while [[ "$(/bin/date +"%s")" -lt "$(checkLogEndTime)" ]]; do
        sleep 15
    done
    
    echo "softwareupdated is no longer logging activity."
    
    # Set the start time for forced update via GUI the plist to 0
    setPlistValue "$BundleID" "ForceUpdateStartEpochTime" "integer" "0" "$DeprecationPlist"
    
    # Let user know shutdown is taking place
    Helper=$("$jamfHelper" -windowType hud -icon "$AppleSUIcon" -title "Shut Down" -description "$ShutdownWarningMessage" -button1 "Shut Down" -defaultButton 1 -timeout "60" -countdown -alignCountdown "right")
    echo "Jamf Helper Exit Code: $Helper"
    
    # Shutdown computer
    echo "Shutting down computer"
    /sbin/shutdown -h now
}

forceSoftwareUpdate(){
    # Determine architecture
    ArchType="$(/usr/bin/arch)"
    
    # We've reached a point where an upgrade/update need to be forced
    if [[ "$ArchType" == "arm64" ]]; then
        # For Apple Silicon, we'll force an update through the GUI
        forceGUISoftwareUpdate
    else
        # For Intel Macs, an attempt to continue using CLI to install updates will be made
        # If someone is logged in and they run out of deferrals, force install updates that require a restart via CLI
        # Prompt users to let them initiate the CLI update via Jamf Helper dialog
        Helper=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "$JamfHelperTitle" -description "$FinalCallNotificationForCLIUpdate" -button1 "Proceed" -defaultButton 1 -timeout "$TimeOutinSecForForcedCLI" -countdown -alignCountdown "right")
        echo "Jamf Helper Exit Code: $Helper"
        # Either they clicked "Updates" or
        # Someone tried to quit jamfHelper or the jamfHelper screen timed out
        # The Timer is already 0, run the updates automatically, the end user has been warned!
        if [[ "$Helper" -eq "0" ]] || [[ "$Helper" -eq "239" ]]; then
            runUpdates
            RunUpdates_EC=$?
            
            if [[ $RunUpdates_EC -ne 0 ]]; then
                exit $RunUpdates_EC
            fi
        fi
    fi
}

runUpdates(){
    "$jamfHelper" -windowType hud -lockhud -title "$JamfHelperTitle" -description "$BackgroundInstallMessage""START TIME: $(/bin/date +"%b %d %Y %T")" -icon "$AppleSUIcon" &>/dev/null &
    
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
        
        "$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "$JamfHelperTitle Error" -description "$SpaceError Your disk has $AvailableFreeSpace GB of free space. $NoSpacePrompt" -button1 "OK" &
        return 12
    fi
    
    if [[ "$SU_EC" -eq 0 ]]; then
        updateRestartAction
    else
        echo "/usr/bin/softwareupdate failed. Exit Code: $SU_EC"
        
        "$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "$JamfHelperTitle" -description "$ContactMsg" -button1 "OK" &
        return 13
    fi
    
    exit 0
}


updateCLI(){
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

updateRestartAction(){
    # On T2 hardware, we need to shutdown on certain updates
    # Verbiage found when installing updates that require a shutdown:
    #   To install these updates, your computer must shut down. Your computer will automatically start up to finish installation.
    #   Installation will not complete successfully if you choose to restart your computer instead of shutting down.
    #   Please call halt(8) or select Shut Down from the Apple menu. To automate the shutdown process with softwareupdate(8), use --restart.
    
    # Determine Secure Enclave version
    SEPType="$(/usr/sbin/system_profiler SPiBridgeDataType | /usr/bin/awk -F: '/Model Name/ { gsub(/.*: /,""); print $0}')"
    
    if [[ "$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -E "Please call halt")" || "$(/bin/cat "$ListOfSoftwareUpdates" | /usr/bin/grep -E "your computer must shut down")" ]] && [[ "$SEPType" ]]; then
        if [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -eq 13 && "$OSPatchVersion" -ge 4 ]] || [[ "$OSMajorVersion" -eq 10 && "$OSMinorVersion" -ge 14 ]] || [[ "$OSMajorVersion" -ge 11 ]]; then
            # Resetting the deferral count
            setPlistValue "$BundleID" "Deferral" "integer" "0" "$DeprecationPlist"
            
            echo "Restart Action: Shutdown/Halt"
            
            /sbin/shutdown -h now
            exit 0
        fi
    fi
    # Resetting the deferral count
    setPlistValue "$BundleID" "Deferral" "integer" "0" "$DeprecationPlist"
    
    # If no shutdown is required then let's go ahead and restart
    echo "Restart Action: Restart"
    
    /sbin/shutdown -r now
    exit 0
}


checkForSoftwareUpdates
checkForLoggedInUser
checkForHIDIdleTime
checkForDisplaySleepAssertions
compareDates
isCurrentTimeLessThanStartDate
isBeyondPointOfNoReturn
isPassEndDate
isPassNagDate
isReadyForReminder

# If we've gotten this far then it is not time to prompt the user yet.
echo "Current time is $CurrentRunTimeString. User will be reminded after $NextReminderTimeString."

exit 0