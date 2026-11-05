# export: xcodebuild -exportArchive with Developer ID, then check the signature and the versions.

_app_release_stage_export() {
    app_release_log "export: Developer ID"
    [[ -n $app_release_team_identifier ]] ||
        app_release_fail "no team: set release_team_identifier, or DEVELOPMENT_TEAM on $app_release_application_target"
    local export_directory=$app_release_run_directory/Export
    local export_options_path=$app_release_run_directory/ExportOptions.plist
    app_release_application_path=$export_directory/$app_release_application_name.app

    if [[ $_app_release_is_dry_run == false ]]; then
        rm -rf "$export_directory"
        if [[ -n $release_export_options_path ]]; then
            [[ -f $release_export_options_path ]] || app_release_fail "release_export_options_path: no file at $release_export_options_path"
            cp "$release_export_options_path" "$export_options_path"
        else
            _app_release_write_export_options "$export_options_path"
        fi
    fi
    if ! app_release_xcodebuild export -exportArchive -archivePath "$app_release_archive_path" \
        -exportPath "$export_directory" -exportOptionsPlist "$export_options_path"; then
        _app_release_collect_distribution_logs
        app_release_fail "xcodebuild -exportArchive failed"
    fi
    if [[ $_app_release_is_dry_run == true ]]; then
        return 0
    fi

    [[ -d $app_release_application_path ]] || app_release_fail "the export left no $app_release_application_path"
    _app_release_verify_signature "$app_release_application_path" "$app_release_team_identifier"
    _app_release_verify_bundle_versions "$app_release_application_path"
    _app_release_call_hook release_verify_export "$app_release_application_path"
    _app_release_manifest_update '.stages.export.applicationPath = $path' --arg path "$app_release_application_path"
}

# Developer ID, signed by hand with this team's certificate. Projects that need provisioning profiles
# (app groups and the like) point release_export_options_path at their own file instead.
_app_release_write_export_options() {
    local export_options_path=$1
    print -r -- '<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>Developer ID Application</string>
    <key>teamID</key>
    <string>'"$app_release_team_identifier"'</string>
</dict>
</plist>' > "$export_options_path"
    plutil -lint -s "$export_options_path" || app_release_fail "wrote an invalid $export_options_path"
}

# xcodebuild names the IDEDistribution log bundle in its output; it explains most export failures.
_app_release_collect_distribution_logs() {
    local log_path=$app_release_run_directory/logs/export.log distribution_logs
    [[ -f $log_path ]] || return 0
    distribution_logs=$(grep -oE '/[^"]+\.xcdistributionlogs' "$log_path" | tail -n 1) || return 0
    if [[ -n $distribution_logs && -d $distribution_logs ]]; then
        cp -R "$distribution_logs" "$app_release_run_directory/logs/"
        print -u2 -r -- "distribution logs: $app_release_run_directory/logs/${distribution_logs:t}"
    fi
}
