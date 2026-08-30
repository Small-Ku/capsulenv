# capsulenv

`capsulenv` 是一個可隨 USB／portable disk 搬移的 Windows 開發環境啟動層。它管理 process environment、portable package projection、常用 package manager 的 cache/tool state、私人 PowerShell modules 與 workspace，並在 drive letter、電腦或 Windows user 改變後修復 Capsulenv 能證明 ownership 的連結與 host integration。

Scoop 仍然存在，但角色已拆開：**Scoop buckets/manifests 是 package metadata ecosystem，stock Scoop CLI 是顯式的 TrustedExecution fallback；Capsulenv runtime 不再 monkey-patch、rewrite 或攔截 Scoop。** 預設 **ShellOnly** 只影響 Capsulenv 開出的 process tree；需要在臨時／洗機電腦上同步可還原的 current-user integration 時，才使用 **User**。

## 快速開始

把 release bundle 解壓到任意暫存目錄，再從 bundle 內安裝到 portable drive：

```bat
install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd
```

進入 Capsulenv 開出的 PowerShell 後，直接用 `capsulenv` 即可；它會綁定目前 active capsule 的 exact launcher，所以不需要 full path，也不會因 PATH 中有另一份 Capsulenv 而跑錯：

```powershell
capsulenv status
capsulenv app list
capsulenv help app
```

Source checkout 刻意不在 repository root 放 `capsulenv.cmd`／`install.cmd`，避免把開發樹誤認成已安裝 capsule。從 source 安裝請用 `scripts\install.cmd <destination>`；只有 release bundle 才在根目錄提供 `install.cmd`，而工作中的 capsule 根目錄只提供 `capsulenv.cmd`。Installer 完成後直接執行 destination 的 `capsulenv.cmd` 即可；不需要先跑 `doctor` 或 `init`。

第一次啟動若 capsule 還沒有 Scoop core／Main，Capsulenv 會 bootstrap **未修改的 upstream Scoop 與 Main bucket**，供 manifest resolution、bucket 管理和必要的 explicit fallback 使用。安全的日常 package path 是先看 plan，再安裝：

```powershell
capsulenv.cmd app plan git
capsulenv.cmd app install git
```

Planner 只接受刻意很小的 declarative subset，例如 `url/hash`、`architecture`、`extract_dir/extract_to`、`bin`、`persist`、`env_add_path`、`env_set`、`shortcuts`、`depends`。第一版 executor 只支援 `http/https/file`、SHA-256、ZIP/plain-file artifact；`cookie`、`psmodule`、未知 active manifest property 等未實作 semantics 會 fail closed，而不是被忽略後誤判為 safe。若 dependency graph 全部可表示為 `PortableSafe`，Capsulenv 自己 download／verify／extract，並建立 capsule-owned `packages/`、`package-persist/`、`shims/` 與 installed state；manifest environment 只在 process runtime 套用。

帶 `pre_install`／`post_install`／installer script 或其他 Capsulenv 不承諾安全語義的 package 會在 mutation 前被分類並停止。審核後若確實要接受 upstream semantics，可明示：

```powershell
capsulenv.cmd app install some-app --allow-trusted
```

或直接使用：

```powershell
scoop install some-app
```

兩者都會使用**未修改的 upstream Scoop**。這是顯式 TrustedExecution boundary：第三方 script、installer、registry/environment/shortcut 等 host mutation 由 Scoop/package 自己負責，**不屬於 PortableSafe 或 Capsulenv 的可逆性承諾**。因此不要再把 `scoop ...` 理解成「Scoop 語法、Capsulenv 語義」。

搬到另一個 drive letter 或另一台電腦時不用重裝；直接在新位置執行 `capsulenv.cmd`，activation 會按需要 rehydrate Capsulenv-owned package projection，以及能從既有 metadata 證明 active version/ownership 的 legacy Scoop `current`／`persist` projection。證據不足時 fail closed，而不是載入或覆寫 Scoop internals 猜測狀態。

日常入口：

```bat
capsulenv.cmd
capsulenv.cmd run git status
capsulenv.cmd status
capsulenv.cmd version
capsulenv.cmd help app
```

`status` 把 session mode、persistent User integration、PortableSafe package 數量、legacy/upstream Scoop app 數量與 relocation/tool 狀態分開顯示；深入檢查使用 `doctor`。

## ShellOnly 與 User

| 模式 | 適合情境 | 對 Windows user 的影響 |
|---|---|---|
| **ShellOnly**（預設） | 私人 Laptop、已有自己環境的電腦 | package/tool vars 與 PATH 只存在 Capsulenv process tree；不建立 Capsulenv Start Menu integration |
| **User** | 一段時間內獨佔、重開機會洗掉狀態的共用電腦 | 同步 Capsulenv 明確擁有、可備份/還原的 current-user integration |

每個新的 standalone `capsulenv.cmd`／`shell` invocation 都先以 ShellOnly 開始。只有顯式 `user-shell`／`install-user`，或由 `user-shell` 開出的 process tree，才使用 User session semantics；host-scoped ledger 是 restore authority，不會把下一個 session 靜默升格。

```bat
capsulenv.cmd user-shell
capsulenv.cmd restore-user
```

User mode 不改變 package trust level。PortableSafe package 的 Start Menu shortcut 會建立在 capsule-specific `Programs\Capsulenv Apps\<capsule-id-prefix>\PortableSafe\...`，而且 `.lnk` 指向 `capsulenv.cmd app run capsule/<app> ...`，不直接綁定某個 drive letter 下的 app executable；relocation 時只重建這個 Capsulenv-owned namespace。直接執行 upstream `scoop` 所建立的 host integration 仍屬 upstream Scoop/TrustedExecution，Capsulenv 不攔截也不宣稱可還原。

`eject` 會收尾 capsule-owned process、檢查 `workspace/` 第一層 Git repository 是否 dirty 並清理 host-local scratch；它不等於 `restore-user`。需要撤銷 Capsulenv 自己的 User integration 時再執行 `restore-user`。

User mode 也可以把 capsule 內指定的 Gecko browser 註冊成 Windows default-app candidate，例如：

```powershell
UserIntegration = @{
    DefaultBrowser = 'librewolf'
}
```

這裡是 installed runtime app selector。Capsulenv-owned package 可寫 `capsule/librewolf`；upstream Scoop install 可寫 `user/firefox` 或 `global/librewolf`。`Browsers` 只補 Gecko-specific profile path／launch argument。Default-browser registration 是 Capsulenv 明確擁有的 HostIntegration；現代 Windows 仍要求使用者在 Settings 確認 `http/https` 的最後 `UserChoice`，Capsulenv 不偽造 association hash。

## 安裝與啟動 app

查看 package trust/capability plan：

```bat
capsulenv.cmd app plan <app>
capsulenv.cmd app plan <bucket>/<app>
```

安全安裝與顯式 trusted fallback：

```bat
capsulenv.cmd app install <app>
capsulenv.cmd app install <app> --allow-trusted
```

有 `bin` 的 PortableSafe app 會收到 Capsulenv-owned relocation-safe shim；manifest shortcut 支援 bounded 子目錄與 package-local custom icon，實際啟動仍統一經 launcher：

```bat
capsulenv.cmd app list
capsulenv.cmd app run <app>
capsulenv.cmd app run capsule/<app> "<shortcut name>"
capsulenv.cmd app run user/<app> "<shortcut name>"
capsulenv.cmd app run global/<app> "<shortcut name>"
```

Runtime selector 與 provisioning history 解耦：`capsule/` 表示 Capsulenv-owned PortableSafe package，`user/`／`global/` 表示 stock Scoop roots；不帶 scope 時若有同名 PortableSafe package會優先選它，legacy user/global 同名則要求明確 scope。

Gecko browser 使用同一套 selector：

```bat
capsulenv.cmd browser firefox
capsulenv.cmd browser capsule/librewolf
capsulenv.cmd browser global/librewolf
```

`firefox`、`zen`、`librewolf` 三個短命令仍是 compatibility aliases。Browser integration 從該 installed app 的 manifest/runtime projection 找 executable 與 persisted profile；`--host` 只借用同一 browser product 的 machine executable，不會跨 product 猜測。

## 從日用機一次性匯入

`seed` 是一次性 migration，不是持續同步：

```bat
capsulenv.cmd seed powershell
capsulenv.cmd seed git
capsulenv.cmd seed scoop
capsulenv.cmd seed weasel
```

`seed powershell` 匯入目前 user 的 PowerShell 7 profiles；capsule 內須已有可解析的 `pwsh` app。`seed git` 匯入 host global Git config，預設排除 credential／HTTP header。`seed scoop` 保存 foreign Scoop apps+buckets inventory；`seed weasel` 對正式 machine-installed 小狼毫做 bounded cold backup/restore。

```bat
capsulenv.cmd seed scoop --apply
```

ShellOnly snapshot migration 仍不執行 foreign manifest lifecycle：它複製已有 app/version/persist/bucket state，再用 Capsulenv 的 bounded projection reconciler 修復可證明的 `current`／persist links。若來源檔案已不可讀或 active version 無法證明，會 fail closed。User mode 的 `--apply` 則明確使用 stock Scoop import，因為這本身就是 TrustedExecution；它直接使用 upstream semantics。

## PowerShell 私人 modules

預設私人 module root 是：

```text
PowerShell\Modules\
```

Capsulenv shell 會把它 prepend 到 `PSModulePath`，並把第一個 configured module root 暴露為 `CAPSULENV_MODULE_ROOT`。私人 module repository 可優先使用該變數，而不必寫入 `%USERPROFILE%\Documents\PowerShell\Modules`。Interactive PowerShell 可由 package 提供；Capsulenv maintenance/control plane 仍與工作 shell 分離，避免更新 package 時鎖住自身 executable。

## Portable storage

| 路徑 | 用途 | 建議 |
|---|---|---|
| `packages/` | Capsulenv-owned PortableSafe version trees | portable runtime；不要當 cache 清除 |
| `package-persist/` | PortableSafe persisted app data | **需要保存** |
| `shims/` | Capsulenv-owned relocation-safe package shims | 可由 installed state 重建 |
| `scoop/`, `scoop-global/` | stock Scoop core/buckets、TrustedExecution/legacy installs | portable runtime/data；不屬 PortableSafe ownership |
| `PowerShell/Modules/` | 私人 PowerShell modules | user data |
| `tool-data/` | Git config、toolchains、global tools、package-manager persistent state | **需要保存**；可能含 token/credential |
| `cache/` | package/tool/compiler reusable caches | 原則上可重建 |
| `project-cache/` | 明確登記的 project build/cache backing store | 由 `cache link` 管理 |
| `workspace/` | portable source repositories | user data |
| `.capsulenv/` | identity、installed package state、relocation/link/User backup | ownership 證據；不要手動當 cache 刪除 |

建立／查看 portable tool storage：

```bat
capsulenv.cmd cache init
capsulenv.cmd cache paths
```

uv／Pixi workspace 與 project cache 的完整 storage semantics 見 [`docs/TOOLS.md`](docs/TOOLS.md)。

## Relocation、offline 與 repair

正常搬移後直接開 shell即可；要明確執行完整修復：

```bat
capsulenv.cmd rehydrate
```

Rehydrate 的 package 部分只做兩種事：重建 Capsulenv-owned `current`／persist／shim/shortcut projection；以及對既有 stock Scoop tree 做 bounded legacy `current`／persist repair。它**不載入 Scoop `lib/*.ps1`、不 override Scoop helper、不 replay manifest hook、不建立 temporary transformed command**。Legacy active version 只接受 app root 內可證明的實體 version directory；外部 reparse target、多個 candidate version 等情況會 fail closed，要求你明確執行 upstream `scoop reset <app>` 或重新安裝/遷移，而不是猜。

```bat
capsulenv.cmd reset
capsulenv.cmd reset capsule/<app>
capsulenv.cmd reset user/<app>
```

這裡的 `capsulenv reset` 是 projection reconcile，**不是 `scoop reset`**。舊的 `capsulenv hooks` 已移除；任意 lifecycle execution 只能經使用者明確選擇的 upstream Scoop。

檢查 offline/readiness 或 local bucket drift：

```bat
capsulenv.cmd offline status
capsulenv.cmd offline prefetch
capsulenv.cmd drift
```

更精確的 trust、provisioning/runtime 與 relocation ownership boundary 見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## Bitwarden SSH Agent

Capsulenv 可把已安裝的 Bitwarden Desktop SSH Agent 設定接到目前模式：

```bat
capsulenv.cmd bitwarden setup
capsulenv.cmd bitwarden status
capsulenv.cmd bitwarden agent-test
```

ShellOnly 只使用 process-only Git SSH 設定且不改 Windows `ssh-agent` service；User mode 可在有明確權限時建立可還原的 user/global integration。還原 Capsulenv 自己改過的部分：

```bat
capsulenv.cmd bitwarden restore
```

Capsulenv 不複製、重建或重新序列化 Bitwarden vault/app state；`Bitwarden.App` 可指向任何相容的 installed runtime app selector（`capsule/`、`user/`、`global/`）；executable 與 state path 由該 app 的 installed manifest/persist projection 決定。更精確的 safety contract 見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## sing-box 私有網絡

若 capsule 已安裝 sing-box 並在它自己的 persist store 放好非空設定，Capsulenv 可檢查並啟動該 instance：

```bat
capsulenv.cmd sing-box status
capsulenv.cmd sing-box check
capsulenv.cmd sing-box connect
capsulenv.cmd sing-box disconnect --force
```

預設 `SingBox.App = 'sing-box'`、`ConfigPath = 'config.json'` 且 `AutoConnect = $true`；未安裝或 persisted config 為空時 activation 只略過，不會下載、生成或猜測 VPN/Tailscale 設定。自訂 bucket／改名 manifest 可把 `SingBox.App` 改成對應 selector，必要時再指定 `BinName`／`ExecutablePath`。

## 更新與移除

下載／建立新版 release bundle 後，**從新版 bundle** 對同一個 destination 再執行 installer：

```bat
X:\capsulenv-release\install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd version
```

Installer 只替換 release manifest 的 destination `InstallFiles`：portable launcher、config/bin helpers 與預先 merge 的 `modules\Capsulenv`；`packages/`、`package-persist/`、`shims/`、`scoop/`、`tool-data/`、`cache/`、`workspace/`、`PowerShell/Modules/`、`.capsulenv/`、local config 與其他 unmanaged files 會保留，mutation 失敗時會回滾。Installer/README/docs 與 bundle metadata 留在 staging bundle，不會安裝到 capsule。**Source patch / Git commit 也不是 deployed runtime update**：要讓 source 修正進入既有 `F:\capenv`，從 development checkout 或新版 release bundle 對它重新 deploy generated module/runtime payload 即可。

Capsulenv 是 portable directory，沒有另外的 machine-wide uninstaller。要永久移除一支 capsule：先在仍使用 User mode 的 host 上執行 `restore-user`，再 `eject`；確認不再需要 USB 內的 `workspace/`、`tool-data/`、Scoop `persist` 等 user data 後，刪除整個 capsule directory。若只想移除 runtime、保留資料供之後重裝，直接保留目錄並用新版 bundle 對同一 destination 安裝即可。

## 設定

預設設定在 `config\capsulenv.psd1`。不要直接把個人差異寫進預設檔；先建立 git-ignored local config：

```powershell
Copy-Item config\capsulenv.local.psd1.example config\capsulenv.local.psd1
```

常見可調項包括 Scoop roots/bootstrap、PowerShell module roots、tool-storage variables、project-link profiles、browser/Bitwarden 行為，以及 relocation allow-list。範例與註解以 `config\capsulenv.local.psd1.example` 為準。

## 診斷與文件

遇到問題先執行：

```bat
capsulenv.cmd doctor
capsulenv.cmd help
```

更深入的文件按用途分開，避免 README 同時變成開發者規格：

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)：ownership、mode、Scoop/PowerShell/Bitwarden/relocation 的內部設計與安全邊界。
- [`docs/TOOLS.md`](docs/TOOLS.md)：tool-data/cache/project-cache、uv/Pixi workspace repair、seed 與 offline storage semantics。
- [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md)：runtime build、installer/update 與 deployment contract。
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)：source layout、module build、測試與 contributor workflow。
- [`docs/MIGRATION.md`](docs/MIGRATION.md)：舊 portable-scoop/capsulenv 版本升級到目前 ownership model 的必要步驟。
