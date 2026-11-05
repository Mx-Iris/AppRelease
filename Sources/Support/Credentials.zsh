# Signing, notarization and Sparkle credentials.
#
# Locally the login keychain holds the Developer ID identity, notarytool reads a keychain profile, and
# generate_appcast reads the Sparkle key from the keychain. On CI (APP_RELEASE_CERTIFICATE_BASE64 set)
# everything arrives in environment variables: the engine builds a temporary keychain and key files,
# and removes them when it exits, whether it succeeded or not.

typeset -g _app_release_credentials_directory=
typeset -g _app_release_keychain_path=
typeset -ga _app_release_original_keychains=()
typeset -ga _app_release_installed_profiles=()
typeset -ga app_release_notary_credentials=()
typeset -g _app_release_sparkle_key_path=

_app_release_uses_ci_credentials() {
    [[ -n ${APP_RELEASE_CERTIFICATE_BASE64:-} ]]
}

_app_release_ensure_credentials_directory() {
    if [[ -z $_app_release_credentials_directory ]]; then
        _app_release_credentials_directory=$(mktemp -d "${TMPDIR:-/tmp}/AppRelease.XXXXXX")
        chmod 700 "$_app_release_credentials_directory"
    fi
}

# Called before each stage; each step only happens once per run of the engine.
_app_release_prepare_credentials_for() {
    local stage=$1
    case $stage in
        (target)
            # The keychain must exist before the identity check, and before archive signs anything.
            if _app_release_uses_ci_credentials && _app_release_scope_includes archive; then
                _app_release_create_temporary_keychain
            fi
            ;;
        (archive|export)
            if _app_release_uses_ci_credentials; then
                _app_release_create_temporary_keychain
            fi
            ;;
        (notary)
            _app_release_resolve_notary_credentials
            ;;
        (product)
            if [[ $_app_release_publishes == true ]]; then
                _app_release_prepare_sparkle_key
            fi
            ;;
    esac
}

_app_release_create_temporary_keychain() {
    if [[ -n $_app_release_keychain_path ]]; then
        return 0
    fi
    if [[ $_app_release_is_dry_run == true ]]; then
        app_release_detail "dry run: the temporary CI keychain is not created"
        return 0
    fi
    _app_release_ensure_credentials_directory
    local keychain_password certificate_path=$_app_release_credentials_directory/certificate.p12
    keychain_password=$(uuidgen)
    print -rn -- "$APP_RELEASE_CERTIFICATE_BASE64" | base64 --decode > "$certificate_path"
    _app_release_keychain_path=$_app_release_credentials_directory/AppRelease.keychain-db
    security create-keychain -p "$keychain_password" "$_app_release_keychain_path"
    # Lock after six hours, never on sleep: -l would lock it when the runner sleeps and leave codesign
    # waiting on a password prompt nobody answers (RuntimeViewer lost 40 minutes to that).
    security set-keychain-settings -u -t 21600 "$_app_release_keychain_path"
    security unlock-keychain -p "$keychain_password" "$_app_release_keychain_path"
    security import "$certificate_path" -k "$_app_release_keychain_path" \
        -P "${APP_RELEASE_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security > /dev/null
    rm -f "$certificate_path"
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" \
        "$_app_release_keychain_path" > /dev/null
    _app_release_original_keychains=(${(f)"$(security list-keychains -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')"})
    security list-keychains -d user -s "$_app_release_keychain_path" "${_app_release_original_keychains[@]}"
    app_release_detail "created a temporary keychain for the CI signing identity"
    _app_release_install_provisioning_profiles
}

# Installs every APP_RELEASE_PROVISIONING_PROFILE_<NAME>_BASE64 into both places Xcode has read
# profiles from over the years.
_app_release_install_provisioning_profiles() {
    local variable_name profile_name profile_directory profile_path
    local -a profile_directories=(
        "$HOME/Library/MobileDevice/Provisioning Profiles"
        "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    )
    for variable_name in ${(ko)parameters}; do
        [[ $variable_name == APP_RELEASE_PROVISIONING_PROFILE_*_BASE64 ]] || continue
        profile_name=${${variable_name#APP_RELEASE_PROVISIONING_PROFILE_}%_BASE64}
        for profile_directory in "${profile_directories[@]}"; do
            mkdir -p "$profile_directory"
            profile_path=$profile_directory/AppRelease-$profile_name.provisionprofile
            print -rn -- "${(P)variable_name}" | base64 --decode > "$profile_path"
            _app_release_installed_profiles+=("$profile_path")
        done
        app_release_detail "installed the provisioning profile $profile_name"
    done
}

_app_release_resolve_notary_credentials() {
    if (( ${#app_release_notary_credentials} )); then
        return 0
    fi
    if [[ -n ${APP_RELEASE_NOTARY_KEY_BASE64:-} ]]; then
        [[ -n ${APP_RELEASE_NOTARY_KEY_IDENTIFIER:-} ]] ||
            app_release_fail "APP_RELEASE_NOTARY_KEY_BASE64 needs APP_RELEASE_NOTARY_KEY_IDENTIFIER (the App Store Connect key ID)"
        _app_release_ensure_credentials_directory
        local key_path=$_app_release_credentials_directory/AuthKey.p8
        print -rn -- "$APP_RELEASE_NOTARY_KEY_BASE64" | base64 --decode > "$key_path"
        app_release_notary_credentials=(--key "$key_path" --key-id "$APP_RELEASE_NOTARY_KEY_IDENTIFIER")
        # Team keys need the issuer; individual keys must not pass one.
        if [[ -n ${APP_RELEASE_NOTARY_ISSUER_IDENTIFIER:-} ]]; then
            app_release_notary_credentials+=(--issuer "$APP_RELEASE_NOTARY_ISSUER_IDENTIFIER")
        fi
        return 0
    fi
    local profile=${APP_RELEASE_NOTARY_KEYCHAIN_PROFILE:-$release_notary_keychain_profile}
    [[ -n $profile ]] ||
        app_release_fail "no notarization credentials: set release_notary_keychain_profile in Release.zsh to the name given to xcrun notarytool store-credentials, or set APP_RELEASE_NOTARY_KEY_BASE64 and APP_RELEASE_NOTARY_KEY_IDENTIFIER"
    app_release_notary_credentials=(--keychain-profile "$profile")
}

_app_release_prepare_sparkle_key() {
    if [[ -n $_app_release_sparkle_key_path || -z ${APP_RELEASE_SPARKLE_PRIVATE_KEY:-} ]]; then
        return 0
    fi
    _app_release_ensure_credentials_directory
    _app_release_sparkle_key_path=$_app_release_credentials_directory/sparkle-private-key
    print -rn -- "$APP_RELEASE_SPARKLE_PRIVATE_KEY" > "$_app_release_sparkle_key_path"
}

# Runs from the EXIT trap, also after a failure, so nothing here may stop it halfway.
_app_release_clean_up_credentials() {
    setopt local_options no_err_exit
    if [[ -n $_app_release_keychain_path ]]; then
        if (( ${#_app_release_original_keychains} )); then
            security list-keychains -d user -s "${_app_release_original_keychains[@]}" 2> /dev/null
        fi
        security delete-keychain "$_app_release_keychain_path" 2> /dev/null
        _app_release_keychain_path=
    fi
    local profile_path
    for profile_path in "${_app_release_installed_profiles[@]}"; do
        rm -f "$profile_path"
    done
    _app_release_installed_profiles=()
    if [[ -n $_app_release_credentials_directory && -d $_app_release_credentials_directory ]]; then
        rm -rf "$_app_release_credentials_directory"
    fi
    _app_release_credentials_directory=
}
