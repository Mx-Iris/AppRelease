#!/bin/zsh -f
# Runs the AppRelease tests.
#
#   Tests/Run.zsh                  syntax check, then every test outside Tests/Integration
#   Tests/Run.zsh --integration    also Tests/Integration, which archives the sample app with the real
#                                  xcodebuild; set APP_RELEASE_TEST_DERIVED_DATA_PATH for its DerivedData
#   Tests/Run.zsh <test files>     only these files
#
# Each test_* function runs in a subshell of its own with err_exit on, and its output is shown only
# when it fails. The exit status is the number of failures, capped at 1.
emulate -R zsh
setopt no_unset pipe_fail extended_glob

typeset -gr test_directory=${0:A:h}
typeset -gr engine_root=${test_directory:h}
typeset -gi passed_count=0 failed_count=0
typeset -g runs_integration=false
typeset -ga test_files=()

for argument in "$@"; do
    case $argument in
        (--integration) runs_integration=true ;;
        (*) test_files+=("${argument:A}") ;;
    esac
done

check_syntax() {
    local file
    local -a files=(
        "$engine_root/app-release" "$engine_root/Install app-release.command"
        "$engine_root"/Sources/**/*.zsh(N) "$test_directory"/**/*.zsh(N) "$test_directory"/Support/Fakes/*(N)
    )
    for file in "${files[@]}"; do
        if ! zsh -n "$file"; then
            print -r -- "  FAIL  syntax of ${file#$engine_root/}"
            failed_count+=1
        fi
    done
    print -r -- "  ok    syntax of ${#files} files"
}

run_test_file() {
    local test_file=$1 test_name output
    local -a function_names test_names
    function_names=(${(f)"$(zsh -f -c 'source "$1"; source "$2"; print -l ${(k)functions}' run \
        "$test_directory/Support/TestingSupport.zsh" "$test_file")"})
    test_names=(${(o)${(M)function_names:#test_*}})
    for test_name in "${test_names[@]}"; do
        local -i exit_code=0
        output=$( (
            source "$test_directory/Support/TestingSupport.zsh"
            source "$test_file"
            trap 'clean_up_test_project' EXIT
            setopt err_exit
            "$test_name"
        ) 2>&1 ) || exit_code=$?
        if (( exit_code == 0 )); then
            print -r -- "  ok    ${test_file:t:r} › $test_name"
            passed_count+=1
        else
            print -r -- "  FAIL  ${test_file:t:r} › $test_name"
            print -r -- "${(F)${${(@f)output}/#/        }}"
            failed_count+=1
        fi
    done
}

check_syntax
if (( ${#test_files} == 0 )); then
    test_files=("$test_directory"/(Target|Launcher)/Test*.zsh(N))
    if [[ $runs_integration == true ]]; then
        test_files+=("$test_directory"/Integration/Test*.zsh(N))
    fi
fi
for test_file in "${test_files[@]}"; do
    run_test_file "$test_file"
done

print -r -- "$passed_count passed, $failed_count failed"
(( failed_count == 0 ))
