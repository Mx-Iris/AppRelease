# Which stages a command runs, and what a dry run shows of them.

test_publish_needs_a_plan_that_reaches_product() {
    make_project
    use_fake_build_settings
    run_app_release all --to export --publish --dry-run
    expect_failure_containing "--publish needs a plan that reaches product"
}

test_publish_never_combines_with_allow_dirty() {
    make_project
    use_fake_build_settings
    run_app_release all --publish --allow-dirty --dry-run
    expect_failure_containing "drop --allow-dirty"
}

test_skip_notarization_cannot_go_past_export() {
    make_project
    use_fake_build_settings
    run_app_release all --skip-notarization --to product --dry-run
    expect_failure_containing "cannot be combined with --to product"
}

test_from_must_not_come_after_the_last_stage() {
    make_project
    use_fake_build_settings
    run_app_release all --from export --to archive --dry-run
    expect_failure_containing "--from export comes after the last stage"
}

test_from_works_only_with_all() {
    make_project
    use_fake_build_settings
    run_app_release archive --from archive
    expect_failure_containing "--from works with all"
}

test_an_unknown_stage_is_refused() {
    make_project
    run_app_release package
    expect_failure_containing "unknown stage 'package'"
}

test_x86_64_turns_off_the_new_package_builder() {
    make_project
    use_fake_build_settings ARCHS="arm64 x86_64"
    run_app_release all --to archive --dry-run
    expect_success
    expect_output_containing "-IDEEnableNewPackagePIFBuilder=NO"
}

test_an_arm64_only_app_keeps_the_new_package_builder() {
    make_project
    use_fake_build_settings ARCHS=arm64
    run_app_release all --to archive --dry-run
    expect_success
    expect_output_not_containing "IDEEnableNewPackagePIFBuilder"
}

test_a_dry_run_of_a_whole_release_lists_every_step() {
    make_project
    configure_release release_notary_keychain_profile=SampleProfile
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    export FAKE_NOTARY_ACCEPTS_CREDENTIALS=1
    run_app_release all --dry-run
    expect_success
    expect_output_containing "xcodebuild archive"
    expect_output_containing "-exportArchive"
    expect_output_containing "notarytool submit"
    expect_output_containing "stapler staple"
    expect_output_containing "SampleApp-1.2.3-45.zip"
    expect_output_containing "dry run finished"
}

test_a_dry_run_of_a_publish_lists_the_tag_and_the_release() {
    make_project
    add_origin
    configure_release release_notary_keychain_profile=SampleProfile 'release_publishers=(github-release)'
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    export FAKE_NOTARY_ACCEPTS_CREDENTIALS=1
    run_app_release all --dry-run --publish
    expect_success
    expect_output_containing "push origin refs/tags/v1.2.3"
    expect_output_containing "gh release create v1.2.3 --repo example/SampleApp"
}

test_the_product_name_template_keeps_a_project_file_name() {
    make_project
    configure_release release_notary_keychain_profile=SampleProfile "release_product_name='{name}-macOS.zip'"
    use_fake_build_settings
    export FAKE_SECURITY_IDENTITY="Developer ID Application: Sample Developer (TEAMID1234)"
    export FAKE_NOTARY_ACCEPTS_CREDENTIALS=1
    run_app_release all --dry-run
    expect_success
    expect_output_containing "Products/SampleApp-macOS.zip"
}
