#!/bin/bash

# This script is meant to be used with Jamf Pro and makes use of Jamf Helper.
# The idea behind this script is that it alerts the user that the OS they are running is
# no longer supported. Rather than forcing updates through, this allows you to control the
# pace of notifications the user receives to perform the OS upgrade. If the user opts to
# proceed with the upgrade, they will get taken to a second policy that you've configured
# to do the OS upgrade.
#
# There are three optional dates that you can supply that will dictate the notifications the user
# receives.
# Start Date: This provides a notification to the user but also allows them to delay when
#   they will receive the next reminder.
# Nag Date: This provides a notification to the user. The user cannot select when to be
#   reminded. This will be set based on the re-notification period set by the admin.
# End Date: This provides a notification to the user when the update can take place. Once
#   this date has been reached, you can set it so that the user has X amount of attempts
#   left before they are forced to upgrade.
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
# Parameter 4: Optional. A minimum OS version to compare against what's running on the
#   client. If the client is running an OS that's the same version or greater then the
#   script will exit. Provide OS version in format of 10.14.6.
# Parameter 5: Optional. The custom trigger name for a Jamf policy that will initiate the
#   OS upgrade.
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
#   to 3 times). The user will get reminded every 24 hours until those deferrals are done.
# Parameter 10: Optional. The re-notification period before the user will get the
#   notification again. This becomes applicable when you're passed the Nag date. Default
#   to 60 minutes.
# Parameter 11: Optional. The time out period in seconds which determines how long the
#   Jamf Helper notification will stay up. Defaults to 90 minutes.
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
#   If left blank, this will default to Apple's macOS upgrade page which has been active
#   since September 2016. You can optionally use a Self Service URL as well.
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
#   deferrals left
# FinalCall: The text used when End date has been reached with no more deferrals left.
#
# There are a few exit codes in this script that may indicate points of failure:
# 10: Required parameter has been left empty.
# 11: Make sure Start date < Nag date < End date.
# 12: Minimum Supported OS Major Version is not an integer.
# 13: Minimum Supported OS Major Version is not an integer.
# 14: Incorrect property list type used. Valid types include: "array" "dict" "string"
#     "data" "date" "integer" "real" "bool"
# 15: Invalid date entered.
# 16: End Date has been provided without custom trigger.

###### ACTUAL WORKING CODE  BELOW #######
setPlistValue (){
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
            exit 14
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


readPlistValue() {
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

checkParam (){
if [[ -z "$1" ]]; then
    /bin/echo "\$$2 is empty and required. Please fill in the JSS parameter correctly."
    exit 10
fi
}

validateDate() {
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
    exit 15
}


jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
jamf="/usr/local/bin/jamf"
OSMajorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 2)"
OSMinorVersion="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d '.' -f 3)"
DeprecationPlist="/Library/Application Support/JAMF/com.custom.deprecations.plist"
BundleID="com.apple.macOS"
LoggedInUser="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')"

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

# Jamf Parameters
MinSupportedOSVersion="${4}" # Look to make optional
CustomTriggerNameForUpgradePolicy="${5}" # Look to make optional
CustomTriggerNameDeprecationPolicy="${6}"
StartDate="$(validateDate "${7}" "StartDate")"; [[ "$?" == 15 ]] && exit 15
NagDate="$(validateDate "${8}" "NagDate")"; [[ "$?" == 15 ]] && exit 15
EndDate="$(validateDate "${9}" "EndDate")"; [[ "$?" == 15 ]] && exit 15
RenotifyPeriod="${10}"
TimeOutinSec="${11}"

########### Variables You Can Modify ###########
# The number of max deferral attempts a user can make after end date
# If left blank, will default to 3
MaxDeferralAttempts=""

# Max Idle Time
# If computer has been idle longer than this time, script will exit.
# If left blank, will default to 600
MaxIdleTime=""

# URL to provide upgrade instructions
# If left blank, it will default to: https://www.apple.com/macos/how-to-upgrade/
MoreInfoURL=""

# Delay options to show user
# If left blank, will default to: Now, 1hr, 4hrs, 24hrs
DelayOptions=""

# Contact information for IT
ITContact=""
########### End Of Variables You Can Modify ###########

# Defaults if parameters left empty
[ -z "$RenotifyPeriod" ] && RenotifyPeriod="3600" # 60 mins
[ -z "$TimeOutinSec" ] && TimeOutinSec="5400" # 90 mins
[ -z "$MaxDeferralAttempts" ] && MaxDeferralAttempts="3"
[ -z "$MaxIdleTime" ] && MaxIdleTime="600" # 10 mins
[ -z "$MoreInfoURL" ] && MoreInfoURL="https://www.apple.com/macos/how-to-upgrade"
[ -z "$DelayOptions" ] && DelayOptions="0, 3600, 14400, 86400" # Now, 1hr, 4hrs, 24hrs
[ -z "$ITContact" ] && ITContact="IT"

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

# Next Reminder Time. If current time is not later than Reminder Time, we should not proceed.
NextReminderEpochTime="$(readPlistValue "$BundleID" "NextReminderEpochTime" "$DeprecationPlist")"
NextReminderTimeString="$(readPlistValue "$BundleID" "NextReminderTimeString" "$DeprecationPlist")"

# Number of times notifications have been ignored.
TimesIgnored="$(readPlistValue "$BundleID" "TimesIgnored" "$DeprecationPlist")"

# Current number of postponements left
CurrentDeferralValue="$(readPlistValue "$BundleID" "Deferral" "$DeprecationPlist")"
[[ -z "$CurrentDeferralValue" ]] && CurrentDeferralValue="0"

# Check Required Jamf Parameters
checkParam "$CustomTriggerNameDeprecationPolicy" "CustomTriggerNameDeprecationPolicy"

########### Verbiage You Can Modify ###########
if [[ "$CustomTriggerNameForUpgradePolicy" ]]; then
    StepsToUpgrade="Finder > Applications > Self Service"
else
    StepsToUpgrade="ð > App Store > search for macOS"
fi

# Default Reminder notification
ReminderNotification="Your computer is running an unsupported version of macOS. To learn more, click More Info or contact $ITContact.

You may upgrade to the latest version of macOS at any time by navigating to:

$StepsToUpgrade

Please make a selection and then click Proceed:"

# Default Nagging notification
NaggingNotification="Your computer is running an unsupported version of macOS. Click Proceed to ensure your computer is in compliance with the latest security updates. To learn more, click More Info or contact $ITContact.

You may upgrade to the latest version of macOS at any time by navigating to:

$StepsToUpgrade
"

if [[ "$EndDate" ]]; then
    NaggingNotification="$NaggingNotification
After $EndDateString, an upgrade will be enforced on this computer."
fi

# Default final notification
FinalNotification="Your computer is running an unsupported version of macOS. We are requiring that you upgrade this computer as soon as possible, but will let you postpone this by one day.

Attempts left to postpone: $(($MaxDeferralAttempts - $CurrentDeferralValue))

Please save your work and click Proceed to start the upgrade. You may upgrade to the latest version of macOS at any time by navigating to:

$StepsToUpgrade

If you have any questions or concerns, please contact $ITContact."

# Default notification for the point of no return
FinalCall="Your computer is running an unsupported version of macOS. The deadline to upgrade has passed.

Please save your work and click Proceed when ready. The upgrade will start in the time indicated below.

If you have any questions or concerns, please contact $ITContact."
########### End Of Variables You Can Modify ###########

# Function to check we're not running an older unsupported OS
checkAgainstMinSupportedOSVersion() {
    [[ -z "$MinSupportedOSVersion" ]] && return 0
    
    MinSupportedOSMajorVersion="$(echo $MinSupportedOSVersion | /usr/bin/cut -d '.' -f 2)"
    MinSupportedOSMinorVersion="$(echo $MinSupportedOSVersion | /usr/bin/cut -d '.' -f 3)"
    
    # Check if Min Supported OS major version is an integer
    if [[ ! "$MinSupportedOSMajorVersion" =~ ^[0-9]+$ ]]; then
        echo "The minimum supported OS major version $MinSupportedOSVersion is not an integer."
        exit 12
    fi
    
    # Check if Min Supported OS minor version is an integer
    if [[ ! "$MinSupportedOSMinorVersion" =~ ^[0-9]+$ ]]; then
        echo "The minimum supported OS minor version $MinSupportedOSVersion is not an integer."
        exit 13
    fi
    
    # Check if current OS version is supported
    if [[ "$OSMajorVersion" -gt "$MinSupportedOSMajorVersion" ]] || [[ "$OSMajorVersion" -eq "$MinSupportedOSMajorVersion" && "$OSMinorVersion" -ge "$MinSupportedOSMinorVersion" ]]; then
        echo "The minimum supported OS is $MinSupportedOSVersion."
        echo "This computer is running $(/usr/bin/sw_vers -productVersion) which is considered supported."
        exit 0
    fi
}

# Function to check if user is logged in
checkForLoggedInUser() {
    if [[ -z "$LoggedInUser" ]]; then
        echo "No user logged in."
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
            echo "$no_ac_power"
            /bin/sleep 60
        else
            return 0
        fi
    done
    
    echo "Exiting script as computer is not connected to power."
    exit 0
}

# Function to get current time
getCurrentTime() {
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

incrementTimesIgnored() {
    let TimesIgnored=$TimesIgnored+1
    
    setPlistValue "$BundleID" "TimesIgnored" "integer" "$TimesIgnored" "$DeprecationPlist"
}

openMoreInfoURL() {
    # Open More Info URL in web browser
    /usr/bin/sudo -u "$LoggedInUser" /usr/bin/open "$MoreInfoURL"
}

# Function to check for idle time
checkForHIDIdleTime() {
    Idle="$(/usr/sbin/ioreg -c IOHIDSystem | /usr/bin/awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')"
    
    if [[ "$Idle" -gt "$MaxIdleTime" ]]; then
        echo "Idle Time: $Idle seconds"
        echo "Exiting script since the computer has been idle for $Idle seconds."
        exit 0
    fi
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
        
        # Track the number of display sleep assertions encountered
        DisplaySleepAssertionsEncountered="$(readPlistValue "$BundleID" "DisplaySleepAssertionsEncountered" "$DeprecationPlist")"
        [[ -z "$DisplaySleepAssertionsEncountered" ]] && DisplaySleepAssertionsEncountered="0"
        
        setPlistValue "$BundleID" "DisplaySleepAssertionsEncountered" "integer" "$DisplaySleepAssertionsEncountered" "$DeprecationPlist"
        
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

compareDates() {
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

isCurrentTimeLessThanStartDate() {
    # Check if current time is greater than the Start Date
    if [[ "$StartDate" && "$CurrentRunEpochTime" -lt "$StartDate" ]]; then
        echo "We have not yet reached the Start Date $StartDateString"
        exit 0
    fi
}

isImpossibleToForce() {
    # If no custom trigger has been provided, we can only reminder or nag user
    if [[ "$EndDate" && -z "$CustomTriggerNameForUpgradePolicy" ]]; then
        echo "End date has been provided without a custom trigger to force upgrade."
        echo "Remove end date deadline or provide a custom trigger to force upgrade."
        exit 16
    fi
}

takeUpgradeAction(){
    # If no custom trigger has been provided, we can only reminder or nag user
    if [[ "$CustomTriggerNameForUpgradePolicy" ]]; then
        "$jamf" policy -event "$CustomTriggerNameForUpgradePolicy" -randomDelaySeconds 0
    else
        /usr/bin/open "macappstore://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?q=apple macos&mt=12"
    fi
}

isBeyondPointOfNoReturn() {
    # Check if we're passed the End Date and no deferral attempts are left
    if [[ "$NextReminderEpochTime" && "$EndDate" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" && "$CurrentRunEpochTime" -ge "$EndDate" ]] && [[ -z "$NextReminderEpochTime" && "$CurrentDeferralValue" -ge "$MaxDeferralAttempts" ]] || [[ "$EndDate" && "$CurrentRunEpochTime" -ge "$EndDate" ]] && [[ "$CurrentDeferralValue" -ge "$MaxDeferralAttempts" ]]; then
        "$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Running Unsupported Software" -description "$FinalCall" -button1 "Proceed" -defaultButton 1 -timeout "$TimeOutinSec" -countdown -alignCountdown "right"
        
        # Running OS upgrade policy
        "$jamf" policy -event "$CustomTriggerNameForUpgradePolicy" -randomDelaySeconds 0
        
        exit 0
    fi
}

isPassEndDate() {
    # Check if we're passed the End Date
    if [[ "$NextReminderEpochTime" && "$EndDate" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" && "$CurrentRunEpochTime" -ge "$EndDate" ]] || [[ -z "$NextReminderEpochTime" && "$EndDate" && "$CurrentRunEpochTime" -ge "$EndDate" ]]; then
        Helper=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Running Unsupported Software" -description "$FinalNotification" -button1 "Proceed" -button2 "Postpone" -cancelButton "2" -defaultButton 2 -timeout "$TimeOutinSec")
        echo "Jamf Helper Exit Code: $HELPER"
        
        checkAttemptToQuit "$Helper"
        
        # User clicked More Info
        if [[ "$Helper" == 2 ]]; then
            # Set next reminder to 24 hour
            setNextReminderTime
            
            # Increment postponement
            let CurrentDeferralValue=$CurrentDeferralValue+1
            
            getCurrentTime
            
            setPlistValue "$BundleID" "LastRunEpochTime" "integer" "$CurrentRunTimeString" "$Plist"
            setPlistValue "$BundleID" "Deferral" "integer" "$CurrentDeferralValue" "$Plist"
            
            incrementTimesIgnored
            
            # Open More Info URL
            openMoreInfoURL
            
            exit 0
        fi
        
        # Running OS upgrade policy
        "$jamf" policy -event "$CustomTriggerNameForUpgradePolicy" -randomDelaySeconds 0
        
        exit 0
    fi
}

isPassNagDate() {
    # Check if we're passed the Nagging Date
    if [[ "$NextReminderEpochTime" && "$NagDate" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" && "$CurrentRunEpochTime" -ge "$NagDate" ]] || [[ -z "$NextReminderEpochTime" && "$NagDate" && "$CurrentRunEpochTime" -ge "$NagDate" ]]; then
        Helper=$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Running Unsupported Software" -description "$NaggingNotification" -button1 "Proceed" -button2 "More Info" -cancelButton "2" -defaultButton 2 -timeout "$TimeOutinSec")
        echo "Jamf Helper Exit Code: $HELPER"
        
        checkAttemptToQuit "$Helper"
        
        # User clicked More Info
        if [[ "$Helper" == 2 ]]; then
            openMoreInfoURL
            
            # Set next reminder to renotify period
            setNextReminderTime "$RenotifyPeriod"
            exit 0
        fi
        
        # Running OS upgrade policy or pointing to the App Store
        takeUpgradeAction
        
        exit 0
    fi
}

isReadyForReminder() {
    # Variable to record whether next reminder has been changed
    NextReminderJustChanged="false"
    
    # If no reminder is set, set a reminder and record reminder change in a variable
    [[ -z "$NextReminderEpochTime" ]] && setNextReminderTime "$RenotifyPeriod" && NextReminderJustChanged="true"
    
    # Provide a reminder notification at this point based on whether the following criteria is met:
    # Current time is greater than the next reminder time, or
    # We are passed the start date for reminders to get triggered
    if [[ "$NextReminderJustChanged" == "false" && "$CurrentRunEpochTime" -ge "$NextReminderEpochTime" ]] || [[ "$NextReminderJustChanged" == "true" && "$StartDate" && "$CurrentRunEpochTime" -ge "$StartDate" ]]; then
        Helper="$("$jamfHelper" -windowType utility -icon "$AppleSUIcon" -title "Running Unsupported Software" -description "$ReminderNotification" -showDelayOptions "$DelayOptions" -button1 "Proceed" -button2 "More Info" -cancelButton "2" -defaultButton 2 -timeout "$TimeOutinSec")"
        echo "Jamf Helper Exit Code: $Helper"
        
        TimeChosen="${Helper%?}"; echo "TimeChosen: $TimeChosen"
        ButtonClicked="${Helper: -1}"; echo "ButtonClicked: $ButtonClicked"
        
        # Check if Helper is 239
        # Regardless of button pressed, ButtonClicked will always be either  "1" or "2"
        # if TimeChosen is empty then TimeChosen will be "nil" and it means user opted to start upgrade immediately
        # if TimeChosen is not empty then TimeChosen will have value "3600, 14400, 86400"
        
        checkAttemptToQuit "$Helper"
        
        # User decided to ask for More Info
        if [[ "$ButtonClicked" == "2" ]]; then
            echo "User clicked More Info button."
            openMoreInfoURL
            
            incrementTimesIgnored
        fi
        
        # User decided to proceed with OS upgrade immediately
        if [[ "$ButtonClicked" == "1" ]] && [[ -z "$TimeChosen" ]]; then
            echo "User selected to start OS upgrade immediately."
            takeUpgradeAction
            exit 0
        fi
        
        # Set next reminder time
        setNextReminderTime "$TimeChosen"
    else
        echo "Current time is $CurrentRunTimeString. User will be reminded after $NextReminderTimeString."
        exit 0
    fi
}

checkAgainstMinSupportedOSVersion
checkForLoggedInUser
checkPower
checkForDisplaySleepAssertions
checkForHIDIdleTime
compareDates
isCurrentTimeLessThanStartDate
isImpossibleToForce
isBeyondPointOfNoReturn
isPassEndDate
isPassNagDate
isReadyForReminder

exit 0