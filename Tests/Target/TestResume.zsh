# Continuing a run: a single stage picks up the scheme's latest run, and only when that is safe.

test_continuing_without_an_earlier_run_is_refused() {
    make_project
    use_fake_build_settings
    run_app_release archive
    expect_failure_containing "there is no earlier run of SampleApp to continue"
}

test_a_single_stage_needs_the_stage_before_it() {
    make_project
    use_fake_build_settings
    run_app_release target --to archive
    expect_success
    run_app_release export
    expect_failure_containing "archive has not completed in the latest run"
}

test_a_run_cannot_continue_on_another_commit() {
    make_project
    use_fake_build_settings
    run_app_release target --to archive
    expect_success
    configure_release "# a commit after the run started"
    run_app_release archive
    expect_failure_containing "but HEAD is now"
}

test_a_new_run_of_the_same_version_keeps_the_earlier_one() {
    make_project
    use_fake_build_settings
    run_app_release target --to archive
    expect_success
    run_app_release target --to archive
    expect_success
    expect_output_containing "kept the earlier run of this version"
    local -a kept_runs=("$test_project"/build/AppRelease/SampleApp/1.2.3-45.replaced-*(N/))
    expect_equal 1 ${#kept_runs} "earlier runs kept aside"
}
