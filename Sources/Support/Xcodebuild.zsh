# The single way into xcodebuild, for the engine and for the hooks alike.

# app_release_xcodebuild <log name> <xcodebuild arguments...>
# The full output goes to <run directory>/logs/<log name>.log; on failure a summary follows on standard
# error. Success is xcodebuild's own exit status, never what a summary tool reports.
app_release_xcodebuild() {
    local log_name=$1
    shift
    local log_path=$app_release_run_directory/logs/$log_name.log
    local -a command=(xcodebuild "$@")
    # Serializes builds on a Mac that queued-build throttles; nesting is safe. Absent on CI runners.
    if (( $+commands[queued-build] )); then
        command=(queued-build "${command[@]}")
    fi
    if [[ $_app_release_is_dry_run == true ]]; then
        print -r -- "    + $(_app_release_quote_command "${command[@]}")"
        return 0
    fi
    mkdir -p "${log_path:h}"
    app_release_detail "xcodebuild $log_name (log: $log_path)"
    local -i exit_status=0
    # A Mac that falls asleep locks keychains and leaves codesign waiting on a prompt nobody answers.
    caffeinate -i "${command[@]}" > "$log_path" 2>&1 || exit_status=$?
    if (( exit_status != 0 )); then
        _app_release_show_build_failure "$log_path" $exit_status
    fi
    return $exit_status
}

_app_release_show_build_failure() {
    local log_path=$1 exit_status=$2
    print -u2 -r -- "xcodebuild exited with status $exit_status; full log: $log_path"
    if (( $+commands[xcsift] )); then
        xcsift < "$log_path" >&2 || true
    elif (( $+commands[xcbeautify] )); then
        xcbeautify --quiet < "$log_path" >&2 || true
    else
        grep -E '(^|: )(fatal )?error: ' "$log_path" | tail -n 30 >&2 || true
        tail -n 20 "$log_path" >&2 || true
    fi
}
