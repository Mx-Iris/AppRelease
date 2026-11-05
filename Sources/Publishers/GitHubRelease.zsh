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

    _app_release_release_notes_arguments
    local -a notes_arguments=("${reply[@]}")

    if gh release view "$app_release_tag" --repo "$app_release_github_repository" > /dev/null 2>&1; then
        app_release_detail "the release $app_release_tag exists; replacing its assets"
        _app_release_run gh release upload "$app_release_tag" --repo "$app_release_github_repository" --clobber "${product_paths[@]}"
    else
        local -a command=(gh release create "$app_release_tag" --repo "$app_release_github_repository" --verify-tag "${notes_arguments[@]}")
        if [[ $app_release_is_prerelease == true ]]; then
            command+=(--prerelease)
        fi
        command+=("${product_paths[@]}")
        _app_release_run "${command[@]}"
    fi
}

# Sets reply to the gh options that carry the release notes: the file release_notes_path names, written
# first by the release_compose_notes hook when it does not exist yet; or empty notes.
_app_release_release_notes_arguments() {
    reply=(--notes "")
    if [[ -z $release_notes_path ]]; then
        return 0
    fi
    _app_release_render_template "$release_notes_path"
    local notes_path=${REPLY:a}
    if [[ ! -f $notes_path ]] && (( $+functions[release_compose_notes] )); then
        _app_release_call_hook release_compose_notes "$notes_path"
    fi
    if [[ ! -f $notes_path ]]; then
        if [[ $_app_release_is_dry_run == true ]]; then
            app_release_detail "dry run: the release notes $notes_path do not exist yet"
        else
            app_release_fail "release_notes_path: no release notes at $notes_path"
        fi
    fi
    reply=(--notes-file "$notes_path")
}
