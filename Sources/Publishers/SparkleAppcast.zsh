# sparkle-appcast: merges this release into the project's appcast (Sparkle's update feed) with Sparkle's
# own generate_appcast, then hands the file to the release_deploy_appcast hook to put online.

_app_release_publish_sparkle_appcast() {
    local application_archive_name=$1
    local appcast_path=${release_appcast_path:a} notes_path=
    if [[ $release_appcast_embeds_release_notes == true ]]; then
        # The GitHub Release's notes, which release_compose_notes has written by now if it writes them.
        _app_release_resolve_release_notes_path
        notes_path=$REPLY
    fi
    app_release_generate_appcast "$app_release_run_directory/Products/$application_archive_name" "$appcast_path" "$notes_path"

    if [[ $_app_release_is_dry_run == true ]]; then
        _app_release_call_hook release_deploy_appcast "$appcast_path"
        return 0
    fi
    if (( $+functions[release_deploy_appcast] )); then
        _app_release_call_hook release_deploy_appcast "$appcast_path"
    else
        app_release_detail "commit and deploy $appcast_path yourself, or define release_deploy_appcast in Release.zsh"
    fi
}

# app_release_generate_appcast <archive> <appcast> [<release notes>]
# Merges this release's item for <archive> into <appcast> with Sparkle's generate_appcast, as the
# sparkle-appcast publisher does for the app: the same EdDSA key, the download URL of this GitHub Release
# (so <archive> must be one of its assets), the beta channel for a prerelease, and release_appcast_arguments.
# For a second app the release ships, such as one zipped inside the first, from release_deploy_appcast. A
# release notes file (.md, .html or .txt; anything else counts as Markdown) becomes the item's description.
app_release_generate_appcast() {
    local archive_path=${1:-} appcast_path=${2:-} notes_path=${3:-}
    [[ -n $archive_path && -n $appcast_path ]] ||
        app_release_fail "app_release_generate_appcast: usage: app_release_generate_appcast <archive> <appcast> [<release notes>]"
    _app_release_resolve_github_repository
    _app_release_find_generate_appcast
    local generate_appcast_path=$REPLY
    local archive_name=${archive_path:t}
    # One directory per archive, so that generate_appcast adds one item and keeps the rest of the feed.
    local staging_directory=$app_release_run_directory/Appcast/${archive_name:r}

    local -a arguments=("$staging_directory" -o "${appcast_path:a}"
        --download-url-prefix "https://github.com/$app_release_github_repository/releases/download/$app_release_tag/")
    if [[ $app_release_is_prerelease == true ]]; then
        arguments+=(--channel beta)
    fi
    if [[ -n $_app_release_sparkle_key_path ]]; then
        arguments+=(--ed-key-file "$_app_release_sparkle_key_path")
    fi
    local notes_name=
    if [[ -n $notes_path ]]; then
        # generate_appcast takes the notes of an archive from the file of the same name beside it.
        case ${notes_path:e} in
            (md|html|txt) notes_name=${archive_name:r}.${notes_path:e} ;;
            (*) notes_name=${archive_name:r}.md ;;
        esac
        arguments+=(--embed-release-notes)
    fi
    arguments+=("${release_appcast_arguments[@]}")

    if [[ $_app_release_is_dry_run == true ]]; then
        if [[ -n $notes_name ]]; then
            app_release_detail "dry run: would embed the release notes $notes_path as $notes_name"
        fi
        _app_release_run "$generate_appcast_path" "${arguments[@]}"
        return 0
    fi
    [[ -f $archive_path ]] || app_release_fail "app_release_generate_appcast: no archive at $archive_path"
    if [[ -n $notes_path && ! -s $notes_path ]]; then
        app_release_fail "app_release_generate_appcast: no release notes at $notes_path (missing or empty)"
    fi
    rm -rf "$staging_directory"
    mkdir -p "$staging_directory"
    cp "$archive_path" "$staging_directory/"
    if [[ -n $notes_name ]]; then
        cp "$notes_path" "$staging_directory/$notes_name"
    fi
    mkdir -p "$app_release_run_directory/logs"
    local generate_log=$app_release_run_directory/logs/generate_appcast-${archive_name:r}.log
    if ! "$generate_appcast_path" "${arguments[@]}" > "$generate_log" 2>&1; then
        cat "$generate_log" >&2
        app_release_fail "generate_appcast failed for $archive_name (log: $generate_log)"
    fi
    rm -rf "$staging_directory"
    app_release_detail "updated ${appcast_path:a} with $archive_name${notes_name:+ and its release notes}"
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
