# notary: submit to the notary service, wait, staple, and check that Gatekeeper takes the app for notarized.
#
# The submission id goes into the manifest before the wait starts, so a run that times out or is
# interrupted continues with notarytool wait instead of uploading again.

typeset -gr _app_release_notary_timeout=2h

_app_release_stage_notary() {
    app_release_log "notary"
    local application_path=$app_release_application_path
    local notary_directory=$app_release_run_directory/Notary
    local submission_path=$notary_directory/$app_release_application_name.zip

    if [[ $_app_release_is_dry_run == true ]]; then
        _app_release_run ditto -c -k --sequesterRsrc --keepParent "$application_path" "$submission_path"
        _app_release_run xcrun notarytool submit "$submission_path" "${app_release_notary_credentials[@]}" --no-wait --output-format json
        _app_release_run xcrun notarytool wait '<submission id>' "${app_release_notary_credentials[@]}" --timeout $_app_release_notary_timeout
        _app_release_run xcrun stapler staple "$application_path"
        _app_release_run spctl --assess --type execute --verbose=4 "$application_path"
        return 0
    fi

    local submission_identifier submission_status
    submission_identifier=$(_app_release_manifest_value '.stages.notary.submissionIdentifier')
    submission_status=$(_app_release_manifest_value '.stages.notary.status')
    if [[ -n $submission_identifier && $submission_status != (Accepted|Invalid|Rejected) ]]; then
        app_release_detail "continuing to wait for submission $submission_identifier"
    else
        mkdir -p "$notary_directory"
        rm -f "$submission_path"
        ditto -c -k --sequesterRsrc --keepParent "$application_path" "$submission_path"
        local submission_output submission_log=$app_release_run_directory/logs/notary-submit.log
        submission_output=$(xcrun notarytool submit "$submission_path" "${app_release_notary_credentials[@]}" \
            --no-wait --output-format json 2> "$submission_log") || {
            cat "$submission_log" >&2
            app_release_fail "notarytool could not submit $submission_path"
        }
        submission_identifier=$(jq -r '.id // empty' <<< "$submission_output" 2> /dev/null) || submission_identifier=
        [[ -n $submission_identifier ]] || app_release_fail "notarytool returned no submission id: $submission_output"
        _app_release_manifest_update '.stages.notary = {submissionIdentifier: $identifier}' --arg identifier "$submission_identifier"
        app_release_detail "submitted as $submission_identifier; waiting, which usually takes a few minutes"
    fi

    # wait's own exit status is not the verdict; info's status field is.
    xcrun notarytool wait "$submission_identifier" "${app_release_notary_credentials[@]}" \
        --timeout $_app_release_notary_timeout > "$app_release_run_directory/logs/notary-wait.log" 2>&1 || true
    local submission_information
    submission_information=$(xcrun notarytool info "$submission_identifier" "${app_release_notary_credentials[@]}" \
        --output-format json 2> "$app_release_run_directory/logs/notary-info.log") ||
        app_release_fail "notarytool info failed for $submission_identifier (log: $app_release_run_directory/logs/notary-info.log)"
    submission_status=$(jq -r '.status // empty' <<< "$submission_information")
    _app_release_manifest_update '.stages.notary.status = $status' --arg status "$submission_status"

    case $submission_status in
        (Accepted)
            app_release_detail "accepted"
            ;;
        ("In Progress")
            app_release_fail "submission $submission_identifier is still in progress after $_app_release_notary_timeout; run app-release notary to keep waiting"
            ;;
        (*)
            local notary_log_path=$app_release_run_directory/logs/notary-$submission_identifier.json
            xcrun notarytool log "$submission_identifier" "${app_release_notary_credentials[@]}" "$notary_log_path" > /dev/null 2>&1 || true
            if [[ -f $notary_log_path ]]; then
                jq -r '.issues[]? | "  \(.severity // "issue"): \(.path // "-"): \(.message)"' "$notary_log_path" >&2 || true
            fi
            app_release_fail "notarization ended as ${submission_status:-unknown} (log: $notary_log_path)"
            ;;
    esac

    _app_release_staple "$application_path"
    _app_release_verify_gatekeeper "$application_path"
    app_release_detail "stapled, and Gatekeeper takes ${application_path:t} for notarized"
    rm -f "$submission_path"
}

# A ticket the service has just issued is sometimes not yet visible to stapler; retry before giving up.
_app_release_staple() {
    local application_path=$1 staple_log=$app_release_run_directory/logs/staple.log
    local -i attempt
    for (( attempt = 1; attempt <= 3; attempt++ )); do
        if xcrun stapler staple "$application_path" > "$staple_log" 2>&1; then
            break
        fi
        if (( attempt == 3 )); then
            cat "$staple_log" >&2
            app_release_fail "stapler could not staple the ticket to ${application_path:t}"
        fi
        app_release_detail "staple attempt $attempt failed; trying again in 15 seconds"
        sleep 15
    done
    xcrun stapler validate "$application_path" > /dev/null 2>&1 ||
        app_release_fail "the ticket stapled to ${application_path:t} does not validate"
}
