# Version and tag rules. Versions look like 1.9.0 or 1.9.0-beta.5; tags add a leading v.

# Succeeds when the tag names the project's version. exact: the same string. base: the tag may add a
# prerelease suffix to a project that keeps its version numeric (LyricsX: v1.9.0-beta.5 for 1.9.0).
_app_release_tag_matches_version() {
    local tag_version=${1#v} project_version=$2 match_mode=$3
    [[ $tag_version == $project_version ]] && return 0
    [[ $match_mode == base && $tag_version == *-* && ${tag_version%%-*} == $project_version ]]
}

# Sets REPLY to the build number LyricsX's scheme gives a version, so that build numbers keep the
# semantic order across channels: MAJOR * 10_000_000 + MINOR * 100_000 + PATCH * 1_000 + label, where
# label is alpha.N → N, beta.N → 100 + N, rc.N → 200 + N, and no suffix → 999.
_app_release_encode_semantic_version() {
    local version=$1
    if [[ ! $version =~ '^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([1-9][0-9]?))?$' ]]; then
        app_release_fail "semantic-version-encoding needs MAJOR.MINOR.PATCH, optionally followed by -alpha.N, -beta.N or -rc.N with N from 1 to 99; got $version"
    fi
    local -i major=$match[1] minor=$match[2] patch=$match[3] label=999
    case ${match[5]-} in
        (alpha) label=$match[6] ;;
        (beta) label=$(( 100 + match[6] )) ;;
        (rc) label=$(( 200 + match[6] )) ;;
    esac
    (( minor <= 99 && patch <= 99 )) || app_release_fail "semantic-version-encoding allows a minor and a patch number up to 99; got $version"
    REPLY=$(( major * 10000000 + minor * 100000 + patch * 1000 + label ))
}
