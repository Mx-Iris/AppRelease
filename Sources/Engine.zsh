#!/bin/zsh -f
# AppRelease engine: target → archive → export → notary → product.
#
# Started by the app-release launcher, which chooses the engine version the project pins and sets
# APP_RELEASE_PROJECT_DIRECTORY. Each stage reads what the previous one left in the run directory,
# checks its own output, and records the result in the run's manifest.json.
emulate -R zsh
setopt err_exit no_unset pipe_fail extended_glob
zmodload zsh/parameter

typeset -gr _app_release_engine_root=${0:A:h:h}
typeset -gr app_release_engine_version=$(<$_app_release_engine_root/Sources/Version)

for _app_release_module in \
    Support/Logging Support/Configuration Support/Plan Support/Git Support/BuildSettings \
    Support/Versioning Support/Manifest Support/Xcodebuild Support/Credentials \
    Support/Verification Support/Hooks \
    Stages/Target Stages/Archive Stages/Export Stages/Notary Stages/Product \
    Publishers/Publish Publishers/GitHubRelease Publishers/SparkleAppcast
do
    source "$_app_release_engine_root/Sources/$_app_release_module.zsh"
done
unset _app_release_module

typeset -g _app_release_command=
typeset -g _app_release_from_stage= _app_release_to_stage=
typeset -g _app_release_version_tag_option= _app_release_derived_data_option=
typeset -g _app_release_is_dry_run=false _app_release_allows_dirty=false
typeset -g _app_release_publishes=false _app_release_skips_notarization=false
typeset -ga app_release_project_arguments=()

_app_release_print_usage() {
    print -r -- "AppRelease $app_release_engine_version

Usage: app-release <stage> [options] [-- arguments for the hooks]

Stages, in order:
  target    Resolve the plan and check everything that can be checked before building
  archive   xcodebuild archive, then check it is an app archive with the expected architectures
  export    xcodebuild -exportArchive with Developer ID, then check the signature
  notary    Notarize, staple, and check that Gatekeeper takes the app for notarized
  product   Zip the app, archive the dSYMs, write SHA256SUMS; with --publish, release it
  all       Run the stages in order, target through product unless --from or --to says otherwise

A single stage continues the latest run of the scheme, so it needs the stages before it.

Options:
  --from <stage>              With all: start at this stage, continuing the latest run
  --to <stage>                With all or target: stop after (or check up to) this stage
  --version-tag <tag>         Release tag, for example v1.4.0; checked against the app's version
  --skip-notarization         Same as --to export: build and check, but make nothing to release
  --publish                   Push the tag, create the GitHub Release, update the appcast
  --derived-data-path <path>  DerivedData for xcodebuild (default <output root>/DerivedData/<scheme>)
  --allow-dirty               Allow uncommitted changes; never together with --publish
  --dry-run                   Resolve the plan, then print the commands instead of running them
  -h, --help                  Show this help
  version                     Print the engine version

Release.zsh, the hooks and the environment variables are described in the README."
}

# Reads the value that follows an option, failing with a message instead of zsh's own.
_app_release_option_value() {
    local option=$1
    shift
    (( $# > 0 )) && [[ $1 != -* ]] || app_release_fail "$option needs a value (see app-release --help)"
    REPLY=$1
}

_app_release_parse_arguments() {
    while (( $# > 0 )); do
        case $1 in
            (--from)
                _app_release_option_value "$@"
                _app_release_from_stage=$REPLY
                shift 2
                ;;
            (--to)
                _app_release_option_value "$@"
                _app_release_to_stage=$REPLY
                shift 2
                ;;
            (--version-tag)
                _app_release_option_value "$@"
                _app_release_version_tag_option=$REPLY
                shift 2
                ;;
            (--derived-data-path)
                _app_release_option_value "$@"
                _app_release_derived_data_option=$REPLY
                shift 2
                ;;
            (--skip-notarization)
                _app_release_skips_notarization=true
                shift
                ;;
            (--publish)
                _app_release_publishes=true
                shift
                ;;
            (--allow-dirty)
                _app_release_allows_dirty=true
                shift
                ;;
            (--dry-run)
                _app_release_is_dry_run=true
                shift
                ;;
            (-h|--help|help)
                _app_release_command=help
                shift
                ;;
            (--)
                shift
                app_release_project_arguments=("$@")
                break
                ;;
            (-*)
                app_release_fail "unknown option $1 (see app-release --help)"
                ;;
            (*)
                [[ -z $_app_release_command ]] || app_release_fail "unexpected argument $1 (see app-release --help)"
                _app_release_command=$1
                shift
                ;;
        esac
    done
    if [[ -z $_app_release_command ]]; then
        _app_release_command=help
    fi
    case $_app_release_command in
        (help|version|all|target|archive|export|notary|product) ;;
        (*) app_release_fail "unknown stage '$_app_release_command' (stages: ${_app_release_stages[*]}, or all)" ;;
    esac
}

_app_release_print_outcome() {
    if [[ $_app_release_is_dry_run == true ]]; then
        app_release_log "dry run finished; nothing was built or changed"
        return 0
    fi
    local last_stage=${_app_release_stages[_app_release_last_index]}
    app_release_log "done: $last_stage"
    app_release_detail "run directory  $app_release_run_directory"
    if [[ $last_stage == product ]]; then
        app_release_detail "products       $app_release_run_directory/Products"
    fi
}

_app_release_main() {
    _app_release_parse_arguments "$@"
    case $_app_release_command in
        (help)
            _app_release_print_usage
            return 0
            ;;
        (version)
            print -r -- "$app_release_engine_version"
            return 0
            ;;
    esac

    app_release_project_directory=${${APP_RELEASE_PROJECT_DIRECTORY:-$PWD}:A}
    cd "$app_release_project_directory"
    _app_release_load_configuration
    _app_release_compute_plan
    _app_release_resolve_locations
    app_release_log "AppRelease $app_release_engine_version · $release_scheme · ${(j: → :)_app_release_stages[_app_release_first_index,_app_release_last_index]}"

    local stage
    local -i index
    for (( index = _app_release_first_index; index <= _app_release_last_index; index++ )); do
        stage=${_app_release_stages[index]}
        if (( index == _app_release_first_index )) && [[ $stage != target ]]; then
            _app_release_resume_run "$stage"
        fi
        _app_release_prepare_credentials_for "$stage"
        if [[ $stage != target ]]; then
            _app_release_begin_stage "$stage"
        fi
        "_app_release_stage_$stage"
        _app_release_record_stage_completion "$stage"
    done
    _app_release_print_outcome
}

# Traps live at the top level: in zsh an EXIT trap set inside a function fires when that function returns.
# A trap given as a string leaves $? alone, so err_exit still exits with the failed command's status.
trap '_app_release_report_unexpected_failure $?' ZERR
trap '_app_release_clean_up_credentials' EXIT
trap '_app_release_clean_up_credentials; exit 130' INT
trap '_app_release_clean_up_credentials; exit 143' TERM

_app_release_main "$@"
