# archive: xcodebuild archive, then check that it is an app archive with the expected architectures.

_app_release_stage_archive() {
    app_release_log "archive"
    _app_release_call_hook release_before_archive

    app_release_archive_path=$app_release_run_directory/$release_scheme.xcarchive
    _app_release_location_arguments
    local -a arguments=(archive "${reply[@]}" -scheme "$release_scheme" -configuration "$release_configuration"
        -destination "$release_destination" -archivePath "$app_release_archive_path"
        -derivedDataPath "$app_release_derived_data_path")
    if (( ${app_release_architectures[(Ie)x86_64]} )); then
        # Xcode 27's new package PIF builder pins every package to arm64 variants, so an x86_64 slice
        # fails to find its package modules. The old builder keeps $(inherited) architectures.
        arguments+=(-IDEEnableNewPackagePIFBuilder=NO)
    fi
    if [[ $app_release_injects_build_number == true ]]; then
        arguments+=(CURRENT_PROJECT_VERSION=$app_release_build_number)
    fi
    arguments+=("${release_archive_arguments[@]}")

    local tracked_changes_before
    tracked_changes_before=$(_app_release_git status --porcelain --untracked-files=no)
    if [[ -e $app_release_archive_path && $_app_release_is_dry_run == false ]]; then
        rm -rf "$app_release_archive_path"
    fi
    app_release_xcodebuild archive "${arguments[@]}" || app_release_fail "xcodebuild archive failed"
    if [[ $_app_release_is_dry_run == true ]]; then
        return 0
    fi

    _app_release_verify_application_archive "$app_release_archive_path"
    local application_in_archive=$REPLY
    _app_release_read_plist_value "$application_in_archive/Contents/Info.plist" CFBundleExecutable
    _app_release_verify_architectures "$application_in_archive/Contents/MacOS/$REPLY" "${app_release_architectures[@]}"
    _app_release_call_hook release_verify_archive "$app_release_archive_path"

    # Package resolution can rewrite a committed Package.resolved while archiving.
    local tracked_changes_after
    tracked_changes_after=$(_app_release_git status --porcelain --untracked-files=no)
    if [[ $tracked_changes_after != $tracked_changes_before ]]; then
        print -u2 -r -- "$tracked_changes_after"
        app_release_warn "archiving changed tracked files (listed above), so the archive may not match commit ${app_release_git_commit[1,12]}"
    fi

    _app_release_manifest_update '.stages.archive.archivePath = $archive | .stages.archive.applicationPath = $application' \
        --arg archive "$app_release_archive_path" --arg application "$application_in_archive"
}
