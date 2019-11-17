#!/bin/zsh

# 11/13/19
# Written by Balmes Pavlov
#
# "tccutil reset All" does not quite work as you'd expect it to in 10.14.
# Therefore we need to create reset each service one by one which is time consuming.
# There's 40 services as of 10.15. I hope to update this in future OS versions with
# whatever additional services get added.
# Note: Location seems to always error out. If you can figure out why, drop me a note.
#
# To determine the list of services make sure you have Xcode CLI tools and run:
# strings /System/Library/PrivateFrameworks/TCC.framework/TCC | grep "^kTCCService[^ ]*$"
# Hopefully it continues to work in future OS versions
#
# Original inspiration: https://gist.github.com/haircut/aeb22c853b0ae4b483a76320ccc8c8e9
# Why? Because no one knows what Python's future on macOS is.

# Determine macOS major version
os_major_ver="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d . -f 2)"

# List of all TCC services as of macOS 10.14
tcc_service_list14=(
    "All"  #10.14+
    "AddressBook"  #10.14+
    "Calendar"  #10.14+
    "Reminders"  #10.14+
    "Twitter"  #10.14+
    "Facebook"  #10.14+
    "SinaWeibo"  #10.14+
    "Liverpool"  #10.14+
    "Ubiquity"  #10.14+
    "TencentWeibo"  #10.14+
    "ShareKit"  #10.14+
    "Photos"  #10.14+
    "PhotosAdd"  #10.14+
    "Microphone"  #10.14+
    "Camera"  #10.14+
    "Willow"  #10.14+
    "MediaLibrary"  #10.14+
    "Siri"  #10.14+
    "AppleEvents"  #10.14+
    "LinkedIn"  #10.14+
    "Accessibility"  #10.14+
    "PostEvent"  #10.14+
    "Location"  #10.14+
    "SystemPolicyAllFiles"  #10.14+
    "SystemPolicySysAdminFiles"  #10.14+
    "SystemPolicyDeveloperFiles"  #10.14+
)

# List of all additional TCC services as of macOS 10.15
tcc_service_list15=(
    "ContactsLimited"  #10.15+
    "ContactsFull"  #10.15+
    "Motion"  #10.15+
    "SpeechRecognition"  #10.15+
    "ListenEvent"  #10.15+
    "SystemPolicyRemovableVolumes"  #10.15+
    "SystemPolicyNetworkVolumes"  #10.15+
    "SystemPolicyDesktopFolder"  #10.15+
    "SystemPolicyDownloadsFolder"  #10.15+
    "SystemPolicyDocumentsFolder"  #10.15+
    "ScreenCapture"  #10.15+
    "DeveloperTool"  #10.15+
    "FileProviderPresence"  #10.15+
    "FileProviderDomain"  #10.15+
)

# Generate empty array that will determine which services to reset
tcc_service_list=()

[[ $os_major_ver -le 13 ]] && echo "Unsupported OS" && exit 0
[[ $os_major_ver -ge 14 ]] && tcc_service_list+=($tcc_service_list14)
[[ $os_major_ver -ge 15 ]] && tcc_service_list+=($tcc_service_list15)

# Loop through all services and reset them
for svc in $tcc_service_list; do
    /usr/bin/tccutil reset "$svc" 2>/dev/null
    
    # Provide feedback on success of reset
    if [[ $? -eq 0 ]]; then
        echo "Successful Reset: $svc"
    else
        echo "Failed     Reset: $svc"
    fi
done