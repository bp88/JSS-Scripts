#!/bin/bash

# 05/19/17
# Written by Balmes Pavlov
#
# This script is intended to be used with Jamf Pro.
# The purpose of this script is to load the JAMFHelper dialog in when a policy runs.
# Parameters will be used to determine the Window Type, Header, Description, Icon, and Button Text. They are described in full detail below.
# The JAMFHelper has many more functions beyond what's used in this script. This script was intended to cover the features I'd most likely use
# while making it flexible enough to use in multiple policies.
# 
# Parameters:
# Required: $4 is the window type used by JamfHelper. There are only three possible values: fs, hud, and utility. Note: All these window types can be exited using CMD + Q.
#    hud: creates an Apple "Heads Up Display" style window
#    utility: creates an Apple "Utility" style window
#    fs: creates a full screen window the restricts all user input
# Required: $5 is the title text used by JamfHelper for the dialog window. Does not appear in the fullscreen dialog, but you still need to fill it out.
# Required: $6 is the header text used by JamfHelper.
# Required: $7 is the description message used by JamfHelper.
# Optional: $8 is the icon path used by JamfHelper. Do not escape characters. If not using one, leave empty. Heavily recommended to use it otherwise dialogs look weird.
# e.g. /My Directory.app/icon.icns is a valid path. /My\ Directory.app/icon.icns is not a valid path.
# Optional: $9 is the text in the first button. Requires that $4 be set to "utility" or "hud" otherwise the value in this parameter will be ignored.
# Pressing the button will not have any effect other than to cause the dialog window to close.
# 
# Exit Codes:
# 1. Indicates that there is a parameter missing.
# 
# The following variable is used for JAMF Helper. While it will pick up text from JSS parameter 6, there is extra text that is hard coded which perhaps you want to modify.
#
# IT Contact Info
# You can supply an email address or contact number for your end users to contact you. This will appear in JAMF Helper dialogs.
# If left blank, it will default to just "IT" which may not be as helpful to your end users.
it_contact="IT@contoso.com"

if [[ -z "$it_contact" ]]; then
    it_contact="IT"
fi

message="${7}

This update may take up to 20 minutes, but if you're on a slower connection it can take substantially longer. If it takes longer than expected, please contact: $it_contact.

START TIME: $(/bin/date)"

# Modify the code below at your own risk.
window_type="${4}"
title="${5}"
header="${6}"
icon="${8}"
button_one="${9}"

jamfHelper="/Library/Application Support/JAMF/bin/jamfHelper.app/Contents/MacOS/jamfHelper"
path_to_jhpid="/tmp/jamfHelper_PID.txt"

display_message (){
    shopt -s nocasematch
    
    if [[ "$1" = "fs" ]]; then
        if [[ -n "$3" ]] && [[ -n "$4" ]]; then
            if [[ -z "$5" ]]; then
                "$jamfHelper" -windowType "$1" -title "$2" -heading "$3" -description "$4" & /bin/echo $! > "$path_to_jhpid"
                exit
            elif [[ -n "$5" ]]; then
                "$jamfHelper" -windowType "$1" -title "$2" -heading "$3" -description "$4" -icon "$5" & /bin/echo $! > "$path_to_jhpid"
                exit
            fi
        elif [[ -z "$2" ]] || [[ -z "$3" ]] || [[ -z "$4" ]]; then
            /bin//bin/echo "You are missing a parameter in the JSS. Please make sure to fill in all JSS parameters."
            exit 1
        fi
    elif [[ "$1" = "utility" ]] || [[ "$1" = "hud" ]]; then
        if [[ -n "$2" ]] && [[ -n "$3" ]] && [[ -n "$4" ]]; then
            if [[ -z "$5" ]] && [[ -n "$6" ]]; then
                "$jamfHelper" -windowType "$1" -title "$2" -heading "$3" -description "$4" -button1 "$6" -defaultButton 1 & /bin/echo $! > "$path_to_jhpid"
                exit
            elif [[ -z "$5" ]] && [[ -z "$6" ]]; then
                "$jamfHelper" -windowType "$1" -title "$2" -heading "$3" -description "$4" & /bin/echo $! > "$path_to_jhpid"
                exit
            elif [[ -n "$5" ]] && [[ -z "$6" ]]; then
                "$jamfHelper" -windowType "$1" -title "$2" -heading "$3" -description "$4" -icon "$5" & /bin/echo $! > "$path_to_jhpid"
                exit
            elif [[ -n "$5" ]] && [[ -n "$6" ]]; then
                "$jamfHelper" -windowType "$1" -title "$2" -heading "$3" -description "$4" -icon "$5" -button1 "$6" -defaultButton 1 & /bin/echo $! > "$path_to_jhpid"
                exit
            fi
        fi
    fi
    
    shopt -u nocasematch
}

display_message "$window_type" "$title" "$header" "$message" "$icon" "$button_one"

/bin/echo "You are missing a parameter in the JSS. Please make sure to fill in all JSS parameters."
exit 1