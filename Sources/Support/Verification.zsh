# Checks that the stages use as their acceptance criteria.

# Sets REPLY to a key's value in a property list; fails when the key is missing.
_app_release_read_plist_value() {
    local plist_path=$1 key=$2
    REPLY=$(plutil -extract "$key" raw -o - "$plist_path" 2> /dev/null) ||
        app_release_fail "$plist_path has no $key"
}

# An app archive names its app in ApplicationProperties. Without it the archive is a Generic Xcode
# Archive, which happens when some other target installs a product outside the app, and Developer ID
# export refuses it. Sets REPLY to the app inside the archive.
_app_release_verify_application_archive() {
    local archive_path=$1 application_path
    if ! application_path=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:ApplicationPath' "$archive_path/Info.plist" 2> /dev/null); then
        print -u2 -r -- "These products are installed outside the app; set SKIP_INSTALL = YES on their targets and let the app embed them:"
        (cd "$archive_path/Products" && find . \( -type f -o -type l \) ! -path '*.app/*' | sort | head -n 20) >&2 || true
        app_release_fail "$archive_path is a Generic Xcode Archive, not an app archive, and Developer ID export would refuse it"
    fi
    REPLY=$archive_path/Products/$application_path
    [[ -d $REPLY ]] || app_release_fail "the archive names $application_path, but $REPLY does not exist"
}

_app_release_verify_architectures() {
    local executable_path=$1
    shift
    local -a expected_architectures=("$@") actual_architectures
    actual_architectures=(${=$(lipo -archs "$executable_path")})
    if [[ ${(j: :)${(o)actual_architectures}} != ${(j: :)${(o)expected_architectures}} ]]; then
        app_release_fail "${executable_path:t} has the architectures (${actual_architectures[*]}), not the expected (${expected_architectures[*]})"
    fi
    app_release_detail "architectures: ${actual_architectures[*]}"
}

# Developer ID, from the expected team, with the hardened runtime and a secure timestamp: what the notary
# service requires, checked before minutes go into an upload it would reject.
_app_release_verify_signature() {
    local application_path=$1 team_identifier=$2
    local verification_log=$app_release_run_directory/logs/codesign-verify.log
    codesign --verify --deep --strict --verbose=2 "$application_path" > "$verification_log" 2>&1 ||
        app_release_fail "the signature of ${application_path:t} does not verify (log: $verification_log)"
    local details
    details=$(codesign --display --verbose=4 "$application_path" 2>&1)
    local line has_authority=false
    for line in "${(@f)details}"; do
        if [[ $line == "Authority=Developer ID Application: "*"($team_identifier)" ]]; then
            has_authority=true
        fi
    done
    [[ $has_authority == true ]] || app_release_fail "${application_path:t} is not signed with the Developer ID Application identity of team $team_identifier"
    [[ $details =~ 'flags=0x[0-9a-f]+\(([a-z-]+,)*runtime(,[a-z-]+)*\)' ]] ||
        app_release_fail "${application_path:t} is signed without the hardened runtime"
    [[ $details == *$'\nTimestamp='* ]] ||
        app_release_fail "${application_path:t} is signed without a secure timestamp"
    app_release_detail "signature: Developer ID ($team_identifier), hardened runtime, timestamp"
}

_app_release_verify_bundle_versions() {
    local info_plist_path=$1/Contents/Info.plist
    _app_release_read_plist_value "$info_plist_path" CFBundleShortVersionString
    [[ $REPLY == $app_release_marketing_version ]] ||
        app_release_fail "the exported app says version $REPLY, but the plan says $app_release_marketing_version"
    _app_release_read_plist_value "$info_plist_path" CFBundleVersion
    [[ $REPLY == $app_release_build_number ]] ||
        app_release_fail "the exported app says build $REPLY, but the plan says $app_release_build_number"
}

# With assessments disabled (spctl --status) spctl accepts any app, an unnotarized one included; the
# source it names is what still tells them apart.
_app_release_verify_gatekeeper() {
    local application_path=$1 verdict
    if ! verdict=$(spctl --assess --type execute --verbose=4 "$application_path" 2>&1); then
        app_release_fail "Gatekeeper rejects ${application_path:t}: $verdict"
    fi
    [[ $verdict == *"source=Notarized Developer ID"* ]] ||
        app_release_fail "Gatekeeper does not take ${application_path:t} for a notarized app: $verdict"
}

# Unpacks a product zip and checks the app inside the way a downloader's Mac would.
_app_release_verify_zipped_application() {
    local zip_path=$1 extraction_directory
    extraction_directory=$(mktemp -d "${TMPDIR:-/tmp}/AppReleaseVerify.XXXXXX")
    ditto -x -k "$zip_path" "$extraction_directory"
    local -a applications=("$extraction_directory"/*.app(N/))
    if (( ${#applications} != 1 )); then
        rm -rf "$extraction_directory"
        app_release_fail "${zip_path:t} should hold exactly one app at its top level"
    fi
    if ! xcrun stapler validate "${applications[1]}" > /dev/null 2>&1; then
        rm -rf "$extraction_directory"
        app_release_fail "the app in ${zip_path:t} carries no valid notarization ticket"
    fi
    _app_release_verify_gatekeeper "${applications[1]}"
    rm -rf "$extraction_directory"
    app_release_detail "${zip_path:t}: stapled, and Gatekeeper takes it for notarized"
}
