# --publish: the outward-facing part, in a fixed order so that an app reading the new appcast always
# finds the download already there: tag, GitHub Release, appcast, and finally the project's deploy hook.
# What can still fail without reaching outside, such as missing release notes, is settled before the tag.

_app_release_publish() {
    local application_archive_name=$1
    app_release_log "publish: $app_release_tag"
    if (( ${release_publishers[(Ie)github-release]} )); then
        _app_release_prepare_github_release
    fi
    _app_release_publish_tag
    if (( ${release_publishers[(Ie)github-release]} )); then
        _app_release_publish_github_release
    fi
    if (( ${release_publishers[(Ie)sparkle-appcast]} )); then
        _app_release_publish_sparkle_appcast "$application_archive_name"
    fi
}

_app_release_resolve_github_repository() {
    if [[ -n $app_release_github_repository ]]; then
        return 0
    fi
    app_release_github_repository=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2> /dev/null) ||
        app_release_fail "gh cannot tell which GitHub repository origin is"
}

# Creates the tag on the released commit when it does not exist yet, and makes sure origin has it.
_app_release_publish_tag() {
    local tagged_commit
    if tagged_commit=$(_app_release_git rev-parse -q --verify "refs/tags/$app_release_tag^{commit}"); then
        [[ $tagged_commit == $app_release_git_commit ]] ||
            app_release_fail "the tag $app_release_tag points at ${tagged_commit[1,12]}, not at the released commit ${app_release_git_commit[1,12]}"
    else
        _app_release_run git -C "$app_release_project_directory" tag -a "$app_release_tag" -m "Release $app_release_tag" "$app_release_git_commit"
    fi
    _app_release_remote_tag_commit "$app_release_tag"
    if [[ -z $REPLY ]]; then
        _app_release_run git -C "$app_release_project_directory" push origin "refs/tags/$app_release_tag"
    elif [[ $REPLY != $app_release_git_commit ]]; then
        app_release_fail "the tag $app_release_tag on origin points at ${REPLY[1,12]}, not at the released commit ${app_release_git_commit[1,12]}"
    else
        app_release_detail "origin already has the tag $app_release_tag"
    fi
}
