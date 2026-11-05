# Which stages run, and how far the target stage's checks reach.

typeset -gra _app_release_stages=(target archive export notary product)
typeset -gi _app_release_first_index=0 _app_release_last_index=0 _app_release_scope_last_index=0

# Sets REPLY to the stage's position, 1 for target through 5 for product.
_app_release_stage_index() {
    local -i index=${_app_release_stages[(Ie)$1]}
    (( index > 0 )) || app_release_fail "unknown stage '$1' (stages: ${_app_release_stages[*]})"
    REPLY=$index
}

# Succeeds when the plan reaches the stage: the target stage checks what the planned stages will need.
_app_release_scope_includes() {
    (( ${_app_release_stages[(Ie)$1]} <= _app_release_scope_last_index ))
}

_app_release_compute_plan() {
    local first_stage last_stage scope_last_stage
    if [[ $_app_release_command == all ]]; then
        first_stage=${_app_release_from_stage:-target}
        last_stage=${_app_release_to_stage:-product}
        scope_last_stage=$last_stage
    else
        [[ -z $_app_release_from_stage ]] || app_release_fail "--from works with all; to run a single stage, name it: app-release $_app_release_from_stage"
        first_stage=$_app_release_command
        last_stage=$_app_release_command
        if [[ $_app_release_command == target ]]; then
            scope_last_stage=${_app_release_to_stage:-product}
        else
            [[ -z $_app_release_to_stage ]] || app_release_fail "--to works with all or target"
            scope_last_stage=$_app_release_command
        fi
    fi

    if [[ $_app_release_skips_notarization == true ]]; then
        [[ $_app_release_command == (all|target) ]] || app_release_fail "--skip-notarization works with all or target"
        if [[ -n $_app_release_to_stage && $_app_release_to_stage != export ]]; then
            app_release_fail "--skip-notarization stops after export, so it cannot be combined with --to $_app_release_to_stage"
        fi
        if [[ $_app_release_command == all ]]; then
            last_stage=export
        fi
        scope_last_stage=export
    fi

    _app_release_stage_index "$first_stage"
    _app_release_first_index=$REPLY
    _app_release_stage_index "$last_stage"
    _app_release_last_index=$REPLY
    _app_release_stage_index "$scope_last_stage"
    _app_release_scope_last_index=$REPLY
    (( _app_release_first_index <= _app_release_last_index )) || app_release_fail "--from $first_stage comes after the last stage, $last_stage"

    if [[ $_app_release_publishes == true ]]; then
        (( _app_release_scope_last_index == ${#_app_release_stages} )) || app_release_fail "--publish needs a plan that reaches product"
        [[ $_app_release_allows_dirty == false ]] || app_release_fail "--publish never releases uncommitted changes; drop --allow-dirty"
    fi
}
