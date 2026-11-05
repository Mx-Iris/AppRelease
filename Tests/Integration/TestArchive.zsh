# Archives the sample app with the real xcodebuild (ad hoc signed, no certificates needed).
# Runs only with Tests/Run.zsh --integration and APP_RELEASE_TEST_DERIVED_DATA_PATH set.

require_derived_data_path() {
    [[ -n ${APP_RELEASE_TEST_DERIVED_DATA_PATH:-} ]] ||
        fail_test "set APP_RELEASE_TEST_DERIVED_DATA_PATH to the DerivedData directory these tests may use"
}

test_the_sample_app_archives_and_passes_the_archive_checks() {
    require_derived_data_path
    make_project
    run_app_release all --to archive --derived-data-path "$APP_RELEASE_TEST_DERIVED_DATA_PATH"
    expect_success
    expect_output_containing "architectures: "
    local manifest_path=$test_project/build/AppRelease/SampleApp/Latest/manifest.json
    expect_equal true "$(jq -r '.stages.archive.completedAt != null' "$manifest_path")" "archive completion recorded in the manifest"
}

test_a_generic_archive_is_refused() {
    require_derived_data_path
    make_project
    configure_release 'release_archive_arguments=(SKIP_INSTALL=NO)'
    run_app_release all --to archive --derived-data-path "$APP_RELEASE_TEST_DERIVED_DATA_PATH"
    expect_failure_containing "is a Generic Xcode Archive"
    expect_output_containing "usr/local/bin/SampleTool"
}

test_a_missing_architecture_is_refused() {
    require_derived_data_path
    make_project
    configure_release 'release_architectures=(arm64 x86_64)' 'release_archive_arguments=(ARCHS=arm64)'
    run_app_release all --to archive --derived-data-path "$APP_RELEASE_TEST_DERIVED_DATA_PATH"
    expect_failure_containing "not the expected (arm64 x86_64)"
}
