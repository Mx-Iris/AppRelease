# The scheme's build settings, read once by the target stage through xcodebuild -showBuildSettings.

typeset -g _app_release_build_settings_json=
typeset -gA app_release_build_settings=()
typeset -g _app_release_bundle_value_origin=

# Sets reply to -workspace <path> or -project <path>.
_app_release_location_arguments() {
    if [[ -n $release_workspace ]]; then
        reply=(-workspace "${release_workspace:a}")
    else
        reply=(-project "${release_project:a}")
    fi
}

_app_release_load_build_settings() {
    local log_path=$1
    _app_release_location_arguments
    local -a command=(xcodebuild -showBuildSettings -json "${reply[@]}" -scheme "$release_scheme"
        -configuration "$release_configuration" -destination "$release_destination"
        -derivedDataPath "$app_release_derived_data_path")
    app_release_detail "reading the build settings of $release_scheme ($release_configuration)"
    local output
    if ! output=$("${command[@]}" 2> "$log_path"); then
        tail -n 20 "$log_path" >&2
        app_release_fail "xcodebuild -showBuildSettings failed for scheme $release_scheme (log: $log_path)"
    fi
    # Package resolution can print to standard output before the JSON starts.
    _app_release_build_settings_json=$(print -r -- "$output" | sed -n '/^\[/,$p')
    jq -e 'type == "array"' <<< "$_app_release_build_settings_json" > /dev/null 2>&1 ||
        app_release_fail "xcodebuild -showBuildSettings printed no JSON array (log: $log_path)"
}

# Picks the app target: release_application_target, the only app target, or the one named like the scheme.
_app_release_resolve_application() {
    local -a application_targets
    application_targets=(${(f)"$(jq -r '.[] | select(.buildSettings.PRODUCT_TYPE == "com.apple.product-type.application") | .target' <<< "$_app_release_build_settings_json")"})
    application_targets=(${(u)application_targets})
    local target
    if [[ -n $release_application_target ]]; then
        (( ${application_targets[(Ie)$release_application_target]} )) ||
            app_release_fail "release_application_target '$release_application_target' is not an app target of scheme $release_scheme (app targets: ${application_targets[*]:-none})"
        target=$release_application_target
    elif (( ${#application_targets} == 1 )); then
        target=${application_targets[1]}
    elif (( ${application_targets[(Ie)$release_scheme]} )); then
        target=$release_scheme
    else
        app_release_fail "scheme $release_scheme builds ${#application_targets} app targets (${application_targets[*]:-none}); set release_application_target"
    fi
    app_release_application_target=$target

    app_release_build_settings=()
    local key value
    while IFS=$'\t' read -r key value; do
        app_release_build_settings[$key]=$value
    done < <(jq -r --arg target "$target" '.[] | select(.target == $target) | .buildSettings | to_entries[] | [.key, (.value | tostring)] | @tsv' <<< "$_app_release_build_settings_json")

    local full_product_name=${app_release_build_settings[FULL_PRODUCT_NAME]-}
    [[ $full_product_name == *.app ]] || app_release_fail "target $target does not build an .app (FULL_PRODUCT_NAME is '$full_product_name')"
    app_release_application_name=${full_product_name%.app}
}

# Sets REPLY to the value the built app's Info.plist will carry for plist_key: the Info.plist's own
# value, with a lone $(SETTING) resolved; or, when the Info.plist has no such key (or is generated),
# the fallback build setting. Records in _app_release_bundle_value_origin where the value came from:
# literal, setting:<NAME> or fallback.
_app_release_effective_bundle_value() {
    local plist_key=$1 fallback_setting=$2
    local info_plist_path=${app_release_build_settings[INFOPLIST_FILE]-} value=
    if [[ -n $info_plist_path ]]; then
        if [[ $info_plist_path != /* ]]; then
            info_plist_path=${app_release_build_settings[SRCROOT]-$app_release_project_directory}/$info_plist_path
        fi
        if [[ -f $info_plist_path ]]; then
            value=$(plutil -extract "$plist_key" raw -o - "$info_plist_path" 2> /dev/null) || value=
        fi
    fi
    if [[ -z $value ]]; then
        REPLY=${app_release_build_settings[$fallback_setting]-}
        _app_release_bundle_value_origin=fallback
        return 0
    fi
    if [[ $value =~ '^\$[({]([A-Za-z0-9_]+)[)}]$' ]]; then
        REPLY=${app_release_build_settings[$match[1]]-}
        _app_release_bundle_value_origin=setting:$match[1]
        return 0
    fi
    if [[ $value == *'$('* || $value == *'${'* ]]; then
        app_release_fail "the Info.plist's $plist_key is '$value'; AppRelease resolves a literal or a single \$(SETTING), nothing more"
    fi
    REPLY=$value
    _app_release_bundle_value_origin=literal
}
