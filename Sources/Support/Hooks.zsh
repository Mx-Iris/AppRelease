# Hooks: functions a project may define in Release.zsh. The engine calls one only when it is defined.
#
# A hook runs in a subshell with err_exit on, so any failing command in it fails the hook, and the
# engine then stops the release. Being a subshell, a hook cannot change the engine's variables; it
# hands results back through app_release_add_product or through files.

_app_release_call_hook() {
    local hook_name=$1
    shift
    if (( ! $+functions[$hook_name] )); then
        return 0
    fi
    if [[ $_app_release_is_dry_run == true ]]; then
        app_release_detail "dry run: would call the hook $hook_name"
        return 0
    fi
    app_release_detail "hook $hook_name"
    # The subshell's failure is the hook's verdict, so it must not end the engine on the spot.
    setopt local_options no_err_exit
    ( setopt err_exit; "$hook_name" "$@" )
    local -i hook_status=$?
    if (( hook_status != 0 )); then
        app_release_fail "the hook $hook_name failed with status $hook_status"
    fi
}

# app_release_add_product <path> [--not-notarized]
# Adds a file to the release: it is copied into Products/, listed in SHA256SUMS and uploaded with the
# GitHub Release. A notarized product must be a zip holding one notarized, stapled app, and is checked
# like the main one; --not-notarized skips that check (an iOS Simulator payload, a dSYM archive).
app_release_add_product() {
    local source_path=${1:-} kind=notarized
    if [[ ${2:-} == --not-notarized ]]; then
        kind=not-notarized
    fi
    [[ -f $source_path ]] || app_release_fail "app_release_add_product: no file at '$source_path'"
    local products_directory=$app_release_run_directory/Products
    local file_name=${source_path:t}
    if [[ ${source_path:A} != ${products_directory:A}/$file_name ]]; then
        cp "$source_path" "$products_directory/$file_name"
    fi
    print -r -- "$kind"$'\t'"$file_name" >> "$app_release_run_directory/products.tsv"
}
