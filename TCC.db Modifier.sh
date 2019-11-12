#!/bin/zsh

# As soon as this is released, I'm going to guess that Apple will squash this:
# Currently options are limited for allowing camera/microphone for certain apps on
# enterprise-owned devices. You can only deny but not allow via configuration profiles.
# If you'd like to "allow" on enterprise-own devices, file feedback with Apple:
#   http://feedbackassistant.apple.com
#
# In order for this script to function, the script or the application running the script
# (e.g. Terminal, Jamf Pro) needs to have full disk access.
# I have made this script to work with Jamf Pro. However modifying it to work with other
# tools shouldn't be hard as long as you replace the Jamf parameters with the appropriate
# values.
# Couple of caveats to note:
# -kTCCServiceMicrophone, kTCCServiceCamera, kTCCServiceUbiquity live in user's TCC.db
# -You'll run into an read-only error when attempting to write to system TCC.db
#   kTCCServiceScreenCapture lives in system TCC.db.
#
# Credit goes to this discussion for helping me figure out how to generate a csreq blob
# https://stackoverflow.com/questions/52706542/how-to-get-csreq-of-macos-application-on-command-line
#
# Jamf Parameters:
# Required: Parameter $4 is used to provide the full path to the application
#           (e.g. /Application/Firefox.app)
# Required: Parameter $5 is used to provide the TCC service name.
#           See $tcc_service_list array for valid entries. Of importance to you will be:
#           "kTCCServiceMicrophone" and "kTCCServiceCamera"
#
# Exit codes:
# 1: No user is logged in
# 2: Invalid application path provided
# 3: TCC Services were not provided
# 4: The provided TCC service is invalid. See $tcc_service_list array for valid entries.


# List of all TCC services as of macOS 10.15
tcc_service_list=(
    "kTCCServiceAddressBook"
    "kTCCServiceContactsLimited"
    "kTCCServiceContactsFull"
    "kTCCServiceCalendar"
    "kTCCServiceReminders"
    "kTCCServiceTwitter"
    "kTCCServiceFacebook"
    "kTCCServiceSinaWeibo"
    "kTCCServiceLiverpool"
    "kTCCServiceUbiquity"
    "kTCCServiceTencentWeibo"
    "kTCCServiceShareKit"
    "kTCCServicePhotos"
    "kTCCServicePhotosAdd"
    "kTCCServiceMicrophone"
    "kTCCServiceCamera"
    "kTCCServiceWillow"
    "kTCCServiceMediaLibrary"
    "kTCCServiceSiri"
    "kTCCServiceMotion"
    "kTCCServiceSpeechRecognition"
    "kTCCServiceAppleEvents"
    "kTCCServiceLinkedIn"
    "kTCCServiceAccessibility"
    "kTCCServicePostEvent"
    "kTCCServiceListenEvent"
    "kTCCServiceLocation"
    "kTCCServiceSystemPolicyAllFiles"
    "kTCCServiceSystemPolicySysAdminFiles"
    "kTCCServiceSystemPolicyDeveloperFiles"
    "kTCCServiceSystemPolicyRemovableVolumes"
    "kTCCServiceSystemPolicyNetworkVolumes"
    "kTCCServiceSystemPolicyDesktopFolder"
    "kTCCServiceSystemPolicyDownloadsFolder"
    "kTCCServiceSystemPolicyDocumentsFolder"
    "kTCCServiceScreenCapture"
    "kTCCServiceDeveloperTool"
    "kTCCServiceFileProviderPresence"
    "kTCCServiceFileProviderDomain"
)

# Get current time in epoch seconds
current_time="$(/bin/date +"%s")"

# Get current logged in user
logged_in_user="$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')"

# Get current logged in user's home directory
[[ "$logged_in_user" ]] && logged_in_user_home="$(/usr/bin/dscl /Local/Default read /Users/"$logged_in_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')"

# Jamf Parameters
app_path="${4}"
service_access="${5}" 
permission="1" # allow. if you need to deny, use a configuration profile.

# Validate parameters
[[ -z "$app_path" || ! -e "$app_path" ]] && echo "Invalid application path." && exit 2
[[ -z "$service_access" ]] && echo "TCC Services not provided" && exit 3

# Variables Dependent on Jamf Parameters
app_identifier="$(/usr/libexec/PlistBuddy -c "print :CFBundleIdentifier" "$app_path"/Contents/Info.plist 2>/dev/null)"

# Generate an array of services
svc_list=($(echo $service_access))

# Function to get csreq blob
getCSREQBlob(){
    # Get the requirement string from codesign
    req_str=$(/usr/bin/codesign -d -r- "$app_path" 2>&1 | /usr/bin/awk -F ' => ' '/designated/{print $2}')
    
    # Convert the requirements string into it's binary representation
    # csreq requires the output to be a file so we just throw it in /tmp
    echo "$req_str" | /usr/bin/csreq -r- -b /tmp/csreq.bin
    
    # Convert the binary form to hex, and print it nicely for use in sqlite
    req_hex="X'$(xxd -p /tmp/csreq.bin  | /usr/bin/tr -d '\n')'"
    
    echo "$req_hex"
    
    # Remove csqeq.bin
    /bin/rm -f "/tmp/csreq.bin"
}

req_hex="$(getCSREQBlob)"

# Loop through services and provide access
for svc in $svc_list; do
    # Check to make sure that a valid TCC service was provided
    if [[ ${tcc_service_list[(ie)$svc]} -le ${#tcc_service_list} ]]; then    
        # Certain TCC services are user specific
        if [[ "$svc" == "kTCCServiceMicrophone" ]] || [[ "$svc" == "kTCCServiceCamera" ]] || [[ "$svc" == "kTCCServiceUbiquity" ]]; then
            if [[ -z "$logged_in_user" ]]; then
                echo "No user logged in. User needs to be logged in to modify their TCC.db with $svc service. Exiting script."
                exit 1
            fi
            
            /usr/bin/sqlite3 "$logged_in_user_home/Library/Application Support/com.apple.TCC/TCC.db" "INSERT or REPLACE INTO access (service,client,client_type,allowed,prompt_count,csreq,last_modified)
            VALUES('$svc','$app_identifier','0','$permission','1',$req_hex,'$current_time')"
        else
            /usr/bin/sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" "INSERT or REPLACE INTO access (service,client,client_type,allowed,prompt_count,csreq,last_modified)
            VALUES('$svc','$app_identifier','0','$permission','1',$req_hex,'$current_time')"
        fi
    else
        echo "$svc is not a valid TCC service"
        exit 4
    fi
done

exit 0