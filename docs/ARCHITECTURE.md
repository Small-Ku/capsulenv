# Capsulenv architecture

這份文件是 runtime ownership、安全邊界與 relocation semantics 的 canonical specification。使用方式見 [`../README.md`](../README.md)，deployment 見 [`DEPLOYMENT.md`](DEPLOYMENT.md)。

## Core ownership rule

Capsulenv 不再把 Scoop CLI 當成自己的 runtime/package engine，也不 fork 或 monkey-patch Scoop。Package provisioning 與 runtime projection 是兩個獨立層：

```text
Scoop buckets / manifests
          |
          v
Capsulenv package planner
          |
    +-----+------------------+
    |                        |
    v                        v
PortableSafe             non-PortableSafe
Capsulenv executor       explicit upstream Scoop
    |                        |
    +-----------+------------+
                v
       installed runtime state
                |
     ProcessPlan / app resolver
     shims / persist / HostIntegration
```

因此有兩種不同 ownership domain：

- **Capsulenv-owned package**：由 PortableSafe executor 建立在 `packages/`、`package-persist/`、`shims/` 與 `.capsulenv/packages/`。Capsulenv可以完整描述並重建其 projection。
- **Stock Scoop install**：由使用者直接執行 `scoop ...`，或 `capsulenv app install ... --allow-trusted` 顯式委派。Capsulenv 不改變其 lifecycle semantics，只把已有 installed manifest/current/persist 視為 legacy runtime input；host mutation 不屬 PortableSafe guarantee。

不得重新引入 `scoop-capsulenv-*` source adapter、transformed Scoop libexec、`shortcut_folder` override、hook fingerprint sanitizer 或任何 `UseGateway` 類 dispatch switch。

## Trust levels

Trust level 與 ShellOnly/User session mode 正交：

| Level | 能做什麼 | Host persistence |
|---|---|---|
| **Runtime** | launch、process-only environment、runtime resolution | 無 |
| **PortableSafe** | bounded download/hash/extract、capsule files、persist projection、Capsulenv shim | 僅 capsule |
| **HostIntegration** | Capsulenv 明確擁有的 Start Menu/default-browser/SSH integration | 顯式、host-scoped、可備份/還原 |
| **TrustedExecution** | upstream Scoop hooks/installers/arbitrary third-party code | 不承諾可逆 |

`User` 不會把 `TrustedScript` 自動變成 safe；`ShellOnly` 也不會嘗試「安全化」任意 PowerShell。跨越 TrustedExecution boundary 必須是使用者的明確 action。

## Runtime layout

長期 capsule 主要 ownership：

```text
capsulenv.cmd
config/
modules/Capsulenv/
packages/<app>/<version>/
packages/<app>/current
package-persist/<app>/
shims/<alias>.cmd
scoop/
scoop-global/
PowerShell/Modules/
tool-data/
cache/
project-cache/
workspace/
.capsulenv/
```

`packages/`、`package-persist/`、`shims/` 是 PortableSafe package domain。`scoop/` 則承載 stock Scoop core、buckets，以及使用者顯式 TrustedExecution/歷史 install；兩者不可混成一個「Scoop owns everything」模型。`scoop-global/` 只保留 upstream Scoop `-g` 的 compatibility root semantics；它仍位於 capsule 內，不代表 Capsulenv 擁有 machine-global package domain，也不需要在未使用 `-g` 時 materialize。

`.capsulenv/packages/<app>.json` 是 Capsulenv-owned installed state，記錄 package/version/architecture/install root/current root/persist mappings/shims/capabilities。State path 以 capsule-relative reference 儲存，避免 drive relocation 後把舊 absolute path 當 authority。

## Package planner and PortableSafe subset

Planner 在任何 package mutation 前解析 manifest、architecture 與 dependency DAG，並分類：

- `PortableSafe`
- `TrustedScript`
- `ExternalInstaller`
- `Unsupported`

Install plan 只有在**整個 dependency graph** 都是 `PortableSafe` 時才能由 safe executor 執行；否則結果是 `TrustedExecutionRequired`。

第一版 PortableSafe subset 刻意限制在 declarative fields：

```text
url / hash
architecture
extract_dir / extract_to
bin
persist
env_add_path
env_set
shortcuts
depends
```

其語義由 Capsulenv 定義，不是「呼叫 Scoop 相同 helper」：

- `bin` -> Capsulenv-owned relocation-safe shim
- `persist` -> Capsulenv link reconciler
- `env_add_path` / `env_set` -> process environment plan
- `shortcuts` -> launcher-based HostIntegration declaration
- `depends` -> planner DAG

SHA-256、URL scheme、archive type、relative path、alias/shortcut name 都是 bounded validation。第一版 executor 只處理 `http`/`https`/`file`、SHA-256、ZIP 與 plain-file artifact；`extract_dir` 只在 ZIP 上有定義。`env_set` 必須是 JSON object。Shortcut name 可包含 bounded 子目錄，custom icon 也只能落在 package projection 內。

Planner 對 Scoop schema 採 **schema-aware fail-closed**：已知純 metadata 欄位可以忽略，但目前未實作、會改變 install/download/runtime 語義的欄位（例如 `cookie`、`psmodule`）不會被悄悄丟掉；未知 root/selected-architecture property 也不能取得 `PortableSafe`。這讓 upstream manifest format 增加新 active semantics 時，Capsulenv 預設停下來而不是錯把它當 declarative no-op。

`pre_install`、`post_install`、installer/uninstaller script 等 arbitrary code 永遠不是 PortableSafe。Capsulenv 不對 script 做 fingerprint allowlist、rewrite 或 partial sandbox；要執行就進 TrustedExecution。

### Review DAG and trust propagation

Package review 使用和 planner 相同的 resolved dependency closure，但保留兩層 trust 狀態：node 的 `DirectReviewRequired` 只描述該 manifest/ownership boundary，本身安全的 ancestor 若依賴任一 direct blocker，`EffectiveReviewRequired` 仍向 root 傳遞成 `TrustedExecution`。Review contract 同時保留 root-to-blocker path，因此「整個 plan 被擋」不會只剩一個 aggregate boolean；使用者和外部 tooling 都能追到是哪條 dependency chain 引入 trusted lifecycle。

對 upstream Scoop-owned `scoop/<app>` update，review 另外以 installed manifests 建立 old closure，以 current buckets 建立 new closure，然後按 package identity 比較 node/edge 與 execution-relevant effects。Diff 涵蓋 source/version、artifact URL/hash、dependencies、extract/projection、bin/persist、process environment、shortcuts 及 lifecycle semantics。舊 closure 缺少已安裝 dependency evidence 時，review 保留 warning 並把 removed-node/edge 判斷標成 conservative；缺失證據不能被解讀成安全 no-op。

## Provisioning and runtime separation

Runtime consumer 不應關心 package 當初由哪個 CLI 安裝，而是解析 installed app projection。Primary selector namespace 表達 **provider/ownership**，而不是把 Scoop 自己的 root scope 混進同一維度：

```text
capsule/<app>          Provider=Capsulenv, Ownership=PortableSafe
scoop/<app>            Provider=Scoop,     Ownership=Upstream
scoop:user/<app>       Provider=Scoop, ProviderScope=User    # 只作消歧
scoop:global/<app>     Provider=Scoop, ProviderScope=Global  # 只作消歧
```

`user/<app>` / `global/<app>` 保留為 legacy aliases，但 resolver 會 canonicalize 成 `scoop:user/<app>` / `scoop:global/<app>`。不帶 selector namespace 時仍優先 Capsulenv-owned package；若只存在一個 upstream Scoop match，`scoop/<app>` 足夠；只有 user/global 兩個 Scoop roots 同時存在同名 app 才要求 provider-local scope。Browser、Bitwarden、tool resolver、`app run` 和 `app exec` 應使用同一 installed-runtime abstraction，而不是各自 hard-code `scoop/apps/<name>/current`。`app exec` 是 provider-neutral runtime boundary：provider ownership 只影響 process environment projection，不改變 caller-facing execution model。

PortableSafe install 仍會在 version tree 寫出 installed `manifest.json` / `install.json` compatibility metadata，讓現有 runtime manifest parser 可共用，而 `.capsulenv/packages/*.json` 保存 Capsulenv 自己的 ownership/state。State 同時保存 provider/reference、source manifest fingerprint 與 installed metadata fingerprints；runtime 每次讀取都驗證它仍指向同一 capsule-owned version/current/persist roots，metadata 漂移即 fail closed。這是 migration bridge，不代表 Scoop 重新取得 ownership。

## Shims

Capsulenv shims 位於 capsule `shims/`，並在 Capsulenv process PATH 中排在 Scoop shims 前。Shim 不嵌入 app 的 absolute install path，而是呼叫 capsule launcher：

```text
shims/git.cmd
  -> ../capsulenv.cmd app exec capsule/git git -- ...
  -> resolve current installed state
  -> apply package ProcessPlan
  -> execute target
```

因此 `E:\capenv -> F:\capenv` 不需要 `scoop reset *` 才修 Capsulenv-owned shims。Alias collision 必須有 ownership marker；不能覆寫不屬該 package 的 shim。

## Stock Scoop boundary

Capsule 仍 bootstrap upstream Scoop core/Main。PowerShell session 的 PATH 會讓真正的 upstream `apps\scoop\current\bin\scoop.ps1` 排在 Scoop shims 前，因此 `scoop` 直接命中 upstream dispatcher。只有 `cmd.exe` 因 `.ps1` 不在一般 executable extension resolution 中，才保留一個 Capsulenv-owned `scoop.cmd` trampoline；它只用自身 `%~dp0` 找到：

```text
../apps/scoop/current/bin/scoop.ps1
```

並直接執行 upstream dispatcher。Capsulenv 不建立 `scoop.ps1` wrapper；舊版留下且能以 Capsulenv marker 證明 ownership 的 PowerShell shim只在 bootstrap migration cleanup 中刪除。`scoop.cmd` 不能載入 Capsulenv runtime transform/policy，也不能根據 ShellOnly/User 改寫 Scoop semantics。

`capsulenv app install <ref> --allow-trusted` 只做一件顯式 boundary crossing：警告後把 `install <ref>` 原樣交給 canonical upstream Scoop。直接 `scoop ...` 亦相同。這些操作可能建立 Scoop 自己的 shortcuts/environment/registry state，Capsulenv 不宣稱其 host mutation 可由 `restore-user` 完整回滾。

## ShellOnly and User session modes

### ShellOnly

每個新的 standalone invocation 預設 ShellOnly。`CAPSULENV_MODE=User` 只由 explicit User entrypoint/process inheritance 設定；persistent ledger 不能用來自動升格 session。

ShellOnly environment 只寫 process scope，並優先使用 Capsulenv package shims與 configured portable tool paths。它不建立 Capsulenv Start Menu integration，也不因為 package manifest 有 environment/shortcut 欄位而寫 Windows User/Machine state。

### User

`user-shell` / `install-user` 只同步 Capsulenv 自己明確定義的 HostIntegration，例如 package launcher shortcuts、default-browser registration、Bitwarden/SSH integration。Backup/restore authority 位於 `.capsulenv/user-integrations/<machine-user-hash>/`。

User mode不是「允許 Capsulenv 替 Scoop執行 arbitrary lifecycle」的開關。使用者若在 User shell 直接執行 upstream Scoop，那是獨立的 TrustedExecution decision。

## Start Menu HostIntegration

Capsulenv-owned shortcut namespace：

```text
Programs\Capsulenv Apps\<capsule-id-prefix>\PortableSafe\<package>\...
```

每個 `.lnk` 的 TargetPath 是 capsule `capsulenv.cmd`，Arguments 指向 `app run capsule/<package> "<shortcut>"`；shortcut不直接 target `E:\...\packages\...\exe`。Windows `.lnk` 仍保存 launcher absolute path，所以 relocation/User sync 會刪除並重建**整個 capsule-specific namespace**。

Capsulenv 永遠不能 override Scoop `shortcut_folder`，也不能寫入 foreign `Programs\Scoop Apps` namespace。Stock Scoop自行建立的 shortcuts 不屬 Capsulenv HostIntegration ownership。

## Relocation projection repair

Rehydrate 不再把 Scoop reset 當 relocation engine。

PortableSafe package repair可以重建：

- `packages/<app>/current`
- package persist directory/file projection
- Capsulenv shims
- User mode 下的 Capsulenv-owned launcher shortcuts

File persist repair只在 ownership 可證明時替換 projection：reparse/hardlink identity直接接受；若 relocation 將 hardlink copy 成 normal file，只在 source/target SHA-256 相同時重建，內容分歧即 fail closed。

對既有 stock Scoop tree，Capsulenv保留一個**bounded legacy projection adapter**，但它不能載入 `scoop/apps/scoop/current/lib/*.ps1` 或呼叫 Scoop private helper。它只讀 installed `manifest.json` / `install.json`，並修復可證明的 `current` / `persist`：

- valid current -> 只有 target 是 app root 的直接、實體 version directory 才保留
- stale current target 的 version leaf 在本地仍有 matching metadata -> 可修
- 沒有 current evidence但只有一個 metadata-bearing version -> 可修
- app root 外部/reparse version target、多個候選 version、normal `current` directory、diverged persisted file 等 ownership 不足 -> fail closed

最後一種情況要求使用者明確執行 upstream `scoop reset <app>`、reinstall 或 migrate；Capsulenv 不猜 active version。

`capsulenv reset` 是 projection reconcile compatibility command，**不是 `scoop reset`**。舊 automatic lifecycle replay / `capsulenv hooks` 已移除。

## PowerShell control plane and profile isolation

`capsulenv.cmd` 的 maintenance/control path 使用 Windows PowerShell-compatible runtime module；interactive shell 可以使用 capsule package提供的 PowerShell 7。這避免更新/repair `pwsh` package 時 control process 鎖住自己的 portable executable。

ShellOnly 不自動載入 host CurrentUser PowerShell profile。私人 modules透過 capsule `PowerShell/Modules` 和 process `PSModulePath` 投影；`seed powershell` 是一次性 migration，不是 runtime依賴。

## Browser ownership

Browser command 使用 unified installed app selector，從該 app 的 installed manifest/runtime projection 找 executable 和 persist-visible profile。`Browsers` config只描述 Gecko-specific profile path、arguments 與可選 default executable override，不再定義第二份 browser data store。

ShellOnly 不把 capsule request 隨意交給 foreign browser profile；`--host` 只允許同一 configured product 的 host executable 配 capsule profile。User default-browser registration 是 explicit HostIntegration，有精確 registry backup；Windows `UserChoice` hash 不由 Capsulenv偽造。

## Bitwarden SSH ownership

Capsulenv 不複製/重建/重新序列化 Bitwarden vault/app state。Setting patch只修改 source-verified top-level keys，保存 exact previous bytes/value state並在寫入前驗證 JSON。App selector同樣以 `capsule/<app>` / `scoop/<app>` 表達 provider；`scoop:user/` / `scoop:global/` 只在 upstream roots 同名時消歧。

ShellOnly Git/OpenSSH 設定使用 process overlay且不更改 Windows `ssh-agent` service；User integration才可進入明確備份/還原流程。

## Lifecycle routine ownership

Capsulenv does not own sing-box, rclone, backup, network, or other workload semantics. It owns only portable runtime projection plus capsule-local lifecycle events. `Routines` may bind `OnEnter`, `OnExit`, `OnRehydrate`, or `OnEject` to a generic command or to an installed-app `App` + `BinName` ProcessPlan. Successful runs persist their last-success timestamp so `MinimumIntervalSeconds` can suppress redundant work after repeated activation.

Long-lived desired state, retry policy, host boot/logon schedules, network configuration meaning, synchronization direction, and process policy belong above Capsulenv. NyaModule can consume the provider-neutral installed-app execution boundary and use a capsule routine only as a local trigger back into its own control plane. This keeps the portable runtime unaware of the workload it happens to execute.

An activated capsule already exports its current runtime location as process environment: `CAPSULENV_ROOT` is the relocation-correct root and `CAPSULENV_LAUNCHER` identifies the control launcher selected for that session. External orchestration launched from the capsule must consume that inherited session context instead of inventing another capsule locator, scanning drive letters, or requiring a copied identity registry. A fixed `CapsuleRoot` may still be supplied by an external orchestrator when it intentionally runs outside a capsule session.

## Weasel seed ownership

Weasel integration是 explicit seed/restore workflow：只對可確認的 machine-installed Weasel user-data tree做 cold copy，restore 前先建立 host rollback snapshot。它不是 portable package executor的一部分。

## Tool and project storage

Package ownership與 tool cache/project storage是不同 surface。`tool-data/`、`cache/`、`project-cache/`、uv/Pixi workspace repair 的 canonical semantics 見 [`TOOLS.md`](TOOLS.md)。Persisted-text relocation仍使用 bounded allow-list，禁止 recursive rewrite unknown app state。

## Static architecture gates

`Capsulenv.StaticAnalysis.ps1` 對以下 invariant fail closed：

- runtime 不得出現 `module-runtime/scoop-capsulenv-*`
- direct Scoop shim不得 gateway/policy/runtime-transform
- runtime 不得 target `Programs\Scoop Apps`
- 禁止任何 `shortcut_folder` override
- session mode resolver不得依賴 persistent ownership command
- control bootstrap/runtime command boundary保持 WinPS 5.1-compatible

這些 gate需要 synthetic rejecting/accepting fixtures；不能為了 refactor方便降級成沒有 ownership意義的 string smoke test。

# Host identity and depot retention

Capsulenv keeps capsule identity and desired state portable, while resolving a
host-local depot from an independent host record. A host record is keyed by a
stable machine/user integration key and never by the portable root or drive
letter.

Unknown hosts resolve to retention = ephemeral by default. The ephemeral
placement is namespaced by host key, capsule identity, and the current boot
epoch, so a valid realization can be reused during one host lifetime without
making reboot/reimage persistence part of correctness. No shutdown cleanup hook
is required.

Persistent placement requires an explicit host enrollment/tag such as home. An
enrolled host may provide a stable local depot root, including a custom local
volume. Portable state is not copied into this depot merely to simplify
cleanup, and a stale host-local record never overrides portable desired state.

The host placement foundation only resolves and materializes layout. Program
resolution, immutable generations, activation, and integration ownership remain
separate boundaries implemented by the downstream architecture issues.

Host identity uses layered evidence. When available, the Windows GDID value at
`HKCU\\SOFTWARE\\Microsoft\\IdentityCRL\\ExtendedProperties\\LID` is a
strong host-installation signal; the machine/user tuple remains a fallback and
co-factor. Capsulenv stores only the derived host digest in placement keys, and
never copies raw GDID into portable state. GDID presence does not infer home or
enable persistent retention; explicit enrollment remains authoritative.

Host JSON publication is fail-closed when replacement is unsupported, retaining
the previous valid record. An invalid or unmarked ephemeral placement is stale
material and is moved aside before rematerialization; an invalid persistent
placement reports a diagnostic instead of being silently adopted.
# Session ledger and portable-state leases

Process ownership is recorded in a host-local session ledger. Each record
contains the session ID, PID, process-start identity, a nonce, role, provider
provenance, ownership classification, and held leases. Only an exact live
record marked owned is actionable; attached and foreign processes are never
stopped by Capsulenv. A reused PID with a different start identity is stale
residue.

The exported registration boundary can create only attached or foreign
records. Owned records are created only by the internal launch-boundary path
with an already captured process-start identity, so an arbitrary live PID
cannot be promoted by a general registration call. Ledger mutations use an
OS-held ledger lock before read-modify-write publication, and a failed lease
bookkeeping step releases its already acquired OS handle before rethrowing.

Portable mutable state declares one of three policies: exclusive, shared-read,
or unmanaged. Exclusive and shared-read acquisitions hold an OS file handle
for the lifetime of the lease, so a crash releases the lock when the process
dies. The ledger is diagnostic metadata; lock-file existence is never used as
authority. Gecko profiles and other single-writer state should use exclusive
leases, while unmanaged state is intentionally outside Capsulenv ownership.
