# AppRelease

AppRelease ships a Mac app outside the App Store: archive, export with Developer ID, notarize, staple,
zip, and optionally publish a GitHub Release and a Sparkle appcast. It is one engine shared by many
projects. Each project describes itself in a small `Release.zsh` and pins the engine version it uses.

```text
target   resolve the plan; check certificates, notary credentials, git state, tag   → manifest.json
archive  xcodebuild archive; check it is an app archive with the expected slices    → .xcarchive
export   xcodebuild -exportArchive (Developer ID); check signature, runtime, versions → .app
notary   notarytool submit and wait; staple; check Gatekeeper says "Notarized"       → stapled .app
product  zip, dSYMs, SHA256SUMS; with --publish: tag, GitHub Release, appcast        → Products/
```

Every stage reads what the previous one left in the run directory, checks its own result, and records
it in `manifest.json`. Any stage can run on its own, and a failed or timed-out run continues where it
stopped: an interrupted notarization waits on the same submission instead of uploading again.

## Requirements

macOS 15 or later (for `/usr/bin/jq`), Xcode, and git. Publishing needs the GitHub CLI (`gh`);
appcasts need the Sparkle package in the app (its `generate_appcast` is used).

## Install

Double-click `Install app-release.command`, or run `./app-release --install`. Either copies the
launcher into `~/.local/bin`. The launcher reads the version a project pins and runs exactly that
version, fetching it once into `~/Library/Caches/AppRelease/<version>`.

## Quick start

Put a `Release.zsh` at the root of the project:

```zsh
release_engine_version=1.0.0
release_workspace=MyApp.xcworkspace
release_scheme=MyApp
release_notary_keychain_profile=MyNotaryProfile   # from: xcrun notarytool store-credentials MyNotaryProfile
```

Ignore `build/` in git, then:

```sh
app-release target              # check everything; build nothing
app-release all                 # target through product; nothing leaves the Mac
app-release all --from notary   # continue the latest run
app-release product --publish   # tag, GitHub Release, appcast
```

`app-release --help` lists every option.

## Release.zsh

| Variable | Default | Meaning |
|---|---|---|
| `release_engine_version` | required | The exact AppRelease version to run |
| `release_workspace` / `release_project` | one required | What to archive |
| `release_scheme` | required | |
| `release_application_target` | the scheme's only app | Needed when the scheme builds several apps |
| `release_configuration` | `Release` | |
| `release_destination` | `generic/platform=macOS` | |
| `release_architectures` | the target's `ARCHS` | Checked with `lipo` after archiving |
| `release_archive_arguments` | none | Extra `xcodebuild archive` arguments; signing settings are not overridden unless given here |
| `release_xcode_path` | the selected Xcode | Becomes `DEVELOPER_DIR` |
| `release_team_identifier` | `DEVELOPMENT_TEAM` | The team whose Developer ID must sign the app |
| `release_export_options_path` | generated | Generated: `developer-id`, manual signing with `Developer ID Application`, the team |
| `release_notary_keychain_profile` | none | For local runs; CI uses an App Store Connect key |
| `release_build_number_source` | `project` | `project`, `commit-count`, or `semantic-version-encoding` |
| `release_version_tag_match` | `exact` | `base` lets a tag add a prerelease suffix to a numeric version |
| `release_product_name` | `{name}-{version}-{build}.zip` | Placeholders `{name}` `{version}` `{build}` `{tag}` |
| `release_publishers` | none | `github-release`, `sparkle-appcast` |
| `release_notes_path` | none | Release notes file, with placeholders, for the GitHub Release |
| `release_appcast_path` | none | Required with `sparkle-appcast` |
| `release_appcast_arguments` | none | Extra `generate_appcast` arguments |

The version comes from the project: `MARKETING_VERSION`, or the Info.plist's own value. A
`--version-tag` must match it. `commit-count` and `semantic-version-encoding` pass
`CURRENT_PROJECT_VERSION` to the archive, so the Info.plist must use `$(CURRENT_PROJECT_VERSION)`.
`semantic-version-encoding` turns `1.9.0-beta.5` into `10900105`, keeping build numbers ordered across
alpha, beta, rc, and final releases.

## Hooks

Define any of these functions in `Release.zsh`. Each runs in a subshell with `err_exit`, so a failing
command fails the hook and stops the release.

| Hook | Called | Argument |
|---|---|---|
| `release_preflight` | at the end of `target` | none |
| `release_before_archive` | before `xcodebuild archive` | none |
| `release_verify_archive` | after the archive checks | the `.xcarchive` |
| `release_verify_export` | after the signature checks | the exported `.app` |
| `release_after_product` | after the zip is made | the `Products` directory |
| `release_compose_notes` | before publishing, when the notes file is missing | the path to write |
| `release_deploy_appcast` | after `generate_appcast` | the appcast |

Hooks may use `app_release_xcodebuild <log name> <arguments...>` (the engine's own way into
`xcodebuild`), `app_release_add_product <file> [--not-notarized]`, `app_release_log`,
`app_release_fail`, and the read-only `app_release_*` variables, such as `app_release_run_directory`,
`app_release_marketing_version`, `app_release_build_number`, `app_release_tag`, and
`app_release_project_arguments` (whatever follows `--` on the command line).

## Continuous integration

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- name: Release
  env:
    GH_TOKEN: ${{ github.token }}
    APP_RELEASE_CERTIFICATE_BASE64: ${{ secrets.DEVELOPER_ID_CERTIFICATE_BASE64 }}
    APP_RELEASE_CERTIFICATE_PASSWORD: ${{ secrets.DEVELOPER_ID_CERTIFICATE_PASSWORD }}
    APP_RELEASE_NOTARY_KEY_BASE64: ${{ secrets.NOTARY_KEY_BASE64 }}
    APP_RELEASE_NOTARY_KEY_IDENTIFIER: ${{ secrets.NOTARY_KEY_IDENTIFIER }}
    APP_RELEASE_NOTARY_ISSUER_IDENTIFIER: ${{ secrets.NOTARY_ISSUER_IDENTIFIER }}
  run: |
    engine_version=$(sed -nE 's/^release_engine_version=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' Release.zsh)
    git clone --quiet --depth 1 --branch "$engine_version" https://github.com/Mx-Iris/AppRelease "$RUNNER_TEMP/AppRelease"
    "$RUNNER_TEMP/AppRelease/app-release" all --version-tag "$GITHUB_REF_NAME" --publish
```

With `APP_RELEASE_CERTIFICATE_BASE64` set, the engine creates a temporary keychain that does not lock
on sleep, imports the certificate, installs any `APP_RELEASE_PROVISIONING_PROFILE_<NAME>_BASE64`
profiles, and removes all of it when it exits.

| Environment variable | Meaning |
|---|---|
| `APP_RELEASE_CERTIFICATE_BASE64`, `APP_RELEASE_CERTIFICATE_PASSWORD` | Developer ID Application `.p12` |
| `APP_RELEASE_PROVISIONING_PROFILE_<NAME>_BASE64` | Provisioning profiles, any number |
| `APP_RELEASE_NOTARY_KEY_BASE64`, `APP_RELEASE_NOTARY_KEY_IDENTIFIER`, `APP_RELEASE_NOTARY_ISSUER_IDENTIFIER` | App Store Connect API key |
| `APP_RELEASE_SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key (`generate_keys -x`) |
| `APP_RELEASE_NOTARY_KEYCHAIN_PROFILE` | Overrides `release_notary_keychain_profile` |
| `APP_RELEASE_OUTPUT_ROOT` | Default `<project>/build/AppRelease` |
| `APP_RELEASE_DERIVED_DATA_PATH` | Default `<output root>/DerivedData/<scheme>` |
| `APP_RELEASE_ENGINE_DIRECTORY` | Run a local engine checkout instead of the pinned version |

## Versioning

AppRelease follows semantic versioning. New optional variables, hooks, helpers, products, or
publishers are minor releases. Renaming or removing any of them, changing a default so that a
project's output changes, or changing what a manifest field means is a major release. A run can only
be continued by the engine version that started it.

## Development

```sh
zsh -f Tests/Run.zsh                 # syntax and all tests with faked Xcode tools
APP_RELEASE_TEST_DERIVED_DATA_PATH=/path/to/DerivedData zsh -f Tests/Run.zsh --integration
```

The integration tests archive an ad hoc signed sample app; no certificate is needed.

## License

MIT
