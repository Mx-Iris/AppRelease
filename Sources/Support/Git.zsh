# Git queries about the project being released.

_app_release_git() {
    git -C "$app_release_project_directory" "$@"
}

# Sets REPLY to the commit the tag names on origin, or to nothing when origin has no such tag.
_app_release_remote_tag_commit() {
    local tag=$1 output
    output=$(_app_release_git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}") || app_release_fail "cannot list the tags on origin"
    local line commit reference peeled_commit= plain_commit=
    for line in "${(@f)output}"; do
        [[ -n $line ]] || continue
        commit=${line%%$'\t'*}
        reference=${line#*$'\t'}
        if [[ $reference == "refs/tags/$tag^{}" ]]; then
            peeled_commit=$commit
        elif [[ $reference == "refs/tags/$tag" ]]; then
            plain_commit=$commit
        fi
    done
    # An annotated tag lists its own object first and the commit as <tag>^{}.
    REPLY=${peeled_commit:-$plain_commit}
}
