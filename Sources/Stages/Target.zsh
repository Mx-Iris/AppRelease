# target: resolve the plan, and check everything that can be checked before minutes go into archiving.
# Produces the run directory and its manifest.json.

typeset -g _app_release_target_log_path=

_app_release_stage_target() {
    app_release_log "target: resolving the plan"
    _app_release_check_required_tools
    _app_release_select_xcode
    _app_release_check_git_state
    mkdir -p "$_app_release_scheme_directory"
    _app_release_target_log_path=$_app_release_scheme_directory/.target-$$.log
    _app_release_load_build_settings "$_app_release_target_log_path"
    _app_release_resolve_application
    _app_release_resolve_versions
    _app_release_resolve_signing
    _app_release_check_local_tag
    if _app_release_scope_includes export; then
        _app_release_preflight_signing
    fi
    if _app_release_scope_includes notary; then
        _app_release_preflight_notary
    fi
    if [[ $_app_release_publishes == true ]]; then
        _app_release_preflight_publish
    fi
    _app_release_call_hook release_preflight
    _app_release_start_run_directory
    _app_release_write_initial_manifest
    _app_release_print_plan
}

_app_release_check_required_tools() {
    local tool
    for tool in xcodebuild xcrun git jq plutil ditto codesign security lipo shasum caffeinate; do
        (( $+commands[$tool] )) || app_release_fail "$tool is not on PATH"
    done
}

_app_release_select_xcode() {
    if [[ -n $release_xcode_path ]]; then
        local developer_directory=${release_xcode_path%/}
        if [[ $developer_directory == *.app ]]; then
            developer_directory+=/Contents/Developer
        fi
        [[ -d $developer_directory ]] || app_release_fail "release_xcode_path: no Xcode at $release_xcode_path"
        export DEVELOPER_DIR=$developer_directory
    fi
    local version_output
    version_output=$(xcodebuild -version 2>&1) || app_release_fail "xcodebuild -version failed: $version_output"
    local -a version_lines=("${(@f)version_output}")
    app_release_xcode_version=${${version_lines[1]-}#Xcode }
    app_release_xcode_build=${${version_lines[2]-}#Build version }
    app_release_developer_directory=${DEVELOPER_DIR:-$(xcode-select -p)}
}

_app_release_check_git_state() {
    local repository_root
    repository_root=$(_app_release_git rev-parse --show-toplevel 2> /dev/null) ||
        app_release_fail "$app_release_project_directory is not inside a git repository"
    app_release_git_commit=$(_app_release_git rev-parse HEAD)

    # An output root inside the repository has to be ignored, or the first run dirties the tree.
    if [[ $_app_release_output_root == ${repository_root:A}/* ]]; then
        mkdir -p "$_app_release_output_root"
        _app_release_git check-ignore -q "$_app_release_output_root/" ||
            app_release_fail "the output root $_app_release_output_root is inside the repository but not ignored; add its directory (usually build/) to .gitignore"
    fi

    local changes
    changes=$(_app_release_git status --porcelain)
    app_release_git_is_dirty=false
    if [[ -n $changes ]]; then
        app_release_git_is_dirty=true
        if [[ $_app_release_allows_dirty == true ]]; then
            app_release_warn "uncommitted changes: what gets built is not commit ${app_release_git_commit[1,12]}"
        else
            print -u2 -r -- "$changes"
            app_release_fail "uncommitted changes (listed above); commit them, or pass --allow-dirty for a build that is not a release"
        fi
    fi
}

_app_release_resolve_versions() {
    _app_release_effective_bundle_value CFBundleShortVersionString MARKETING_VERSION
    app_release_marketing_version=$REPLY
    [[ -n $app_release_marketing_version ]] ||
        app_release_fail "cannot find the app's version: neither MARKETING_VERSION nor the Info.plist's CFBundleShortVersionString is set"

    app_release_tag=${_app_release_version_tag_option:-v$app_release_marketing_version}
    local tag_version=${app_release_tag#v}
    _app_release_tag_matches_version "$app_release_tag" "$app_release_marketing_version" "$release_version_tag_match" ||
        app_release_fail "the tag $app_release_tag does not match the app's version $app_release_marketing_version (release_version_tag_match=$release_version_tag_match)"
    if [[ $tag_version == *-* ]]; then
        app_release_is_prerelease=true
    else
        app_release_is_prerelease=false
    fi

    case $release_build_number_source in
        (project)
            _app_release_effective_bundle_value CFBundleVersion CURRENT_PROJECT_VERSION
            app_release_build_number=$REPLY
            [[ -n $app_release_build_number ]] ||
                app_release_fail "cannot find the app's build number: neither CURRENT_PROJECT_VERSION nor the Info.plist's CFBundleVersion is set"
            app_release_injects_build_number=false
            ;;
        (commit-count)
            [[ $(_app_release_git rev-parse --is-shallow-repository) == false ]] ||
                app_release_fail "commit-count needs the whole history, but this clone is shallow (on GitHub Actions, give actions/checkout fetch-depth: 0)"
            app_release_build_number=$(_app_release_git rev-list --count HEAD)
            app_release_injects_build_number=true
            ;;
        (semantic-version-encoding)
            _app_release_encode_semantic_version "$tag_version"
            app_release_build_number=$REPLY
            app_release_injects_build_number=true
            ;;
    esac

    # An injected CURRENT_PROJECT_VERSION only reaches the app when its Info.plist asks for it.
    if [[ $app_release_injects_build_number == true ]]; then
        _app_release_effective_bundle_value CFBundleVersion CURRENT_PROJECT_VERSION
        if [[ $_app_release_bundle_value_origin != (fallback|setting:CURRENT_PROJECT_VERSION) ]]; then
            app_release_fail "release_build_number_source=$release_build_number_source passes CURRENT_PROJECT_VERSION to the archive, but the Info.plist sets CFBundleVersion to '$REPLY'; change it to \$(CURRENT_PROJECT_VERSION)"
        fi
    fi

    app_release_run_directory=$_app_release_scheme_directory/$tag_version-$app_release_build_number
}

_app_release_resolve_signing() {
    if (( ${#release_architectures} )); then
        app_release_architectures=("${release_architectures[@]}")
    else
        app_release_architectures=(${=app_release_build_settings[ARCHS]-})
    fi
    (( ${#app_release_architectures} )) || app_release_fail "cannot tell which architectures to expect; set release_architectures"
    app_release_team_identifier=${release_team_identifier:-${app_release_build_settings[DEVELOPMENT_TEAM]-}}
}

_app_release_check_local_tag() {
    local tagged_commit
    if tagged_commit=$(_app_release_git rev-parse -q --verify "refs/tags/$app_release_tag^{commit}"); then
        [[ $tagged_commit == $app_release_git_commit ]] ||
            app_release_fail "the tag $app_release_tag already exists on ${tagged_commit[1,12]}, not on HEAD (${app_release_git_commit[1,12]})"
    fi
}

_app_release_preflight_signing() {
    if ! _app_release_uses_ci_credentials && [[ -n ${SSH_CONNECTION:-}${SSH_TTY:-} ]]; then
        app_release_fail "this is an ssh session, which cannot use the login keychain, so codesign would fail (errSecInternalComponent); release from a local Terminal, or provide CI credentials (APP_RELEASE_CERTIFICATE_BASE64)"
    fi
    [[ -n $app_release_team_identifier ]] ||
        app_release_fail "no team: set release_team_identifier, or DEVELOPMENT_TEAM on $app_release_application_target"
    [[ ${app_release_build_settings[ENABLE_HARDENED_RUNTIME]-} == YES ]] ||
        app_release_fail "the hardened runtime is off for $app_release_application_target (ENABLE_HARDENED_RUNTIME); the notary service would reject the app"
    if [[ $_app_release_is_dry_run == true ]] && _app_release_uses_ci_credentials; then
        app_release_detail "dry run: the CI signing identity is not checked"
        return 0
    fi
    local identities line has_identity=false
    identities=$(security find-identity -v -p codesigning 2>&1) || app_release_fail "security find-identity failed: $identities"
    for line in "${(@f)identities}"; do
        if [[ $line == *'"Developer ID Application: '*"($app_release_team_identifier)\""* ]]; then
            has_identity=true
        fi
    done
    [[ $has_identity == true ]] ||
        app_release_fail "no \"Developer ID Application\" identity of team $app_release_team_identifier in the keychain"
}

_app_release_preflight_notary() {
    _app_release_resolve_notary_credentials
    xcrun notarytool history "${app_release_notary_credentials[@]}" --output-format json > /dev/null 2>&1 ||
        app_release_fail "the notary service refused these credentials or could not be reached; try: xcrun notarytool history $(_app_release_quote_command "${app_release_notary_credentials[@]}")"
}

_app_release_preflight_publish() {
    (( $+commands[gh] )) || app_release_fail "--publish needs the GitHub CLI, gh"
    gh auth status > /dev/null 2>&1 || app_release_fail "gh is not signed in (locally gh auth login; on CI set GH_TOKEN)"
    _app_release_git remote get-url origin > /dev/null 2>&1 || app_release_fail "--publish needs a remote named origin"
    _app_release_resolve_github_repository
    _app_release_remote_tag_commit "$app_release_tag"
    if [[ -n $REPLY && $REPLY != $app_release_git_commit ]]; then
        app_release_fail "the tag $app_release_tag on origin points at ${REPLY[1,12]}, not at HEAD (${app_release_git_commit[1,12]})"
    fi
    if [[ -n $release_appcast_path ]]; then
        [[ -d ${release_appcast_path:a:h} ]] || app_release_fail "release_appcast_path: the directory ${release_appcast_path:a:h} does not exist"
    fi
    if (( ${release_publishers[(Ie)github-release]} )); then
        _app_release_preflight_release_notes
    fi
}

# Starts the run directory. A run of the same version and build that is already there is kept aside,
# never deleted: it may be a release that went out.
_app_release_start_run_directory() {
    if [[ $_app_release_is_dry_run == true ]]; then
        rm -f "$_app_release_target_log_path"
        return 0
    fi
    if [[ -e $app_release_run_directory ]]; then
        local kept_path=$app_release_run_directory.replaced-$(date -u +%Y%m%dT%H%M%SZ)
        mv "$app_release_run_directory" "$kept_path"
        app_release_detail "kept the earlier run of this version as ${kept_path:t}"
    fi
    mkdir -p "$app_release_run_directory/logs"
    mv "$_app_release_target_log_path" "$app_release_run_directory/logs/build-settings.log"
    ln -sfn "${app_release_run_directory:t}" "$_app_release_scheme_directory/Latest"
}

_app_release_print_plan() {
    local prerelease_note=
    if [[ $app_release_is_prerelease == true ]]; then
        prerelease_note=" (prerelease)"
    fi
    app_release_detail "app            $app_release_application_name.app (target $app_release_application_target)"
    app_release_detail "version        $app_release_marketing_version, build $app_release_build_number, tag $app_release_tag$prerelease_note"
    app_release_detail "xcode          $app_release_xcode_version ($app_release_xcode_build) at $app_release_developer_directory"
    app_release_detail "architectures  ${app_release_architectures[*]}"
    app_release_detail "team           ${app_release_team_identifier:-none}"
    app_release_detail "checked up to  ${_app_release_stages[_app_release_scope_last_index]}"
    app_release_detail "run directory  $app_release_run_directory"
}
