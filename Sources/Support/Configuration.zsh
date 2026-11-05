# Release.zsh: the project's side of the contract. Every variable it may set is declared here with
# its default; the README lists them with their meaning.

typeset -g release_engine_version=
typeset -g release_workspace= release_project= release_scheme= release_application_target=
typeset -g release_configuration=Release
typeset -g release_destination='generic/platform=macOS'
typeset -ga release_architectures=()
typeset -ga release_archive_arguments=()
typeset -g release_xcode_path=
typeset -g release_team_identifier=
typeset -g release_export_options_path=
typeset -g release_notary_keychain_profile=
typeset -g release_build_number_source=project
typeset -g release_version_tag_match=exact
typeset -g release_product_name='{name}-{version}-{build}.zip'
typeset -ga release_publishers=()
typeset -g release_notes_path=
typeset -g release_notes_fallback=none
typeset -g release_appcast_path=
typeset -ga release_appcast_arguments=()

# Where this run's files go; set by _app_release_resolve_locations.
typeset -g _app_release_output_root= _app_release_scheme_directory=
typeset -g app_release_project_directory= app_release_derived_data_path= app_release_run_directory=

# The run's context: set by the target stage, or read back from manifest.json when a later stage
# continues a run. Hooks may read all of these.
typeset -g app_release_application_target= app_release_application_name=
typeset -g app_release_marketing_version= app_release_build_number= app_release_tag=
typeset -g app_release_is_prerelease=false app_release_injects_build_number=false
typeset -ga app_release_architectures=()
typeset -g app_release_team_identifier= app_release_git_commit= app_release_git_is_dirty=false
typeset -g app_release_xcode_version= app_release_xcode_build= app_release_developer_directory=
typeset -g app_release_archive_path= app_release_application_path=
typeset -g app_release_github_repository=

_app_release_load_configuration() {
    local release_file=$app_release_project_directory/Release.zsh
    [[ -f $release_file ]] || app_release_fail "no Release.zsh in $app_release_project_directory"
    # Sourced here, inside the engine: plain assignments set the globals above, and the hook
    # functions it defines become visible to _app_release_call_hook.
    source "$release_file"

    if [[ $release_engine_version != $app_release_engine_version && -z ${APP_RELEASE_ENGINE_DIRECTORY:-} ]]; then
        app_release_fail "Release.zsh pins AppRelease $release_engine_version, but this engine is $app_release_engine_version; start it through the app-release launcher"
    fi
    [[ -n $release_scheme ]] || app_release_fail "Release.zsh must set release_scheme"
    if [[ -n $release_workspace && -n $release_project ]]; then
        app_release_fail "Release.zsh sets both release_workspace and release_project; keep one"
    fi
    [[ -n $release_workspace || -n $release_project ]] || app_release_fail "Release.zsh must set release_workspace or release_project"
    case $release_build_number_source in
        (project|commit-count|semantic-version-encoding) ;;
        (*) app_release_fail "release_build_number_source must be project, commit-count or semantic-version-encoding, not '$release_build_number_source'" ;;
    esac
    case $release_version_tag_match in
        (exact|base) ;;
        (*) app_release_fail "release_version_tag_match must be exact or base, not '$release_version_tag_match'" ;;
    esac
    case $release_notes_fallback in
        (none|generated) ;;
        (*) app_release_fail "release_notes_fallback must be none or generated, not '$release_notes_fallback'" ;;
    esac
    [[ $release_product_name == *.zip ]] || app_release_fail "release_product_name must end in .zip: this version of AppRelease makes zip archives only"
    [[ $release_product_name != */* ]] || app_release_fail "release_product_name is a file name, not a path: '$release_product_name'"

    local publisher
    for publisher in "${release_publishers[@]}"; do
        case $publisher in
            (github-release|sparkle-appcast) ;;
            (*) app_release_fail "unknown publisher '$publisher' in release_publishers (known: github-release, sparkle-appcast)" ;;
        esac
    done
    if (( ${release_publishers[(Ie)sparkle-appcast]} )); then
        (( ${release_publishers[(Ie)github-release]} )) || app_release_fail "sparkle-appcast needs github-release in release_publishers: the appcast points at the GitHub Release's downloads"
        [[ -n $release_appcast_path ]] || app_release_fail "sparkle-appcast needs release_appcast_path"
    fi
}

_app_release_resolve_locations() {
    _app_release_output_root=${${APP_RELEASE_OUTPUT_ROOT:-$app_release_project_directory/build/AppRelease}:a}
    _app_release_scheme_directory=$_app_release_output_root/$release_scheme
    local derived_data_path=${_app_release_derived_data_option:-${APP_RELEASE_DERIVED_DATA_PATH:-$_app_release_output_root/DerivedData/$release_scheme}}
    app_release_derived_data_path=${derived_data_path:a}
}

# Renders a file name template. Placeholders: {name} {version} {build} {tag}.
_app_release_render_template() {
    local rendered=$1
    rendered=${rendered//\{name\}/$app_release_application_name}
    rendered=${rendered//\{version\}/$app_release_marketing_version}
    rendered=${rendered//\{build\}/$app_release_build_number}
    rendered=${rendered//\{tag\}/$app_release_tag}
    if [[ $rendered == *\{*\}* ]]; then
        app_release_fail "unknown placeholder in '$1' (known: {name} {version} {build} {tag})"
    fi
    REPLY=$rendered
}
