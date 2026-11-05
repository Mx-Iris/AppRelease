# manifest.json in the run directory: what each stage produced, so later stages can continue the run.
# schemaVersion 1. A run may only be continued by the engine version that started it.

typeset -gri _app_release_manifest_schema_version=1

# Applies a jq filter to the manifest in place: _app_release_manifest_update '<filter>' [jq options].
_app_release_manifest_update() {
    local filter=$1
    shift
    if [[ $_app_release_is_dry_run == true ]]; then
        return 0
    fi
    local manifest_path=$app_release_run_directory/manifest.json
    jq "$@" "$filter" "$manifest_path" > "$manifest_path.updating"
    mv -f "$manifest_path.updating" "$manifest_path"
}

# Prints the raw value at a jq path, or nothing when it is missing.
_app_release_manifest_value() {
    jq -r "$1 // empty" "$app_release_run_directory/manifest.json"
}

_app_release_write_initial_manifest() {
    if [[ $_app_release_is_dry_run == true ]]; then
        return 0
    fi
    jq -n \
        --argjson schemaVersion $_app_release_manifest_schema_version \
        --arg engineVersion "$app_release_engine_version" \
        --arg createdAt "$(_app_release_timestamp)" \
        --arg projectDirectory "$app_release_project_directory" \
        --arg scheme "$release_scheme" \
        --arg configuration "$release_configuration" \
        --arg applicationTarget "$app_release_application_target" \
        --arg applicationName "$app_release_application_name" \
        --arg gitCommit "$app_release_git_commit" \
        --argjson gitDirty $app_release_git_is_dirty \
        --arg xcodeVersion "$app_release_xcode_version" \
        --arg xcodeBuild "$app_release_xcode_build" \
        --arg developerDirectory "$app_release_developer_directory" \
        --arg marketingVersion "$app_release_marketing_version" \
        --arg buildNumber "$app_release_build_number" \
        --arg buildNumberSource "$release_build_number_source" \
        --argjson injectsBuildNumber $app_release_injects_build_number \
        --arg tag "$app_release_tag" \
        --argjson prerelease $app_release_is_prerelease \
        --arg teamIdentifier "$app_release_team_identifier" \
        --arg architectures "${app_release_architectures[*]}" \
        '{
            schemaVersion: $schemaVersion,
            engineVersion: $engineVersion,
            createdAt: $createdAt,
            project: {
                directory: $projectDirectory, scheme: $scheme, configuration: $configuration,
                applicationTarget: $applicationTarget, applicationName: $applicationName,
                gitCommit: $gitCommit, gitDirty: $gitDirty
            },
            xcode: {version: $xcodeVersion, build: $xcodeBuild, developerDirectory: $developerDirectory},
            version: {
                marketing: $marketingVersion, build: $buildNumber, buildNumberSource: $buildNumberSource,
                injectsBuildNumber: $injectsBuildNumber, tag: $tag, prerelease: $prerelease
            },
            signing: {teamIdentifier: $teamIdentifier, architectures: ($architectures | split(" "))},
            stages: {}
        }' > "$app_release_run_directory/manifest.json"
}

_app_release_record_stage_completion() {
    _app_release_manifest_update '.stages[$stage].completedAt = $date' --arg stage "$1" --arg date "$(_app_release_timestamp)"
}

# A stage that runs again invalidates what came after it, and is itself unfinished until it completes.
# The notary entry keeps its submission id, which is what lets an interrupted wait continue.
_app_release_begin_stage() {
    local stage=$1
    local -i index=${_app_release_stages[(Ie)$stage]}
    _app_release_manifest_update \
        'del(.stages[$stage].completedAt) | reduce ($later | split(" ") | map(select(length > 0)))[] as $name (.; del(.stages[$name]))' \
        --arg stage "$stage" --arg later "${_app_release_stages[index + 1, -1]}"
}

# Continues the scheme's latest run at the given stage: checks that the run can be continued here,
# then loads its context.
_app_release_resume_run() {
    local stage=$1
    local latest_link=$_app_release_scheme_directory/Latest
    [[ -L $latest_link && -d $latest_link ]] ||
        app_release_fail "there is no earlier run of $release_scheme to continue; start with app-release target or app-release all"
    app_release_run_directory=${latest_link:A}
    local manifest_path=$app_release_run_directory/manifest.json
    [[ -f $manifest_path ]] || app_release_fail "$app_release_run_directory has no manifest.json; start over with app-release all"

    local schema_version recorded_engine_version recorded_commit current_commit previous_stage completed_at
    schema_version=$(jq -r '.schemaVersion' "$manifest_path")
    (( schema_version == _app_release_manifest_schema_version )) ||
        app_release_fail "the latest run's manifest has schema $schema_version, which this engine cannot read; start over with app-release all"
    recorded_engine_version=$(jq -r '.engineVersion' "$manifest_path")
    [[ $recorded_engine_version == $app_release_engine_version ]] ||
        app_release_fail "the latest run was started by AppRelease $recorded_engine_version and this is $app_release_engine_version; start over with app-release all"
    recorded_commit=$(jq -r '.project.gitCommit' "$manifest_path")
    current_commit=$(_app_release_git rev-parse HEAD)
    [[ $recorded_commit == $current_commit ]] ||
        app_release_fail "the latest run built ${recorded_commit[1,12]}, but HEAD is now ${current_commit[1,12]}; start over with app-release all"
    previous_stage=${_app_release_stages[${_app_release_stages[(Ie)$stage]} - 1]}
    completed_at=$(jq -r --arg stage "$previous_stage" '.stages[$stage].completedAt // empty' "$manifest_path")
    [[ -n $completed_at ]] ||
        app_release_fail "$previous_stage has not completed in the latest run (${app_release_run_directory:t}); run app-release $previous_stage first"

    _app_release_load_context_from_manifest
    app_release_log "continuing ${app_release_run_directory:t}"
}

_app_release_load_context_from_manifest() {
    local manifest_path=$app_release_run_directory/manifest.json
    local -A values=()
    local key value
    while IFS=$'\t' read -r key value; do
        values[$key]=$value
    done < <(jq -r '[
            ["applicationTarget", .project.applicationTarget],
            ["applicationName", .project.applicationName],
            ["gitCommit", .project.gitCommit],
            ["gitDirty", (.project.gitDirty | tostring)],
            ["xcodeVersion", .xcode.version],
            ["xcodeBuild", .xcode.build],
            ["developerDirectory", .xcode.developerDirectory],
            ["marketingVersion", .version.marketing],
            ["buildNumber", .version.build],
            ["injectsBuildNumber", (.version.injectsBuildNumber | tostring)],
            ["tag", .version.tag],
            ["prerelease", (.version.prerelease | tostring)],
            ["teamIdentifier", .signing.teamIdentifier],
            ["architectures", (.signing.architectures | join(" "))],
            ["archivePath", (.stages.archive.archivePath // "")],
            ["applicationPath", (.stages.export.applicationPath // "")]
        ][] | @tsv' "$manifest_path")

    app_release_application_target=${values[applicationTarget]-}
    app_release_application_name=${values[applicationName]-}
    app_release_git_commit=${values[gitCommit]-}
    app_release_git_is_dirty=${values[gitDirty]-false}
    app_release_xcode_version=${values[xcodeVersion]-}
    app_release_xcode_build=${values[xcodeBuild]-}
    app_release_developer_directory=${values[developerDirectory]-}
    app_release_marketing_version=${values[marketingVersion]-}
    app_release_build_number=${values[buildNumber]-}
    app_release_injects_build_number=${values[injectsBuildNumber]-false}
    app_release_tag=${values[tag]-}
    app_release_is_prerelease=${values[prerelease]-false}
    app_release_team_identifier=${values[teamIdentifier]-}
    app_release_architectures=(${=values[architectures]-})
    app_release_archive_path=${values[archivePath]-}
    app_release_application_path=${values[applicationPath]-}
    # Later stages use the Xcode that the run started with.
    if [[ -n $app_release_developer_directory ]]; then
        export DEVELOPER_DIR=$app_release_developer_directory
    fi
}
