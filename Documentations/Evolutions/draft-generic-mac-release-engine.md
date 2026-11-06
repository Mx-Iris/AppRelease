# Draft - 通用 Mac 发版引擎 AppRelease

- **状态**: In Progress
- **作者**: JH
- **创建日期**: 2026-11-05
- **最后更新**: 2026-11-06
- **所属愿景**: 无
- **关联提案**: XCOrganizer《一条命令编出公证过的 XCOrganizer》（`Documentations/Evolutions/draft-build-notarized-app.md`，已 Withdrawn，由本提案取代）；InjectionScaffold《0004 - 模板带上归档脚本》（Draft，脚手架接入引擎时改写）
- **实现分支 / PR**: `feature/generic-mac-release-engine`
- **配套文档**: 待定 —— 落地时登记使用指南 `Documentations/Guides/ReleaseConfiguration.md`

## 摘要

AppRelease 是一个用 zsh 写的发版引擎，把「归档 → 导出 → 公证 → 打包 → 发布」固定成五段流水线 `target → archive → export → notary → product`：每段只读上一段的产物，做完自己验收，验收不过就停，结果写进运行目录里的 `manifest.json`，所以任何一段都能单独重跑、失败后从断点续跑。项目只在根目录放一份 `Release.zsh`，钉住要用的引擎版本、声明引擎读不到的变量、按需定义钩子函数。引擎放在单独的公开仓库 `Mx-Iris/AppRelease`，本机由启动器按项目钉住的版本执行，CI 只剩几行 YAML，签名与公证凭据也由引擎处理。第一版只支持「Xcode App + zip」，用来分批替换 XCOrganizer、FinderSidebarIconFix、RuntimeViewer、LyricsX、StarLight 五个项目现有的五套发版脚本。

## 动机

五个项目各有一套发版脚本，骨架几乎一样：预检 → `xcodebuild archive` → `xcodebuild -exportArchive` → `notarytool` 公证 → staple（把公证票据钉进 App，离线也能通过 Gatekeeper）→ `ditto` 打 zip → 可选发布。差别只在凭据、版本号、项目专属的校验和发布方式。

问题是：某个项目踩坑后的修复只留在它自己的脚本里，其余项目照旧带着同一个坑。下面都是已经发生的例子：

| 修复 | 只在哪里有 | 其余项目的现状 |
|---|---|---|
| Xcode 27 新的 package PIF builder（Xcode 把 Swift 包转成构建图的那一步）给包写死 `arm64 arm64e arm64e.x1`，出 x86_64 的归档会失败；归档时传 `-IDEEnableNewPackagePIFBuilder=NO` | RuntimeViewer（next）`ArchiveScript.sh:216` | 都没有。任何出 x86_64、带 SwiftPM 依赖的项目，在没改过这个默认值的机器（包括 GitHub 的 runner）上都会撞上 |
| 归档后检查是不是 App 归档：多出一个会安装的命令行 target 时归档变成 Generic Xcode Archive，Developer ID 导出被拒 | RuntimeViewer `ArchiveScript.sh:366-369` | 都没有 |
| CI 临时钥匙串的设置不带 `-l`（睡眠即上锁），否则 runner 睡眠后 codesign 弹窗卡住 40 多分钟 | RuntimeViewer `.github/workflows/release.yml:83`（`-ut 21600`） | StarLight `scripts/release.sh:87`、LyricsX `Scripts/release/setup-keychain.sh:63` 仍是 `-lut 21600` |
| 公证结果只认 JSON 里的 `status`，不是 `Accepted` 就取 `notarytool log` 打印被拒原因 | XCOrganizer `Scripts/BuildNotarizedApp.sh:201-213`、LyricsX `Scripts/release/notarize.sh:36-56` | RuntimeViewer `ArchiveScript.sh:457-470`、FinderSidebarIconFix `ArchiveScript.sh:484-495`、StarLight `scripts/release.sh:186` 只看退出码，被拒时看不到原因 |
| staple 之后用 `spctl` 核对 `source=Notarized Developer ID`（Gatekeeper 评估被关掉时 `spctl` 什么都放行，只有 source 还能分辨） | XCOrganizer `BuildNotarizedApp.sh:219-225` | 都没有 |

同一件事还写了好几份：CI 建临时钥匙串在 StarLight、LyricsX、RuntimeViewer 各写一份；`fail` / `log` / `run` / `run_piped` 这组工具函数在 RuntimeViewer 和 FinderSidebarIconFix 之间复制，InjectionScaffold 的 0004 草案还打算再复制一份进模板。

继续各写各的，每踩一个新坑就要修五遍，而且总有几处会漏掉。

## 前期调研

### 现有脚本盘点

RuntimeViewer 以 next 分支为准（上面那些修复都在 next 上）。

| 项目 | 脚本 | 在哪发版 | 发布 | 项目专属的部分 |
|---|---|---|---|---|
| XCOrganizer（私有） | `Scripts/BuildNotarizedApp.sh`（zsh，232 行） | 本机 | 无 | `Scripts/CheckEmbeddedHelpers.sh` 检查内嵌 helper（`:183`）；归档时覆盖签名设置为 Developer ID（`:152-154`） |
| FinderSidebarIconFix（私有） | `ArchiveScript.sh`（bash，531 行） | 本机 | `gh release`（`:512-518`） | arm64e 切片（`:332`）、launchd plist（`:344`）、`--export-method` 切换 |
| RuntimeViewer（公开） | `ArchiveScript.sh`（bash，608 行） | CI 与本机 | `gh release`、Sparkle `generate_appcast`、appcast 提交或开 PR（`:553-592`） | 拉 SourceEditor framework、先归档 Catalyst helper、iOS Simulator 载荷、图标校验 |
| LyricsX（公开） | `Scripts/release/` 下 12 个按阶段拆开的脚本 | CI | `gh release`、`sign_update` 加自写 Python 改 appcast、推旧 Pages 仓库做镜像 | 3 个 Developer ID 描述文件、build number 编码、版本写在 Info.plist 字面值里 |
| StarLight（公开） | `scripts/release.sh`（bash，203 行） | CI | 在 YAML 里 `gh release`（`release.yml:99-106`） | 无 |

- 全部只发 App 的 zip。没有项目发 dmg、pkg，也没有项目发经过公证的独立命令行工具（MachOSwiftSection 的 `swift-section` 只做 ad hoc 签名，`build-executable-product.sh:78`）。
- 五个项目发版时都不跑测试，三个 CI 项目也没有单独的测试 workflow。
- LookInside（`Lakr233/LookInside`）也有一套（`Scripts/build-and-release.sh` 等），但仓库属于 Lakr233，不在本提案范围。

### 版本号的三种现状

- **XCOrganizer**：从导出 App 的 Info.plist 读（`BuildNotarizedApp.sh:190-192`）。
- **RuntimeViewer**：`MARKETING_VERSION` 写在 `Configurations/Version.xcconfig`，带预发布后缀（例如 `3.0.0-beta.5`）；`--version-tag` 必须与它完全一致。
- **LyricsX**：版本写在 Info.plist 的字面值里，而且只写数字部分（`LyricsX/Supporting Files/Info.plist` 里是 `1.9.0`），tag 可以多一个后缀（`v1.9.0-beta.5`），`validate.sh:37-40` 允许「完全一致或等于去掉后缀的部分」。build number 由 `lib.sh:67` 的 `encode_build_number` 从 tag 的完整版本算出（`MAJOR*10_000_000 + MINOR*100_000 + PATCH*1_000 + 子标签`，alpha 1–99、beta 101–199、rc 201–299、正式版 999），再用 PlistBuddy 写进 CI 工作副本里的 Info.plist（`validate.sh:49-54`）。

### 产物文件名是对外的契约

RuntimeViewer 用固定名 `RuntimeViewer-macOS.zip`（`ArchiveScript.sh:492`），FinderSidebarIconFix 用 `FinderSidebarIconFix-macOS.zip`（`:212`），LyricsX 用 `LyricsX_<VERSION>+<BUILD>.zip`（`package.sh:17`），StarLight 用 `StarLight-<tag>.zip`（`release.sh:53`）。README 或下载链接可能依赖这些名字，引擎不能把它们统一改掉。

### 签名设置不能在归档时一律覆盖

XCOrganizer 在归档命令上覆盖 `CODE_SIGN_STYLE` / `CODE_SIGN_IDENTITY`，而 LyricsX 特意不覆盖：覆盖会泄漏到 Automatic 签名的 SwiftPM 依赖 target，报 "conflicting provisioning settings"（`Scripts/release/build.sh:41-47`）。所以引擎默认不碰归档的签名设置，需要的项目自己追加参数。

### Sparkle

Sparkle 是这两个项目用的自动更新框架，appcast 是它读的更新源 XML。

- **RuntimeViewer**：把新 zip 放进一个临时目录，交给 `generate_appcast`，用 `-o docs/appcast.xml` 合并进已有的 appcast（现有 7 个条目，说明逐版合并可行），参数有 `--download-url-prefix`、`--release-notes-url-prefix`、`--ed-key-file`、`--channel beta`（`ArchiveScript.sh:496-528`）。工具优先取 DerivedData 下 `SourcePackages/artifacts/sparkle/Sparkle/bin/` 里的那份，与 App 链接的 Sparkle 版本一致（`:259-286`）。
- **LyricsX**：用 `sign_update` 只算签名和长度（`sign-sparkle.sh`），再由自写的 `update-appcast.py` 改 appcast，分两处推送：本仓库的 canonical 和旧 Pages 仓库的 mirror（`publish-appcast.sh`，后者需要 `PAGES_MIRROR_TOKEN`）。它自己从 xcconfig 推算 `minimumSystemVersion`；`generate_appcast` 直接读主 App Info.plist 的 `LSMinimumSystemVersion`，应能得到同样的值（推测，迁移 LyricsX 时逐字段核对）。

### CI 凭据

- 三个 CI 项目都在 runner 上建临时钥匙串、导入 Developer ID Application 的 .p12。
- LyricsX 还要装 3 个 Developer ID 描述文件到 `~/Library/MobileDevice/Provisioning Profiles/`（`setup-keychain.sh:85-100`），导出用仓库里的 `ExportOptions.plist`（manual 签名，带 `provisioningProfiles` 映射）。Xcode 16 之后是否改从 `~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 读描述文件，没有核实；LyricsX 现在的位置在 macos-26 runner 上能用。
- 公证凭据：本机多用 `notarytool store-credentials` 存进钥匙串的 profile，CI 用 App Store Connect API key（.p8）。
- ssh 会话拿不到登录钥匙串（两台 Mac 之间的 git HTTPS 凭据就因此失败）；codesign 在这种会话里通常报 `errSecInternalComponent`（常见现象，没有在本机复现）。

### 工具与环境

- `notarytool submit` 支持 `--wait --timeout <时长> --output-format json`；`notarytool wait <submission-id>` 能接着等一个已经提交的请求，不用重新上传（本机 Xcode 27.2 的 `notarytool --help`）。
- `queued-build` 支持嵌套：它给子进程设 `QUEUED_BUILD_HOLDER`，构建内部再调用不会死锁（`Repositories/Scripts/queued-build.md:87`）。所以引擎内部给 xcodebuild 套上它是安全的；在没有它的机器（CI）上直接执行。
- macOS 15 起系统自带 `/usr/bin/jq`（本机为 `jq-1.7.1-apple`）。
- 本机同时装着 Xcode 26.6、27.2、27.3 beta，用哪个必须显式指定。
- 命令行上的 `-IDEEnableNewPackagePIFBuilder=NO` 能盖过机器上持久化的默认值，已在 RuntimeViewer 验证（`Documentations/ResolvedIssues/2026-09-27-release-archive-packages-lost-x86-64.md`）。在 Xcode 26 上传这个参数是否无害没有验证（推测：不认识的 user default 会被忽略）。

## 提议方案

### 五段流水线

| 段 | 做什么 | 产出 | 验收（不过就停） |
|---|---|---|---|
| `target` | 读 `Release.zsh` 和 scheme 的 build settings，指定 Xcode，定版本号、build number 和 tag，预检 | `manifest.json` | Developer ID 证书在、公证凭据可用、git 工作区干净、tag 没被别的提交占用、hardened runtime 已开、不在没有 CI 凭据的 ssh 会话里、`release_preflight` 钩子 |
| `archive` | `xcodebuild archive` | `<scheme>.xcarchive` | 是 App 归档、主可执行文件的 `lipo -archs` 与声明一致、`release_verify_archive` 钩子 |
| `export` | `xcodebuild -exportArchive`（Developer ID） | `Export/<App>.app` | `codesign --verify --deep --strict` 通过；签名者是本团队的 Developer ID Application；带 hardened runtime 和安全时间戳；Info.plist 的版本号、build number 与 manifest 一致；`release_verify_export` 钩子 |
| `notary` | `ditto` 打提交包 → `notarytool submit --wait` → staple | staple 过的 App | `status` 是 `Accepted`、`stapler validate` 通过、`spctl` 给出 `source=Notarized Developer ID` |
| `product` | `ditto` 打 zip、归档 dSYM（崩溃符号化用的调试符号）、算 SHA256；带 `--publish` 时对外发布 | `Products/` | 把 zip 解开重新做 `stapler validate` 与 `spctl`，确认打进去的是 staple 过的 App |

命名照 Xcode 的动作：`archive` 就是 `xcodebuild archive`，`export` 就是 `-exportArchive`。

### 项目怎么接入

项目根目录放一份 `Release.zsh`，由引擎 `source`。里面只写三类东西：钉住的引擎版本、引擎读不到或需要覆盖的变量、可选的钩子函数。然后运行 `app-release all`。

### 引擎怎么分发

- 公开仓库 `Mx-Iris/AppRelease`，tag 用不带 `v` 的语义化版本（`1.0.0`），和 SwiftPM 包的习惯一致。许可证 MIT，README 用英文。
- 项目在 `Release.zsh` 里写 `release_engine_version=1.0.0`，钉的是确切版本。
- 本机：`Install app-release.command` 把启动器 `app-release` 装进 `~/.local/bin`。启动器读项目钉住的版本，从 `~/Library/Caches/AppRelease/<版本>/` 取引擎，没有就浅克隆那个 tag 一次。
- CI：YAML 读出钉住的版本，浅克隆那个 tag，运行它自带的启动器。

### 凭据

- **本机**：签名用登录钥匙串里的 Developer ID Application；公证用 `release_notary_keychain_profile` 指定的 keychain profile；Sparkle 的 EdDSA 私钥用 `generate_keys` 存进登录钥匙串的那份。
- **CI**：所有凭据经环境变量给出。引擎建临时钥匙串（`set-keychain-settings -ut`，不带 `-l`），导入证书、装描述文件、把 key 写成临时文件；退出时（包括失败）删除临时钥匙串、恢复钥匙串搜索列表、删掉临时文件。
- **ssh 会话**：没有 CI 凭据时，`target` 段直接拒绝并说明原因，不等到签名时才失败。

### 发布（`--publish`）

顺序固定，保证用户的 App 读到新 appcast 时，下载地址已经存在：

1. **tag**：不存在就在 HEAD 上打 annotated tag 并推送；已经存在则必须指向 HEAD。
2. **GitHub Release**：不存在就创建（预发布加 `--prerelease`），已存在就 `gh release upload --clobber`。
3. **appcast**：`generate_appcast` 合并进 `release_appcast_path`，下载地址前缀是这个 Release 的资产地址，预发布放进 `beta` channel。
4. **上线**：调用项目的 `release_deploy_appcast` 钩子，由项目决定是直接提交、开 PR，还是推镜像。

### 非目标

- dmg、pkg、独立命令行工具。代码里按产物类型分派，留好位置，第一版只实现 App + zip。
- 测试关卡。发版时不跑测试。
- 改工程里的版本号、自动递增、提交版本变更。
- LookInside，以及两个脚手架模板（InjectionScaffold、ApplicationScaffold）的接入，以后另写提案。
- 在引擎自己的 CI 里做真实签名与公证。
- Mac App Store 发布。
- 把引擎包装成 GitHub Action。

## 详细设计

### 仓库结构

```
AppRelease/
├── app-release                     Launcher, installed into ~/.local/bin
├── Install app-release.command     Double-click installer
├── Sources/
│   ├── Version                     This checkout's engine version, read by the launcher
│   ├── Engine.zsh                  Argument parsing, stage dispatch, run directory
│   ├── Stages/                     Target.zsh, Archive.zsh, Export.zsh, Notary.zsh, Product.zsh
│   ├── Publishers/                 GitHubRelease.zsh, SparkleAppcast.zsh
│   └── Support/                    Logging.zsh, Manifest.zsh, Xcodebuild.zsh, Credentials.zsh,
│                                   Versioning.zsh, Verification.zsh
├── Tests/
│   ├── Fixtures/SampleApp/         Minimal Xcode app used by the tests
│   └── Test*.zsh
├── Documentations/
├── README.md
└── LICENSE
```

### 命令行

```zsh
app-release target                     # resolve and preflight only; prints the plan
app-release archive                    # every stage can run alone, reading the previous stage's output
app-release export
app-release notary
app-release product [--publish]
app-release all [--from <stage>] [--to <stage>] [--publish]
app-release target --to <stage>        # check only what the stages up to <stage> need

# Options shared by every stage:
#   --version-tag <tag>           e.g. v1.4.0 or v3.0.0-beta.5; checked against the project's version
#   --skip-notarization           stop after export and make no zip, so nothing unnotarized looks like a release
#   --derived-data-path <path>    overrides APP_RELEASE_DERIVED_DATA_PATH
#   --allow-dirty                 skip the clean working tree check; refused together with --publish
#   --dry-run                     print every command instead of running it
#   -- <arguments>                handed to the hooks as app_release_project_arguments
```

### `Release.zsh` 的约定

以 XCOrganizer 为例：

```zsh
# Release.zsh — read by AppRelease (https://github.com/Mx-Iris/AppRelease)
release_engine_version=1.0.0

release_workspace=XCOrganizer.xcworkspace
release_scheme=XCOrganizer
release_archive_arguments=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Developer ID Application"
)
release_notary_keychain_profile=XCOrganizerNotary   # the name given to notarytool store-credentials

# Every embedded helper must be able to start before anything is notarized.
release_verify_export() {
    local application_path=$1
    "$app_release_project_directory/Scripts/CheckEmbeddedHelpers.sh" "$application_path"
}
```

**命名约定**：项目定义的变量和钩子以 `release_` 开头；引擎提供给钩子的函数和只读变量以 `app_release_` 开头；环境变量以 `APP_RELEASE_` 开头。引擎内部函数以 `_app_release_` 开头，不属于契约。

**变量**

| 变量 | 默认 | 说明 |
|---|---|---|
| `release_engine_version` | 必填 | 要运行的 AppRelease 确切版本 |
| `release_workspace` / `release_project` | 二选一必填 | 归档用的 workspace 或 project |
| `release_scheme` | 必填 | |
| `release_application_target` | scheme 里唯一的 App target | scheme 构建多个 App 时指定发哪一个 |
| `release_configuration` | `Release` | |
| `release_destination` | `generic/platform=macOS` | 需要特殊切片（例如 arm64e）的项目可以改 |
| `release_architectures` | scheme 的 `ARCHS` | `archive` 段用 `lipo -archs` 核对主可执行文件；含 `x86_64` 时归档带上 `-IDEEnableNewPackagePIFBuilder=NO` |
| `release_archive_arguments` | 空 | 追加给 `xcodebuild archive` 的参数。引擎默认不覆盖签名设置 |
| `release_xcode_path` | 当前选中的 Xcode | 引擎据此导出 `DEVELOPER_DIR` |
| `release_team_identifier` | scheme 的 `DEVELOPMENT_TEAM` | 用来核对签名者 |
| `release_export_options_path` | 引擎生成 | 生成的内容：`method=developer-id`、`signingStyle=manual`、`signingCertificate=Developer ID Application`、`teamID`。需要描述文件的项目（LyricsX）指向自己的文件 |
| `release_notary_keychain_profile` | 无 | 本机公证用；CI 用 API key 的环境变量 |
| `release_build_number_source` | `project` | `project`、`commit-count`、`semantic-version-encoding`，见「版本号」 |
| `release_version_tag_match` | `exact` | `exact`：tag 去掉 `v` 后与版本号完全一致；`base`：tag 可以多一个预发布后缀 |
| `release_product_name` | `{name}-{version}-{build}.zip` | 占位符有 `{name}`（App 名）、`{version}`、`{build}`、`{tag}` |
| `release_publishers` | 空 | 可选 `github-release`、`sparkle-appcast` |
| `release_notes_path` | 无 | 发布说明文件，可用占位符，例如 `Changelogs/{tag}.md`；用作 GitHub Release 正文 |
| `release_notes_fallback` | `none` | `generated`：没有说明文件时，用 GitHub 按提交历史生成的说明（1.1.0 起） |
| `release_appcast_path` | 无 | 列了 `sparkle-appcast` 时必填 |
| `release_appcast_arguments` | 空 | 追加给 `generate_appcast` 的参数，例如 RuntimeViewer 的 `--release-notes-url-prefix` |

**钩子**（都可选，定义了才调用；返回非零即视为验收失败）

| 钩子 | 何时调用 | 参数 | 例子 |
|---|---|---|---|
| `release_preflight` | `target` 段末尾 | 无 | 检查项目特有的前提 |
| `release_before_archive` | `archive` 段开始前 | 无 | RuntimeViewer：拉 SourceEditor framework、先归档并导出 Catalyst helper |
| `release_verify_archive` | `archive` 段验收 | `.xcarchive` 路径 | FinderSidebarIconFix：arm64e 切片、launchd plist |
| `release_verify_export` | `export` 段验收 | 导出的 `.app` 路径 | XCOrganizer：内嵌 helper；RuntimeViewer：图标、内嵌 framework、模拟器载荷 |
| `release_after_product` | `product` 段打完 zip 之后 | `Products/` 路径 | RuntimeViewer：登记 iOS Simulator 载荷；LyricsX：登记 dSYM 压缩包 |
| `release_compose_notes` | 发布前，`release_notes_path` 指向的文件不存在时 | 要写入的路径 | LyricsX：生成发布说明 |
| `release_deploy_appcast` | appcast 生成之后 | appcast 路径 | RuntimeViewer：提交或开 PR；LyricsX：提交并推 Pages 镜像 |

**引擎提供给钩子的东西**

| 名字 | 作用 |
|---|---|
| `app_release_xcodebuild <日志名> <参数…>` | 与引擎自己的 xcodebuild 调用走同一个入口（见下文） |
| `app_release_log <消息>` / `app_release_fail <消息>` | 统一输出；`fail` 以非零状态退出 |
| `app_release_add_product <路径> [--not-notarized]` | 登记额外产物：写进 `SHA256SUMS`、随 GitHub Release 上传；`--not-notarized` 表示跳过 Gatekeeper 检查 |
| `app_release_project_directory`、`app_release_run_directory`、`app_release_derived_data_path` | 位置 |
| `app_release_marketing_version`、`app_release_build_number`、`app_release_tag`、`app_release_is_prerelease` | 版本信息 |
| `app_release_project_arguments` | 命令行 `--` 之后的参数（数组），给项目自定义开关用，例如 RuntimeViewer 的 `--local-deps` |

### 启动器

启动器只用正则读出钉住的版本，不 `source` `Release.zsh`；执行项目代码的只有引擎。

```zsh
#!/bin/zsh
# app-release (sketch): run exactly the AppRelease version that the project pins.
set -euo pipefail

project_directory=$PWD
while [[ ! -f $project_directory/Release.zsh ]]; do
    if [[ $project_directory == / ]]; then
        print -u2 -r -- "No Release.zsh in ${PWD} or any parent directory"
        exit 64
    fi
    project_directory=${project_directory:h}
done

engine_version=$(sed -nE 's/^release_engine_version=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$project_directory/Release.zsh")
if [[ -z $engine_version ]]; then
    print -u2 -r -- "Release.zsh does not pin release_engine_version"
    exit 64
fi

launcher_directory=${0:A:h}
if [[ -n ${APP_RELEASE_ENGINE_DIRECTORY:-} ]]; then
    engine_directory=$APP_RELEASE_ENGINE_DIRECTORY
    print -u2 -r -- "warning: running the engine in ${engine_directory}, not the pinned ${engine_version}"
elif [[ -f $launcher_directory/Sources/Version && $(< $launcher_directory/Sources/Version) == $engine_version ]]; then
    engine_directory=$launcher_directory    # a checkout of the pinned tag, as in CI
else
    engine_directory=$HOME/Library/Caches/AppRelease/$engine_version
    # Missing: shallow-clone the tag into a temporary directory, then move it into place.
fi

APP_RELEASE_PROJECT_DIRECTORY=$project_directory exec zsh "$engine_directory/Sources/Engine.zsh" "$@"
```

### 运行目录与 manifest

```
<output root>/<scheme>/<version>-<build>/
├── manifest.json
├── logs/                     archive.log, export.log, notary-<submission>.json, ...
├── <scheme>.xcarchive
├── ExportOptions.plist
├── Export/<App>.app
├── DebugSymbols/<App>.dSYMs.zip
└── Products/                 <release_product_name>, SHA256SUMS, extra products
```

- 输出根默认是 `<项目>/build/AppRelease`（项目要 gitignore `build/`），用 `APP_RELEASE_OUTPUT_ROOT` 改；两台 Mac 上可以指向外置卷。
- DerivedData 默认是 `<输出根>/DerivedData/<scheme>`，与 Xcode 界面里的构建分开，避免同时构建时抢构建数据库。`APP_RELEASE_DERIVED_DATA_PATH` 或 `--derived-data-path` 可改；agent 运行时指向 agent 专属目录。
- `manifest.json` 记录：`schemaVersion`、引擎版本、git commit、Xcode 版本与路径、版本号 / build number / tag / 是否预发布、每段的完成时间和关键产出、公证的 submission id 与结果、每个产物的 SHA256。
- **续跑**：`--from <stage>` 要求前面各段在 manifest 里都已完成、git commit 与当前 HEAD 相同、引擎版本相同，否则拒绝。不带 `--from` 的 `all` 只删掉这次会重新生成的东西。
- **公证续等**：`notary` 段发现 manifest 里有 submission id 却没有结果时，用 `notarytool wait` 接着等，不重新上传。

### xcodebuild 入口

引擎和钩子的每一次 xcodebuild 都走这一个函数：

```zsh
# Sources/Support/Xcodebuild.zsh (sketch)
app_release_xcodebuild() {
    local log_path="$app_release_run_directory/logs/$1.log"
    shift
    local -a command=(xcodebuild "$@")
    # Serializes builds on the shared Mac; nesting is safe. Absent on CI runners.
    if (( $+commands[queued-build] )); then
        command=(queued-build "${command[@]}")
    fi
    # A sleeping Mac locks keychains and stalls codesign.
    caffeinate -i "${command[@]}" > "$log_path" 2>&1
    local exit_status=$?
    # The summary is for reading only: xcsift, else xcbeautify, else the tail of the log.
    _app_release_summarize_log "$log_path"
    return $exit_status
}
```

`archive` 段在调用时加上 `-derivedDataPath`、`-destination`，以及（含 x86_64 时）`-IDEEnableNewPackagePIFBuilder=NO`。`DEVELOPER_DIR` 在 `target` 段导出一次。成败只认 xcodebuild 自己的退出状态，从不认摘要。

### 公证

```zsh
# Sources/Stages/Notary.zsh (sketch)
# zsh reserves $status, hence submission_status.
submission_result=$(xcrun notarytool submit "$submission_path" "${notary_credentials[@]}" \
    --wait --timeout 2h --output-format json) || true
submission_identifier=$(jq -r '.id // empty' <<< "$submission_result")
submission_status=$(jq -r '.status // empty' <<< "$submission_result")
```

- 提交包：`ditto -c -k --sequesterRsrc --keepParent <App> <提交包>.zip`。
- 拿到 submission id 立刻写进 manifest，超时或中断后可以续等。
- `status` 不是 `Accepted`：取 `notarytool log` 存到 `logs/notary-<id>.json`，打印每条 issue 的路径和原因，然后失败。
- staple 失败时重试 3 次、间隔 15 秒（预防票据刚生成时还查不到），之后 `stapler validate`，再用 `spctl --assess --type execute` 核对 `source=Notarized Developer ID`。

### 版本号

- **版本号**：先读 scheme build settings 里的 `MARKETING_VERSION`；没有就读 `INFOPLIST_FILE` 里 `CFBundleShortVersionString` 的字面值（LyricsX）。
- **tag**：`--version-tag` 给了就用，否则是 `v<版本号>`。按 `release_version_tag_match` 校验。
- **预发布**：tag 带 `-` 后缀即为预发布。
- **build number**：
  - `project`：读 `CURRENT_PROJECT_VERSION`，没有就读 Info.plist 的 `CFBundleVersion`。
  - `commit-count`：`git rev-list --count HEAD`。浅克隆时拒绝（CI 要 `fetch-depth: 0`）。
  - `semantic-version-encoding`：按 LyricsX 的公式从 tag 的完整版本算。
  - 后两种在归档时以 `CURRENT_PROJECT_VERSION=<n>` 注入，要求 Info.plist 写的是 `$(CURRENT_PROJECT_VERSION)`。`export` 段核对导出 App 的 `CFBundleVersion`，对不上就失败，不会悄悄发出错的 build number。

### CI 接入

```yaml
# .github/workflows/release.yml — the whole release job
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: Release
        env:
          GH_TOKEN: ${{ github.token }}
          APP_RELEASE_CERTIFICATE_BASE64: ${{ secrets.MACOS_CERTIFICATE_BASE64 }}
          APP_RELEASE_CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
          APP_RELEASE_NOTARY_KEY_BASE64: ${{ secrets.NOTARY_API_KEY_BASE64 }}
          APP_RELEASE_NOTARY_KEY_IDENTIFIER: ${{ secrets.NOTARY_API_KEY_ID }}
          APP_RELEASE_NOTARY_ISSUER_IDENTIFIER: ${{ secrets.NOTARY_API_ISSUER_ID }}
          APP_RELEASE_SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          engine_version=$(sed -nE 's/^release_engine_version=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' Release.zsh)
          git clone --quiet --depth 1 --branch "$engine_version" https://github.com/Mx-Iris/AppRelease "$RUNNER_TEMP/AppRelease"
          "$RUNNER_TEMP/AppRelease/app-release" all --version-tag "$GITHUB_REF_NAME" --publish
```

各项目现有的 secrets 不改名，在 `env:` 里映射到引擎读取的名字（上例的 secret 名只是示意）。

**环境变量**

| 环境变量 | 内容 |
|---|---|
| `APP_RELEASE_CERTIFICATE_BASE64`、`APP_RELEASE_CERTIFICATE_PASSWORD` | Developer ID Application 的 .p12（base64）和密码；设了它就进入 CI 凭据模式 |
| `APP_RELEASE_PROVISIONING_PROFILE_<名字>_BASE64` | 任意多个 Developer ID 描述文件（LyricsX 有 3 个） |
| `APP_RELEASE_NOTARY_KEY_BASE64`、`APP_RELEASE_NOTARY_KEY_IDENTIFIER`、`APP_RELEASE_NOTARY_ISSUER_IDENTIFIER` | App Store Connect API key |
| `APP_RELEASE_SPARKLE_PRIVATE_KEY` | `generate_keys -x` 导出的 EdDSA 私钥 |
| `APP_RELEASE_NOTARY_KEYCHAIN_PROFILE` | 覆盖 `release_notary_keychain_profile` |
| `APP_RELEASE_OUTPUT_ROOT`、`APP_RELEASE_DERIVED_DATA_PATH` | 输出位置 |
| `APP_RELEASE_ENGINE_DIRECTORY` | 用本地的引擎副本代替钉住的版本，供开发引擎和迁移期间使用；启动器会醒目提示 |

### Sparkle appcast

- `generate_appcast` 优先取 `<DerivedData>/SourcePackages/artifacts/sparkle/Sparkle/bin/` 下的那份（与 App 链接的 Sparkle 版本一致），其次取 PATH 里的，都没有就失败。
- 把这次的 zip 单独放进临时目录交给它，`-o` 指向 `release_appcast_path`，合并而不是重写。
- `--download-url-prefix` 是 `https://github.com/<owner>/<repo>/releases/download/<tag>/`；`--release-notes-url-prefix` 指向 Release 页面（沿用 RuntimeViewer 的做法）。
- 预发布加 `--channel beta`；CI 用 `--ed-key-file` 读环境变量里的私钥，本机用钥匙串里的。

### 测试

- **引擎 CI**（`Mx-Iris/AppRelease` 自己的 GitHub Actions，不存放任何证书）：所有脚本过 `zsh -n`；单元测试覆盖版本号解析与编码、tag 匹配、manifest 读写和续跑判断、产物名模板、`--dry-run` 的输出；示例 App 用 ad hoc 签名走完 `target` 和 `archive`。
- **反例**：给示例 App 多加一个会安装的命令行 target，确认 `archive` 段拦下 Generic 归档；声明 x86_64 却只编 arm64，确认 `lipo` 检查拦下。
- **真实签名与公证**：在本机迁移 XCOrganizer 时验收（落地步骤 3）。

## 替代方案考量

- **每个项目拷一份引擎**：CI 不用任何配置，但引擎一改就要逐个同步，正是现在各项目的修复不互通的成因。否。
- **独立仓库以 git submodule 挂进各项目**：版本钉在 commit 上、本机与 CI 必然一致，但每个 worktree 都要先初始化 submodule。否。
- **私有仓库**：四个 CI 项目是公开仓库，每个都要另配能读私有仓库的 token。否。
- **本机装最新版，主版本不符才拒绝**：实现最简单，但本机和 CI 的小版本可能不同，同一个提交在两边行为不一样。否。
- **把 Build 段做成可选的测试关卡**（`build` 跑测试，`archive` 做归档加导出）：名字能对上用户最初设想的五段，但开了测试的项目每次发版多一次完整编译和测试，而且这五个项目目前都不在发版时跑测试。否；五段改用 Xcode 的动作命名。
- **沿用 Build / Archive 的叫法但让 `build` 跑 `xcodebuild archive`**：只编一次，但 `archive` 子命令并不跑 `xcodebuild archive`，看日志时容易混。否。
- **版本统一以 tag 为准、归档时注入**：工程里的值不再起作用，在 Xcode 里直接 Archive 出来的版本会和发版对不上。否。
- **版本统一以工程为准、build number 也手动维护**：LyricsX 现有的编码方案得改成手动递增。否。
- **引擎只做到本地产物**：引擎最小，但发布逻辑仍然各写各的。否。
- **引擎再管版本号递增并提交**（LookInside 的做法）：引擎就要写仓库、推提交，出错的代价更大。否。
- **CI 继续自己管凭据**：引擎更简单，但三份建钥匙串的脚本留着，`-lut` 的问题也要逐个去修。否。
- **再发布一个 GitHub Action**：项目用一行 `uses:` 接入，但版本要同时钉在 YAML 和 `Release.zsh` 两处，还多一层接口要维护。否。
- **第一版就做 dmg、pkg、命令行工具**：工作量大约翻倍，而且暂时没有项目用得上。否。
- **Sparkle 只签名、appcast 交给项目**：LyricsX 不用改，但两套 appcast 生成方式会一直并存。否。
- **每个项目的迁移各写一份提案**：每个仓库自己的历史更完整，但多出五份几乎重复的文档；迁移的决定已经在本提案里做完。否。
- **引擎 CI 用 secrets 跑真实公证**：覆盖最全，但要把签名证书放进一个公开仓库的 secrets。否。
- **引擎不设 CI**：最省事，但改动没有任何自动把关。否。
- **其他名字**：`MacRelease` / `mac-release`、`ReleasePipeline` / `release-pipeline`。选定 `AppRelease`；已知将来支持命令行工具时，名字里的 App 不够贴切。
- **现成工具 fastlane（gym + notarize）**：多一个 Ruby 依赖；项目专属的部分仍要写成 Fastfile 里的 lane，等于换一种语言重写同样的钩子；动机里那几条教训也不是它内建的。否。

## 影响

### 源码兼容性（source compatibility）

纯新增：1.0.0 是首个版本，`Release.zsh` 的变量、钩子、`app_release_*` 函数和 `APP_RELEASE_*` 环境变量还没有任何既有使用方。

### ABI 兼容性（条件项）

不适用 —— 引擎是 zsh 脚本，没有二进制接口；项目按钉住的版本取源码执行。

### 下游影响

本仓库内没有其他 target。五个项目的发版入口会变（这是各项目发版方式的破坏性变化，随各自的迁移提交落地）：

| 项目 | 现在 | 迁移后 |
|---|---|---|
| XCOrganizer | `Scripts/BuildNotarizedApp.sh --keychain-profile <名字>` | `app-release all`（profile 写进 `Release.zsh`） |
| FinderSidebarIconFix | `./ArchiveScript.sh --version-tag <tag> --upload-to-github` | `app-release all --version-tag <tag> --publish` |
| RuntimeViewer | `./ArchiveScript.sh --version-tag <tag> --update-appcast --upload-to-github --commit-push`，CI 同 | `app-release all --version-tag <tag> --publish`，appcast 的提交在钩子里 |
| LyricsX | CI 依次跑 `Scripts/release/` 下的十几个步骤 | CI 一步 `app-release all --version-tag "$GITHUB_REF_NAME" --publish` |
| StarLight | CI 跑 `scripts/release.sh`，再在 YAML 里 `gh release` | 同上 |

其他需要项目配合的改动：

- **LyricsX**：主 App、Helper、Widget 的 Info.plist 改用 `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`，在 xcconfig 里声明这两个值；appcast 改由 `generate_appcast` 生成。
- **CI 项目**：secrets 不改名，只在 YAML 里映射。
- 引擎升级是各项目里改一行 `release_engine_version` 的显式改动，不会自动波及任何项目。

### 文档与示例

- **引擎仓库**：英文 README（安装、快速开始、CI 片段）；使用指南 `Documentations/Guides/ReleaseConfiguration.md`，写全部变量、钩子、环境变量，以及从签名上看不出来、违反了就会出问题的契约（例如注入 build number 要求 Info.plist 用 `$(CURRENT_PROJECT_VERSION)`）。
- **各项目**：在迁移提交里改掉引用旧脚本的文档——XCOrganizer `CLAUDE.md:132-136`，FinderSidebarIconFix `Documentations/Internal/ReleasePackaging.md` 与 README，StarLight `Documentations/ReleaseCI.md`，RuntimeViewer 里引用 `ArchiveScript.sh` 的文档（迁移时全仓搜索）。LyricsX `docs/superpowers/` 下的发版 spec 与 plan 属于历史记录，不改写。

## API 演进与废弃策略

- **语义化版本**：新增可选变量、可选钩子、新的 `app_release_*` 函数、新的产物类型或发布方式，算 minor；改名或删除变量、钩子、函数，改变某个默认值导致已有项目的产物不同，或改变 manifest 已有字段的含义，算 major。
- **废弃**：旧名至少保留一个 minor 版本，引擎读到时打印警告并映射到新名，下一个 major 删除。
- **manifest**：带 `schemaVersion`；`--from` 只接受同一引擎版本写下的 manifest。
- 每个项目按钉住的版本运行，引擎发新版不影响任何没改钉住版本的项目。

## 落地步骤

1. **引擎骨架**：启动器、`Engine.zsh`、运行目录与 manifest、日志、`--dry-run`、`target` 段。
   验收：示例 App 上 `app-release target` 打出正确的计划；单元测试通过。
   进度：完成，与步骤 2 一起验收。
2. **其余四段（只做 App + zip）**：xcodebuild 入口、归档类型与 `lipo` 检查、导出校验、公证与续等、staple 重试、`spctl` 来源核对、产物名模板、dSYM、`SHA256SUMS`、CI 凭据模式、两种发布方式；README、LICENSE、引擎 CI 一并写好。
   验收：示例 App 走完 `target` 和 `archive`；两个反例都变红。
   进度：完成。`Tests/Run.zsh` 的 45 个命令行测试全部通过；`--integration` 的 3 个测试在本机（Xcode 27.2）真的归档了示例 App，Generic 归档与缺架构两个反例都被拦下。
3. **迁移 XCOrganizer**（本机，第一批）：写 `Release.zsh`，用 `APP_RELEASE_ENGINE_DIRECTORY` 指向引擎工作副本，在本机做真实的签名、公证、staple。
   验收：与 `BuildNotarizedApp.sh` 的产物逐项比对（签名者、entitlements、Info.plist、`spctl` 结果）一致。删除 `BuildNotarizedApp.sh`，更新 `CLAUDE.md`；XCOrganizer 那份 In Progress 的提案改为 Withdrawn 并链接本提案。
   进度：完成，在 XCOrganizer 的 `feature/adopt-app-release` 上，等步骤 4 发布引擎后再合并（它钉的 1.0.0 那时才拉得到）。本机完整跑通一次：通用归档、Developer ID 导出、内嵌辅助程序检查、公证 Accepted、装订、Gatekeeper 认作 Notarized Developer ID、zip 解开复检。旧脚本用 `--skip-notarization` 出了一份对照：主程序签名、entitlements、Info.plist、架构、4 个内嵌代码的签名都相同，文件只多一个装订进去的票据 `Contents/CodeResources`。
4. **发布引擎 1.0.0**：在 GitHub 创建公开仓库 `Mx-Iris/AppRelease`（对外动作，执行前再次确认），推送并确认引擎 CI 通过，打 tag `1.0.0`；两台 Mac 各运行一次 `Install app-release.command`。
   验收：XCOrganizer 钉 `1.0.0`，不设 `APP_RELEASE_ENGINE_DIRECTORY`，再跑一次 `app-release target`。
   进度：完成。公开仓库 https://github.com/Mx-Iris/AppRelease ，引擎 CI（`macos-26-arm64`，默认 Xcode 26.6）48 个测试全部通过，tag `1.0.0` 已推送；两台 Mac 都装好了启动器（Ultra 经 ssh 克隆到同一路径后安装）。XCOrganizer 用装好的启动器、不设本地引擎目录，从 GitHub 拉下 1.0.0 跑通了 `target` 预检；它的功能分支已在本地合进 main，未推送。
5. **迁移 FinderSidebarIconFix**（本机，第二批）：arm64e 切片与 launchd plist 检查放进钩子，`release_publishers=(github-release)`，产物名保持 `FinderSidebarIconFix-macOS.zip`。
   验收同步骤 3；删除 `ArchiveScript.sh`，更新文档。
   进度：完成，在 FinderSidebarIconFix 的 `feature/adopt-app-release` 上，已推送，并在本地快进合进 main，未推送。项目钉 1.1.0：迁移中发现它要 GitHub 自动生成的发布说明，引擎为此加了 `release_notes_fallback`。装好的启动器从 GitHub 拉下 1.1.0 跑通五段：两个钩子通过（daemon 与 payload 带 arm64e，launchd 服务是 Release 版），公证 Accepted，Gatekeeper 认作 Notarized Developer ID，zip 解开复检通过。与旧脚本 2026-10-12 发出的已公证产物比对：文件清单、三个二进制的架构、签名、entitlements、launchd plist 一致，Info.plist 只差工具链字段。
6. **迁移 StarLight**（CI，第三批里最简单的一个）：`release.yml` 换成引擎片段，映射 secrets，产物名保持 `StarLight-{tag}.zip`。
   验收：手动触发、不带 `--publish` 跑通且产物过 `spctl`；下一个正式版本走 `--publish`。删除 `scripts/release.sh`，更新 `Documentations/ReleaseCI.md`。
7. **迁移 RuntimeViewer**（next 分支）：
   - `release_before_archive` 跑 `FetchSourceEditorScript.sh`，用 `app_release_xcodebuild` 归档并导出 Catalyst helper，构建 iOS Simulator 载荷。
   - `release_verify_export` 校验图标、SourceEditor framework、模拟器载荷。
   - `release_after_product` 用 `app_release_add_product --not-notarized` 登记 `RuntimeViewer-iOS-Simulator.zip`。
   - `release_deploy_appcast` 搬入现有的「提交或开 PR」逻辑。
   - `--update-packages`、`--local-deps` 经 `--` 交给钩子；产物名保持 `RuntimeViewer-macOS.zip`。
   验收：手动触发的演练（不发布）通过，生成的 appcast 条目与旧脚本的格式一致。删除 `ArchiveScript.sh`，更新文档。
8. **迁移 LyricsX**：
   - Info.plist 改用 build settings（见「下游影响」）。
   - `release_version_tag_match=base`、`release_build_number_source=semantic-version-encoding`、`release_export_options_path=ExportOptions.plist`。
   - `release_archive_arguments=(-skipMacroValidation -skipPackagePluginValidation OTHER_CODE_SIGN_FLAGS=--timestamp)`。
   - 3 个描述文件经 `APP_RELEASE_PROVISIONING_PROFILE_*_BASE64` 传入；`release_deploy_appcast` 负责 canonical 提交与 Pages 镜像；`release_after_product` 登记 dSYM 压缩包；YAML 里保留 Metal toolchain 那一步。
   验收：同一个版本用新旧两种方式各生成一次 appcast 条目，逐字段比对（`sparkle:version`、`shortVersionString`、`minimumSystemVersion`、channel、length，签名能用公钥验证）；演练通过。删除整个 `Scripts/release/`（含 `update-appcast.py`）。
9. **收尾**：提案改 Implemented 并分配编号，写使用指南，判断术语表。

**收尾时必须判断两件事**（判断结果写进决策日志，不允许沉默跳过）：

- **要不要配套专题文章** —— 有「从 API 签名看不出来的调用方契约」就写使用指南；有「下次维护会踩、
  代码本身看不出来的决策」就写实现说明。写了就登记到头部的「配套文档」。判据见全局 agent 指令
  的「三类文档的分工」。
- **有没有引入新术语** —— 有就同批次登记进术语表（项目级 `Documentations/Glossary.md`，
  跨项目通用的登记到全局术语表）。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-11-05 | Created as Draft | 起因：五个项目各有一套发版脚本，修过的坑彼此不同步（PIF 开关、归档类型检查、钥匙串 `-l`、公证状态判定）。按完整档做了三轮澄清提问，以下决策经用户确认后成稿。 |
| 2026-11-05 | 引擎单独建公开仓库，项目钉确切版本 | 四个 CI 项目是公开仓库，读不到私有仓库或 iCloud 里的 Scripts。否决 submodule（每个 worktree 都要初始化）和每个项目拷一份（回到修复不互通的老样子）。 |
| 2026-11-05 | 本机由启动器按钉住的版本执行 | 本机与 CI 行为一致。否决「装最新版、主版本不符才拒绝」。 |
| 2026-11-05 | 迁移范围：用户名下五个项目，分批 | 顺序为 XCOrganizer → FinderSidebarIconFix → RuntimeViewer、LyricsX、StarLight。LookInside 的仓库属于 Lakr233；脚手架模板以后另提。否决「只迁 XCOrganizer」。 |
| 2026-11-05 | `--publish` 管到 tag、GitHub Release、appcast 生成；上线交给钩子 | 否决「只做到本地产物」（发布逻辑仍各写各的）和「再管版本号递增」（引擎要写仓库）。 |
| 2026-11-05 | 版本号以工程为准，build number 三选一 | 否决「统一以 tag 为准」（Xcode 里直接 Archive 的版本对不上）和「统一以工程为准」（LyricsX 要改成手动递增）。 |
| 2026-11-05 | 五段照 Xcode 的动作命名：`target / archive / export / notary / product`，不设测试关卡 | 推荐过的「build 作为可选测试关卡」被否：发版不多花一次编译，名字与 xcodebuild 的动作一一对应。 |
| 2026-11-05 | CI 凭据由引擎处理，YAML 只剩几行 | 三份建钥匙串的脚本合成一份，顺带修掉 `-lut`。否决 GitHub Action 封装（版本要钉在两处）和「CI 自己管」。 |
| 2026-11-05 | 第一版只做 App + zip | 五个项目都只发 zip；dmg、pkg、命令行工具留分派位置。 |
| 2026-11-05 | 名称定为 AppRelease，命令 `app-release`，配置 `Release.zsh` | 从 MacRelease、ReleasePipeline、AppRelease 三者中选定；已知将来支持命令行工具时名字不够贴切。 |
| 2026-11-05 | Sparkle 统一用 `generate_appcast` | 否决「引擎只签名」。LyricsX 迁移时改用它，并逐字段核对生成的条目。 |
| 2026-11-05 | 各项目的迁移不另写提案 | 迁移提交删除旧脚本、更新本项目文档并链接本提案，在落地步骤里逐项完成。 |
| 2026-11-05 | 引擎 CI 不放证书 | 真实签名与公证在本机迁移 XCOrganizer 时验收。否决在公开仓库的 secrets 里放签名证书，也否决不设 CI。 |
| 2026-11-05 | 影响一节按 library 写 | `Release.zsh` 的变量与钩子被五个仓库依赖，需要 API 演进与废弃策略。 |
| 2026-11-05 | 确认未经提问采用的做法 | 钩子是 `Release.zsh` 里的函数；xcodebuild 统一入口；公证只认 `status`；ssh 会话无 CI 凭据即拒绝；输出根默认 `build/AppRelease`；secrets 不改名；预发布按 tag 后缀判定；要求 macOS 15+；MIT 许可证；本地目录 `Personal/Scripts/AppRelease`。用户确认。 |
| 2026-11-05 | 成稿时按调研补入的设计细节，待审阅 | 都来自对现有脚本的核查：版本号读不到 build setting 时回退到 Info.plist 字面值，并加 `release_version_tag_match=base`（LyricsX）；产物名用模板，保留各项目现有文件名（下载地址依赖它）；默认不覆盖归档的签名设置（LyricsX `build.sh:41-47`）；`release_export_options_path` 与描述文件环境变量（LyricsX）；`product` 段解开 zip 复检。 |
| 2026-11-05 | 用户批准，开始实现 | 状态改为 Accepted，实现放在 `feature/generic-mac-release-engine`。仓库还没有远端，提案只提交在本地；GitHub 仓库按落地步骤 4 另行确认后再建。 |
| 2026-11-05 | 状态改为 In Progress；步骤 1、2 的代码写完，先交审阅 | 按全局规则，自己写的脚本先给用户审阅再运行；审阅前只做了 `zsh -n` 语法检查，测试还没跑。 |
| 2026-11-05 | 增加 `--to <stage>` | 与 `--from` 对称；`--skip-notarization` 即 `--to export`；`target --to <stage>` 只预检到该段。测试与「只验证前几段」都需要它，而且不用证书。 |
| 2026-11-05 | 增加 `release_application_target`、`release_appcast_arguments` | 前者用于 scheme 构建多个 App 的项目；后者让 RuntimeViewer 继续传 `--release-notes-url-prefix`。这个参数的语义没有核实，所以引擎不默认传。 |
| 2026-11-05 | 运行目录用 tag 的版本加 build 命名，例如 `1.9.0-beta.5-10900105` | LyricsX 的工程版本不带后缀，用 tag 的版本才能区分同一版本的几个预发布。 |
| 2026-11-05 | 同一版本再跑 `target` 时，旧运行目录改名为 `.replaced-<时间>` 保留 | 旧目录可能是已经发出去的版本，不能删。 |
| 2026-11-05 | 公证先 `submit --no-wait` 记下 id，再 `wait`，以 `notarytool info` 的 status 为准 | 记下 id 在前，等待被打断也能续等；`wait` 的退出码不作结论。 |
| 2026-11-05 | CI 模式下临时钥匙串在 archive 之前建好 | XCOrganizer、LyricsX 在归档时就用 Developer ID 签名，等到 export 再建就晚了。 |
| 2026-11-05 | 钩子在子 shell 里运行，带 err_exit | 钩子里任何一条命令失败都算钩子失败；代价是钩子改不了引擎的变量，结果经 `app_release_add_product` 或文件传回。 |
| 2026-11-05 | 描述文件同时装进 `~/Library/MobileDevice/Provisioning Profiles` 与 `~/Library/Developer/Xcode/UserData/Provisioning Profiles`，退出时都删 | Xcode 新版读哪一处没有核实，两处都放最稳。 |
| 2026-11-05 | 某段重跑时，manifest 里它之后各段的记录作废；notary 保留 submission id | 否则重新导出后，续等的会是旧 App 的公证。 |
| 2026-11-05 | 归档改动了已跟踪的文件（比如 Package.resolved）时只警告 | 直接失败可能被 Xcode 改写格式之类的无害变化误伤；先观察迁移中的实际情况再定。 |
| 2026-11-05 | `--publish` 时 `release_publishers` 为空则只补打并推送 tag；`sparkle-appcast` 要求同时列 `github-release` | appcast 里的下载地址指向 GitHub Release。 |
| 2026-11-05 | README、LICENSE、引擎 CI 随步骤 2 写 | 文档与代码同批落地；步骤 4 只剩建仓库、推送、打 tag、安装。 |
| 2026-11-05 | 测试只从 `app-release` 命令行驱动；xcodebuild、security、xcrun、gh 用 PATH 上的假工具代替 | 项目怎么用就怎么测，替身只放在系统边界；真 xcodebuild 的归档测试放进 `--integration`。用户确认了这个测试入口。 |
| 2026-11-05 | 步骤 1、2 完成 | 用户审阅后同意运行测试：45 个命令行测试与 3 个集成测试全部通过。 |
| 2026-11-05 | 步骤 3 完成，XCOrganizer 的分支先不合并 | 用户同意在本机真做一次公证。公证配置名用 `notarytool-password`：FinderSidebarIconFix 与 RuntimeViewer 给同一团队用的就是它，`notarytool history` 确认可用。XCOrganizer 的 `Release.zsh` 钉 1.0.0，引擎发布前合进 main 会让那里的 `app-release` 拉不到引擎，所以合并放到步骤 4 之后。 |
| 2026-11-05 | 步骤 4 完成，引擎 1.0.0 发布 | 用户同意建公开仓库并发布。功能分支快进合进 main 后推送；提案仍为 In Progress、不取号，编号等五个项目都迁完、正式收尾时再分配。 |
| 2026-11-05 | 核实：Xcode 26 接受 `-IDEEnableNewPackagePIFBuilder=NO` | 前期调研里这一条原是推测。引擎 CI 的默认 Xcode 是 26.6，集成测试归档通用示例 App 时带着这个参数照常成功；示例没有 package，所以只证明参数本身无害。 |
| 2026-11-05 | 引擎 1.1.0：新增 `release_notes_fallback`，新建 GitHub Release 时显式传 `--title <tag>` | 迁移 FinderSidebarIconFix 时发现它发版用 GitHub 自动生成的说明（`--generate-notes`），RuntimeViewer 在没给说明文件时也这样做，1.0.0 只会给空说明。按 API 演进策略，新增可选变量算 minor；默认值不变，已有行为不受影响。四个项目建 Release 时都把标题设为 tag，引擎照做。 |
| 2026-11-05 | FinderSidebarIconFix 的 launchd plist 检查改为从 plist 本身推出服务名 | 旧脚本把 `Label` 与 build setting `INJECTION_SERVICE_NAME` 逐字比对；钩子在单独续跑某一段时拿不到 build settings。改为检查：`LaunchDaemons/` 下只有一个 plist、文件名就是 `<Label>.plist`、`Label` 不以 `.debug` 结尾、`MachServices` 打开了它、`BundleProgram` 指向的文件存在。当初那道检查要防的「Release 包里装的是 Debug 服务名」仍然拦得住。 |
| 2026-11-05 | FinderSidebarIconFix 的对照改用旧脚本 2026-10-12 发出的已公证产物 | 旧脚本在本机 Xcode 27.2 上归档失败，报 `Unable to resolve module dependency: 'FinderSidebarIconFixDaemonCore'`：新的 package PIF builder 丢掉了本地包的 x86_64，正是引擎在要求 x86_64 时关掉这个 builder 要防的坑。旧脚本上一次真实发布的产物同样公证过，比对的项目不变。 |
| 2026-11-05 | 迁移时 `.worktrees/` 先写进主检出的 `.git/info/exclude`，`.gitignore` 的改动随功能分支提交 | FinderSidebarIconFix 原先没有忽略 `.worktrees/`。直接改主检出的 `.gitignore` 会在 main 上留下未提交的改动；`.git/info/exclude` 只在本机生效、不进提交。后面几个项目遇到同样情况照此办。 |
| 2026-11-06 | 锁屏时分两段跑：先 `--to export`，解锁后 `--from notary` | 锁屏时 `notarytool` 读不到钥匙串里的公证凭据，报 `No Keychain password item found for profile`。`target` 段的公证预检在上传前就拦下了，但报错只说凭据被拒，没提锁屏；补这条提示留到下次改引擎。这次续跑隔了一夜，也验证了跨天续跑。 |
| 2026-11-06 | 步骤 5 完成 | FinderSidebarIconFix 用 GitHub 上的 1.1.0 公证通过、比对一致；功能分支已推送并在本地合进 main，等用户看过再推。 |
