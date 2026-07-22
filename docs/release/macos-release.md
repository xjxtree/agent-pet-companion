# macOS Release Procedure / macOS 发布流程

A public Agent Pet Companion release is one versioned runtime set: macOS App, PetCore, `petcore-cli`, runtime manifest, connector contracts, Skills, schemas, and bundled pets. It is distributable only when the exact universal archive is Developer ID-signed, Apple-notarized, stapled, accepted on a supported Mac, and recorded in the root [CHANGELOG](../../CHANGELOG.md).

公开版本是一个统一的运行时集合，包括 macOS App、PetCore、`petcore-cli`、runtime manifest、连接器契约、Skills、schemas 与内置宠物。只有最终 universal 归档完成 Developer ID 签名、Apple 公证、staple、受支持 Mac 实机验收，并写入根目录 [CHANGELOG](../../CHANGELOG.md) 后，才可以发布。

Development bundles, ad-hoc signatures, unsigned builds, and evidence from another commit or archive are never public release evidence.

开发 bundle、ad-hoc 签名、未签名构建，以及来自其他 commit 或归档的验证结果，都不能作为公开发布证据。

## 1. Freeze version and changelog / 冻结版本与变更记录

Choose a semantic version `X.Y.Z` and positive build number. The Git tag must be `vX.Y.Z`.

Before the release build:

1. confirm every user-visible change is under `[Unreleased]` in [CHANGELOG.md](../../CHANGELOG.md);
2. rename `[Unreleased]` to `[X.Y.Z] - YYYY-MM-DD`;
3. add a new empty `[Unreleased]` section above it;
4. verify no other changelog section or GitHub Release uses the same version;
5. keep validation logs and pending work out of the changelog.

发布前选择语义版本 `X.Y.Z` 和正整数 build，tag 必须为 `vX.Y.Z`；将 CHANGELOG 的 `[Unreleased]` 改为 `[X.Y.Z] - YYYY-MM-DD`，在上方新建空的 `[Unreleased]`，并确认版本唯一。CHANGELOG 只记录用户可见变化，不保存测试日志或待办。

The generated `apc.runtime-manifest.v1` must bind the App version/build/shared build ID, PetCore RPC and component build IDs, SQLite range, event schema, `.petpack` read/write versions, and all connector contracts. See [Runtime and IPC](../architecture/runtime-and-ipc.md).

## 2. Run the source gate / 运行源码门禁

Requirements:

- macOS 14+ and Xcode 16+ with command-line tools;
- Rust 1.96.0 and `aarch64-apple-darwin` plus `x86_64-apple-darwin` targets;
- Python 3 for validators;
- an explicit Developer ID Application identity and `notarytool` keychain profile for distribution.

Run fresh checks for the release commit:

```bash
./script/validate_test_isolation.sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --locked -- -D warnings
cargo test --workspace --locked
(cd apps/macos && swift test)
./script/validate_schema_fixtures.sh
./script/validate_source_syntax.sh
./script/validate_build_scripts_safety.sh
./script/validate_security_boundaries.sh
```

Real connectors, real Codex App Server generation, and visible macOS UI remain explicit acceptance gates. The [validation profiles](../development/validation.md) define what each result can and cannot prove.

真实连接器、真实 Codex App Server 制作与可见 macOS UI 均属于显式验收门禁；每层结果的证明范围以[验证层级](../development/validation.md)为准。

## 3. Build artifacts / 构建产物

### Local development App / 本机开发 App

```bash
./script/build_app_bundle.sh
```

This creates an ad-hoc-signed `dist/AgentPetCompanion.app` for local testing. It is not notarized or distributable.

该命令默认只生成用于本机测试的 ad-hoc 签名 App；它未经公证，不可对外分发。

For informal handoff, request and verify a separate archive explicitly:

如需非正式交接，显式生成并校验独立归档：

```bash
./script/build_app_bundle.sh --archive
```

This additionally creates `dist/AgentPetCompanion-develop.zip`. Use the ZIP as the authoritative handoff artifact when copying through a File Provider-managed folder.

该命令会额外生成 `dist/AgentPetCompanion-develop.zip`；通过 File Provider 管理的目录复制时，应以该 ZIP 作为交接产物。

### Unsigned universal inspection

```bash
./script/build_release.sh --unsigned
```

This builds a universal Release candidate for local inspection. It is not distributable.

### Signed distribution

Set values explicitly in the release shell. Do not commit them or add credential discovery to the scripts.

```bash
export APC_RELEASE_VERSION='X.Y.Z'
export APC_RELEASE_BUILD='1'
export APC_RELEASE_CHANNEL='release'
export APC_CODESIGN_IDENTITY='Developer ID Application: Example Team (TEAMID)'
export APC_NOTARY_PROFILE='agent-pet-companion-notary'
./script/build_release.sh --distribution
```

The script builds universal Rust/Swift Release binaries, signs nested executables and the App with hardened runtime and timestamp, verifies signatures and slices, submits with `notarytool`, staples and validates the ticket, requires `spctl` acceptance, then writes:

- `dist/AgentPetCompanion-macos-universal.zip`
- `dist/AgentPetCompanion-macos-universal.zip.sha256`

Missing signing/notary values or any failed stage must stop the release.

## 4. Accept the exact archive / 验收最终归档

All checks must use the final signed/notarized archive after extracting it into a clean temporary directory.

### Runtime and lifecycle

- Verify `arm64` and `x86_64` slices, signature, notarization, staple, `spctl`, archive hash, and exact runtime-manifest/build identity.
- Exercise upgrade from an older compatible runtime, rejection of an incompatible newer database, candidate failure, and last-known-good rollback.
- Verify single-instance control center behavior, normal close/reopen, Dock/menu **Quit**, App relaunch, PetCore continuity after UI exit, and no duplicate UI host.
- Confirm a newly opened valid bundle can trigger the event-driven handoff; do not test or document a periodic background updater.

### Product UI

- Verify sidebar order: **Pet Library → AI Pet Maker → Pet Configuration → Agent Connections → Service & Diagnostics**.
- Verify Pet Configuration contains only **Appearance & Desktop Pet** and **Messages & Sources**, while diagnostics export remains available only from the root **Service & Diagnostics** page.
- On a clean App home, verify both bundled pets are present and one valid pet is active.
- Verify overlay drag/resize/right-click, first-click session controls, bubble expand/open behavior, and resize-handle hiding when the pointer leaves.
- Verify create, cancel, retry, reply, generation history, import, export, activation, and edit-from-import flows that apply to the release.

Use Computer Use first with Accessibility reads and element actions. Any fallback that can move the pointer, inject input, activate an App, or steal focus requires explicit user approval immediately before use.

### Pet library and package safety

- Validate/render all seven states from both packaged built-in archives.
- In an isolated existing library, verify same ID is preserved, same name with a different ID coexists, repeated seeding is idempotent, and an existing active pet is not replaced.
- Verify bundled pets can be previewed, enabled, and exported, while UI and RPC reject deletion and same-ID modification/import.
- Verify ordinary imported pets remain editable even without an App creation history, and stale-base edits cannot overwrite a newer revision.
- Re-run `.petpack` structure, budget, provenance, visual-difference, and recursive privacy gates against the packaged artifact.

### Connectors and diagnostics

- Verify supported connector install/repair/check/test/uninstall behavior against the current runtime contract without reading credentials.
- Export diagnostics with PetCore healthy and unavailable. Both paths must produce `apc.diagnostics-bundle.v1`, obey the fixed allowlist and retention bounds, and exclude prompts, full messages, tool data, credentials, paths, identifiers, SQLite, pets, jobs, runtime tokens, and connector configuration.

Use [System architecture](../architecture/overview.md), [Data model](../architecture/data-model.md), [Agent connectors](../integrations/agent-connectors.md), and the [`.petpack` specification](../specifications/AgentPetCompanion_Petpack_Whitepaper_V1.md) as the acceptance contract rather than copying those rules into release notes.

## 5. Publish the GitHub Release / 发布 GitHub Release

After the release commit and exact archive pass:

1. create and push tag `vX.Y.Z` for that commit;
2. create one GitHub Release for `vX.Y.Z`;
3. attach the universal ZIP and SHA-256 file;
4. copy the matching changelog section into concise release notes;
5. record the commit, runtime manifest identity, supported macOS baseline, archive hash, notarization request ID, and links to CI/acceptance evidence;
6. verify the Release version, tag, manifest version, and changelog version agree.

发布完成后，每个 GitHub Release、tag 与 CHANGELOG 版本段必须一一对应。不得把用户诊断包、凭据、公证私有日志或包含用户数据的验收产物附加到 Release。
