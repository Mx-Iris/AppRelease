# github-release: creates the release for the tag, or replaces the assets of one that already exists.

_app_release_publish_github_release() {
    _app_release_resolve_github_repository
    local -a product_paths
    if [[ $_app_release_is_dry_run == true ]]; then
        _app_release_render_template "$release_product_name"
        product_paths=("$app_release_run_directory/Products/$REPLY")
    else
        product_paths=(${(f)"$(_app_release_product_paths)"})
    fi

    if gh release view "$app_release_tag" --repo "$app_release_github_repository" > /dev/null 2>&1; then
        app_release_detail "the release $app_release_tag exists; replacing its assets"
        _app_release_run gh release upload "$app_release_tag" --repo "$app_release_github_repository" --clobber "${product_paths[@]}"
    else
        _app_release_release_notes_arguments
        local -a command=(gh release create "$app_release_tag" --repo "$app_release_github_repository"
            --title "$app_release_tag" --verify-tag "${reply[@]}")
        if [[ $app_release_is_prerelease == true ]]; then
            command+=(--prerelease)
        fi
        command+=("${product_paths[@]}")
        _app_release_run "${command[@]}"
    fi
}

# Sets reply to the gh options that carry the release notes:
# - the file release_notes_path names, written first by the release_compose_notes hook when missing;
# - otherwise, with release_notes_fallback=generated, the notes GitHub generates from the history;
# - otherwise empty notes when no file was asked for, and a failure when the asked-for file is missing.
_app_release_release_notes_arguments() {
    local notes_path=
    if [[ -n $release_notes_path ]]; then
        _app_release_render_template "$release_notes_path"
        notes_path=${REPLY:a}
        if [[ ! -f $notes_path ]] && (( $+functions[release_compose_notes] )); then
            _app_release_call_hook release_compose_notes "$notes_path"
        fi
        if [[ -f $notes_path ]]; then
            reply=(--notes-file "$notes_path")
            return 0
        fi
    fi
    if [[ $release_notes_fallback == generated ]]; then
        reply=(--generate-notes)
        return 0
    fi
    if [[ -z $notes_path ]]; then
        reply=(--notes "")
        return 0
    fi
    if [[ $_app_release_is_dry_run == true ]]; then
        app_release_detail "dry run: the release notes $notes_path do not exist yet"
        reply=(--notes-file "$notes_path")
        return 0
    fi
    app_release_fail "release_notes_path: no release notes at $notes_path"
}
