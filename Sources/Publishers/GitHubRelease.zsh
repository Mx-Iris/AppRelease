# github-release: creates the release for the tag, or replaces the assets of one that already exists.

typeset -g _app_release_github_release_exists=false
typeset -ga _app_release_github_release_notes_arguments=()

# target's check: a release that will be created must have its notes unless something else provides
# them, so that missing notes stop the release before anything is archived.
_app_release_preflight_release_notes() {
    [[ -n $release_notes_path && $release_notes_fallback == none ]] || return 0
    if (( $+functions[release_compose_notes] )); then
        return 0
    fi
    if gh release view "$app_release_tag" --repo "$app_release_github_repository" > /dev/null 2>&1; then
        return 0
    fi
    _app_release_resolve_release_notes_path
    [[ -s $REPLY ]] || _app_release_fail_without_release_notes "$REPLY"
}

# Settles what the release needs before the tag is pushed: whether it exists, and its notes. A release
# that cannot be created stops here, while nothing has left the Mac yet.
_app_release_prepare_github_release() {
    _app_release_resolve_github_repository
    _app_release_github_release_notes_arguments=()
    if gh release view "$app_release_tag" --repo "$app_release_github_repository" > /dev/null 2>&1; then
        _app_release_github_release_exists=true
        return 0
    fi
    _app_release_github_release_exists=false
    _app_release_release_notes_arguments
    _app_release_github_release_notes_arguments=("${reply[@]}")
}

_app_release_publish_github_release() {
    local -a product_paths
    if [[ $_app_release_is_dry_run == true ]]; then
        _app_release_render_template "$release_product_name"
        product_paths=("$app_release_run_directory/Products/$REPLY")
    else
        product_paths=(${(f)"$(_app_release_product_paths)"})
    fi

    if [[ $_app_release_github_release_exists == true ]]; then
        app_release_detail "the release $app_release_tag exists; replacing its assets"
        _app_release_run gh release upload "$app_release_tag" --repo "$app_release_github_repository" --clobber "${product_paths[@]}"
    else
        local -a command=(gh release create "$app_release_tag" --repo "$app_release_github_repository"
            --title "$app_release_tag" --verify-tag "${_app_release_github_release_notes_arguments[@]}")
        if [[ $app_release_is_prerelease == true ]]; then
            command+=(--prerelease)
        fi
        command+=("${product_paths[@]}")
        _app_release_run "${command[@]}"
    fi
}

# Sets reply to the gh options that carry the release notes:
# - the file release_notes_path names, written first by the release_compose_notes hook when it is
#   missing or empty;
# - otherwise, with release_notes_fallback=generated, the notes GitHub generates from the history;
# - otherwise empty notes when no file was asked for, and a failure when the asked-for file is missing
#   or empty.
_app_release_release_notes_arguments() {
    local notes_path=
    if [[ -n $release_notes_path ]]; then
        _app_release_resolve_release_notes_path
        notes_path=$REPLY
        if [[ ! -s $notes_path ]] && (( $+functions[release_compose_notes] )); then
            _app_release_call_hook release_compose_notes "$notes_path"
        fi
        if [[ -s $notes_path ]]; then
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
    _app_release_fail_without_release_notes "$notes_path"
}

# Sets REPLY to the absolute path that release_notes_path names for this release.
_app_release_resolve_release_notes_path() {
    _app_release_render_template "$release_notes_path"
    REPLY=${REPLY:a}
}

_app_release_fail_without_release_notes() {
    app_release_fail "release_notes_path: no release notes at $1 (missing or empty); write them, or set release_notes_fallback=generated"
}
