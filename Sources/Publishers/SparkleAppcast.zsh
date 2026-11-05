# sparkle-appcast: merges this release into the project's appcast (Sparkle's update feed) with Sparkle's
# own generate_appcast, then hands the file to the release_deploy_appcast hook to put online.

_app_release_publish_sparkle_appcast() {
    local application_archive_name=$1
    _app_release_resolve_github_repository
    _app_release_find_generate_appcast
    local generate_appcast_path=$REPLY
    local staging_directory=$app_release_run_directory/Appcast
    local appcast_path=${release_appcast_path:a}

    # Only this release's zip goes in, so generate_appcast adds one item and keeps the rest of the feed.
    local -a arguments=("$staging_directory" -o "$appcast_path"
        --download-url-prefix "https://github.com/$app_release_github_repository/releases/download/$app_release_tag/")
    if [[ $app_release_is_prerelease == true ]]; then
        arguments+=(--channel beta)
    fi
    if [[ -n $_app_release_sparkle_key_path ]]; then
        arguments+=(--ed-key-file "$_app_release_sparkle_key_path")
    fi
    arguments+=("${release_appcast_arguments[@]}")

    if [[ $_app_release_is_dry_run == true ]]; then
        _app_release_run "$generate_appcast_path" "${arguments[@]}"
        _app_release_call_hook release_deploy_appcast "$appcast_path"
        return 0
    fi
    rm -rf "$staging_directory"
    mkdir -p "$staging_directory"
    cp "$app_release_run_directory/Products/$application_archive_name" "$staging_directory/"
    local generate_log=$app_release_run_directory/logs/generate_appcast.log
    if ! "$generate_appcast_path" "${arguments[@]}" > "$generate_log" 2>&1; then
        cat "$generate_log" >&2
        app_release_fail "generate_appcast failed (log: $generate_log)"
    fi
    rm -rf "$staging_directory"
    app_release_detail "updated $appcast_path"

    if (( $+functions[release_deploy_appcast] )); then
        _app_release_call_hook release_deploy_appcast "$appcast_path"
    else
        app_release_detail "commit and deploy $appcast_path yourself, or define release_deploy_appcast in Release.zsh"
    fi
}

# The generate_appcast that ships with the Sparkle package the app links, so feed and framework agree;
# otherwise one on PATH.
_app_release_find_generate_appcast() {
    local packaged_tool=$app_release_derived_data_path/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast
    if [[ -x $packaged_tool ]]; then
        REPLY=$packaged_tool
    elif (( $+commands[generate_appcast] )); then
        REPLY=${commands[generate_appcast]}
    elif [[ $_app_release_is_dry_run == true ]]; then
        REPLY=generate_appcast
    else
        app_release_fail "generate_appcast not found: neither at $packaged_tool (from the Sparkle package the app links) nor on PATH"
    fi
}
