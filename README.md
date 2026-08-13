# capsulenv

`capsulenv` 是一個可搬移的 Windows Scoop 啟動與修復層。它不自行建立另一套 `data/`、Bitwarden app-data、Firefox profile 或 Zen profile；資料所有權仍交回 Scoop manifest 的 `persist`、`pre_install` 與 `post_install`。搬移後，capsulenv 只會對明確 allow-list 中的 Scoop-persisted UTF text 設定做舊 root → 新 root 修復。

開發 checkout 會由 `Merge-ModuleScripts.ps1` deterministic merge `src/*.ps1`；安裝版則直接載入預先生成的 `modules\Capsulenv`。`shell` 會開啟繼承 portable Scoop environment 的子 PowerShell。

## 所有權模型

```text
capsulenv/
├─ capsulenv.cmd
├─ src/                              capsulenv orchestration only
├─ scripts/scoop-capsulenv-replay.ps1
├─ config/
├─ modules/Capsulenv/                installed/prebuilt merged module
├─ PowerShell/Modules/                private/user modules on PSModulePath
├─ cache/                            portable reusable caches
│  └─ scoop/                         Scoop download cache
├─ tool-data/                        toolchains and global tool state
├─ project-cache/                    linked per-project build caches
├─ workspace/                        recommended portable source workspace
├─ scoop/                            complete portable Scoop root
│  ├─ apps/
│  ├─ buckets/
│  ├─ persist/                       manifest-declared persisted app data/profiles
│  ├─ shims/
│  └─ config.json                     portable Scoop config boundary
├─ scoop-global/                     optional Scoop-owned global root
├─ .capsulenv/                       relocation state, link registry, reversible backups
├─ .build/                           development-only generated module
└─ .capsulenv-runtime.json           installed runtime metadata
```

capsulenv 同時設定 `SCOOP` 與 `SCOOP_GLOBAL`，避免 `reset *` 意外枚舉主機的 `%ProgramData%\scoop`。兩個 root 都仍由 Scoop 本體管理。`scoop\config.json` 會在第一次載入 Scoop core 前建立，強制 Scoop 使用 capsule-local portable config，而不是 `%USERPROFILE%\.config\scoop\config.json`。

## Portable PowerShell modules

Capsulenv 預設建立 `PowerShell/Modules/`，在 session 中 prepend 到 `PSModulePath`，並把第一個 module root 暴露為 `CAPSULENV_MODULE_ROOT`。這個目錄是 mutable user data，不屬於 capsulenv installer 的 managed runtime files，因此更新 capsulenv 不會刪除其中的私人 modules。

可在 `config/capsulenv.local.psd1` 改成其他位置；相對路徑會從 capsule root 解析：

```powershell
@{
    Environment = @{
        ModulePath = @('PowerShell\Modules')
    }
}
```

私人 module build script 建議接受明確的 `-InstallRoot`，其次使用 `$env:CAPSULENV_MODULE_ROOT`，最後才回退到 Documents 的 PowerShell module folders。如此在 capsulenv shell 內可直接：

```powershell
.\Merge-ModuleScripts.ps1 -Install
Import-Module NyaModule
```

而不會把 module 同時複製到 `%USERPROFILE%\Documents\PowerShell\Modules`。`PSModulePath` 只在 capsulenv session 中 prepend，不會由 `enable-user` 持久覆寫；這可保留 PowerShell 5.1／7 各自在啟動時建立 default module paths 的原生語意。`CAPSULENV_MODULE_ROOT` 本身仍可隨 `install-user`（舊名 `enable-user`）備份／還原。

PowerShell executable 與 `$PSHOME` profile 仍由 Scoop package ownership 管理。Scoop `pwsh` 的 persisted `profile.ps1`、`Microsoft.PowerShell_profile.ps1`、`Microsoft.VSCode_profile.ps1` 不會另複製到 Capsulenv-specific profile tree。ShellOnly child shell 以 `-NoProfile` 啟動，然後只明確 dot-source capsule-owned `$PSHOME\profile.ps1` 與 `$PSHOME\Microsoft.PowerShell_profile.ps1`；host CurrentUser profiles 因而不會在 isolation 完成後重新污染 session。若 bootstrap 只能使用 host PowerShell/pwsh，ShellOnly 不會把該 host executable 的 `$PSHOME` profile 當成 capsule profile。User mode則保留 PowerShell 正常 profile chain，符合 convenience-first ownership。兩個 mode 都會把 PSReadLine history 指向 `tool-data\powershell\PSReadLine\ConsoleHost_history.txt`。

## Portable tool storage

工具儲存現在分成三種 ownership class，而不是把所有內容都當 cache：

```text
cache/                              rebuildable shared caches
├─ uv/                              uv package cache
├─ uv-python/                       uv managed-Python archive cache
├─ pixi/                            Pixi package/repodata/http/uv cache
├─ npm/
├─ pnpm/                            pnpm metadata/dlx cache
├─ pnpm-store/                      pnpm content-addressable store
├─ bun/
├─ go-build/
├─ go-mod/
├─ ccache/
└─ sccache/

tool-data/                          persistent tool state/global installs
├─ git/config                      portable Git global config
├─ powershell/PSReadLine/           portable PowerShell mutable history/state
├─ uv/python/                       installed managed Python runtimes
├─ uv/tools/                        uv global tools
├─ uv/uv.toml                       uv user config
├─ pixi/                            PIXI_HOME/global installs
├─ npm/                             npm global prefix
│  └─ npmrc                         npm/pnpm user config
├─ pnpm/                            pnpm home/global packages/bin
├─ pnpm-state/                      pnpm state/update metadata
├─ bun/global/                      Bun global packages
├─ bun/bin/                         Bun global package executables
├─ go/gopath/                       Go workspace state
├─ go/bin/                          go install binaries
├─ go/env                           GOENV configuration file
├─ rustup/                          rustup toolchains/state
├─ cargo/                           Cargo home: bins + registry/git cache + credentials/config
├─ ccache/ccache.conf               persistent ccache config
└─ sccache/config.toml              persistent sccache config
```

預設 environment mapping：

| Tool | Rebuildable cache/store | Persistent capsule state |
|---|---|---|
| Git | — | `GIT_CONFIG_GLOBAL` → `tool-data/git/config` |
| PowerShell | — | PSReadLine history → `tool-data/powershell/PSReadLine/ConsoleHost_history.txt` |
| uv | `UV_CACHE_DIR`, `UV_PYTHON_CACHE_DIR` | managed Python、global tools、`UV_CONFIG_FILE`、共同 `bin/` |
| Pixi | `PIXI_CACHE_DIR` | `PIXI_HOME` |
| npm | `NPM_CONFIG_CACHE` | `NPM_CONFIG_PREFIX`, `NPM_CONFIG_USERCONFIG` |
| pnpm | `PNPM_CONFIG_STORE_DIR`, `PNPM_CONFIG_CACHE_DIR` | `PNPM_HOME`, state/global/global-bin dirs |
| Bun | `BUN_INSTALL_CACHE_DIR` | `BUN_INSTALL_GLOBAL_DIR`, `BUN_INSTALL_BIN` |
| Go | `GOCACHE`, `GOMODCACHE` | `GOPATH`, `GOBIN`, `GOENV` |
| Rust/Cargo | project `target/` 另行處理 | `RUSTUP_HOME`, `CARGO_HOME` |
| ccache | `CCACHE_DIR`, `CCACHE_TEMPDIR` | `CCACHE_CONFIGPATH` |
| sccache | `SCCACHE_DIR` | `SCCACHE_CONF` |

`PathVariables` 只代表 directory-valued environment variables；`FileVariables` 專門代表 `GIT_CONFIG_GLOBAL`、`UV_CONFIG_FILE`、`PIXI_CONFIG_FILE`、`NPM_CONFIG_USERCONFIG`、`CAPSULENV_PSREADLINE_HISTORY`、`GOENV`、`CCACHE_CONFIGPATH`、`SCCACHE_CONF` 這類 file-valued setting。`cache init` 會建立 directory、file parent 以及缺少的空 config file，不會把 config filename 誤建立成 directory。Git/uv/npm 的 user/global config 因而跟 USB 搬移；ccache/sccache 的 config 亦特別移出 `cache/`，所以刪除 compiler cache 不會同時丟掉持久設定，也不會因 cache 被重建而退回 host user config。

`cache/` 原則上是可重建資料，但並不代表任何時候都應直接 `rmdir /s`：Capsulenv 不會預設開啟 Bun global virtual store、pnpm experimental global virtual store，也不會強制 uv symlink cache mode；若 local config 主動開啟會讓 project environment 對 shared store/cache 形成更強 linkage，清理時應使用相應 tool-native command。Capsulenv 因而暫不提供一個粗暴的 `cache clean all`。

`tool-data/` 不可當 cache 清除。尤其 `CARGO_HOME` 同時放置 Cargo executable、registry/git cache、config/credentials，Rust/Cargo 沒有一個等價的官方單一變數可以把其中所有「cache」安全拆到 `cache/`，因此仍視為 mixed persistent state。Capsulenv 也不設定全域 `CARGO_TARGET_DIR`；每個專案的 `target/` 繼續透過 `cargo-target` project-link profile 選擇性搬入 `project-cache/`。

同理，Capsulenv 不會把 `node_modules`、`.venv`、`.pixi` 或 Go temporary build scratch 集中成一份共享 project directory。uv/pnpm/Pixi 的 cache/store 依賴 hardlink/reflink 等機制取得最佳性能；若 capsule 在 `F:`、project 在 `D:`，工具可能退化成 copy。需要最大化 dedup/performance 時，建議把 source 放在 capsule 的 `workspace/` 或同一 filesystem；外部 project 則優先維持 correctness/isolation。

Go 有一個刻意保留的例外：`go env GOTELEMETRYDIR` 是 Go 自己計算的 non-settable telemetry state location，直接設定同名 environment variable 不會重定向它。Capsulenv 不會為了這一項而覆寫整個 `%APPDATA%`/XDG user-config root，因為那會把大量無關 child process 一起改道。因此 Go build/module cache、`GOENV`、`GOPATH/GOBIN` 已 capsule-owned，但 Go telemetry 仍是 host-owned known exception；這比宣稱已 portable、實際仍寫 host profile 更誠實。

ShellOnly 只把上述 environment mapping 放進 Capsulenv process tree；User mode才持久寫到目前 Windows user environment，並由 host-scoped backup/restore contract 管理。一般 `git config --global`、uv user config 與 npm/pnpm 共用的 user config 會寫入 USB-owned file；因此若 `npmrc` 內包含 registry token，它也會跟 capsule 一起攜帶，應按 secret 處理。Bun 的一般 `bunfig.toml` 暫不另造 Capsulenv abstraction。Scoop download cache 則透過 `SCOOP_CACHE` 明確放在頂層 `cache/scoop`，與其他可重用 cache 一起搬移。

Capsulenv 另提供 `CAPSULENV_SCRATCH`，位置為 host `%TEMP%\capsulenv\<capsule-id>`（非 Windows test host 則使用該平台 temporary directory）。它只供 Capsulenv/scripts 放真正 transient、高寫入的工作資料；Capsulenv 不改寫 `TEMP`/`TMP`。`eject` 會嘗試清掉這個 scratch。

## 從日用機一次性 seed

`seed` 是明確的一次性匯入，不是 Laptop/USB 的持續同步。成功 seed 後，USB 上既有的 Scoop persist／`tool-data/` state 成為 source of truth：

```bat
capsulenv.cmd seed powershell
capsulenv.cmd seed git
capsulenv.cmd seed scoop
```

`seed powershell` 把 host 的 `CurrentUserAllHosts` 與 `CurrentUserCurrentHost` profile 原樣複製到 capsule Scoop `pwsh` 的 persisted `profile.ps1` 與 `Microsoft.PowerShell_profile.ps1`。Manifest 建立但仍為空的 destination 可直接 seed；已有內容則要求 `--force`。Capsulenv 不嘗試 regex rewrite profile 內的 absolute path、host-only module import 或 secret，seed 後應自行檢視。私人 module 本體仍應部署到 `PowerShell/Modules/`，而不是盲目複製 host 整個 module search path。

`seed git` 讀取真正的 host global Git config（暫時排除 Capsulenv `GIT_CONFIG_*` overlay），以 Git 自己的 parser 展開 includes，再寫成獨立的 `tool-data/git/config`。`include.*` / `includeIf.*` 不會重新寫入；`core.sshCommand` 與 `gpg.ssh.program` 留給 Capsulenv SSH ownership。`credential.*` 與 `http.*.extraHeader` 預設亦不匯入，只有明確 `--include-sensitive` 才保留後兩類。已有 portable Git config 時要求 `--force`。

`seed scoop` 使用 foreign host Scoop 的 native `export` 取得 inventory，但只保存 `apps` 與 `buckets` 到 `tool-data/scoop/Scoopfile.json`，不搬 host Scoop config。預設只 capture；`seed scoop --apply` 才用 capsule Scoop native `import` 套用，而且只允許 User mode，因 package install/import 可能產生 shortcuts、environment entries 及其他 user integration。洗機共用電腦若沒有 foreign host Scoop，也可直接 `--apply` USB 上之前保存的 inventory。

建立及查看 capsulenv-owned storage 位置：

```bat
capsulenv.cmd cache init
capsulenv.cmd cache paths
```

將 Rust 專案現有 `target/` 搬入 capsule，並在原位置建立 directory junction：

```bat
capsulenv.cmd cache link cargo-target D:\src\project --move
```

查看或解除：

```bat
capsulenv.cmd cache status D:\src\project
capsulenv.cmd cache unlink cargo-target D:\src\project
capsulenv.cmd cache unlink cargo-target D:\src\project --restore
```

Windows 不支援 directory hardlink，因此 directory profile 預設使用不需 Administrator 的 junction；`--symlink` 可在 Developer Mode／elevated 環境使用。框架亦支援 `Kind = 'File'` 配合 `LinkType = 'HardLink'` 的自訂 profile。專案 ID 對 capsule 內的 source path 使用相對路徑計算，所以把 repository 放在 `workspace/` 後，整個 capsule與 source 一起搬移仍會找到同一份 project cache。capsule 外的專案則以 absolute path 識別；專案本身搬位後會形成新的 cache ID。File hardlink 只適合同一 volume 的明確檔案 profile；正常狀態以 Windows file identity 驗證。Registry 另保存 length + SHA-256 ownership fingerprint，使整個 capsule 被跨 drive「copy + delete」而令 hardlink 退化成兩份普通檔案時仍能安全判斷是否可重建。

建立 link 時會在 `.capsulenv/project-cache-links.json` 登記 capsule-relative project reference、link type 與最後一次 target。Junction／absolute symlink 搬移後仍可能保存舊 target，因此 `shell`、`init` 會自動嘗試重接；也可手動執行：

```bat
capsulenv.cmd cache repair
capsulenv.cmd cache repair --strict
```

修復器只會替換「目前 stale target 精確等於 registry 記錄的上一個 target」的 reparse point；普通目錄、普通檔案或指向其他位置的 link 一律拒絕改動。外部 project 暫時不在時會保留記錄並跳過，之後可再修復。

若 portable `scoop-global/apps` 內已有應用程式，完整 `rehydrate` 必須在 elevated terminal 執行。Scoop 對非 elevated global reset 只會略過 app；capsulenv 會在 reset 前拒絕繼續，避免 links 尚未重建便錯誤保存新的 relocation fingerprint。

Scoop 原生 `reset` 會重建 app 的 `current` junction、shims、Start Menu shortcuts、User/Machine environment entries 與 `persist` links，所以它不能直接作為 ShellOnly relocation primitive。Capsulenv 現在依 mode 分流：

1. **ShellOnly** 使用 capsule-local temporary Scoop command，只執行 `link_current`、`create_shims`、`unlink_persist_data`／`persist_data` 與 persist permission；不建立 Start Menu shortcut、不寫 User/Machine environment，也不 replay manifest hook。
2. **User** 使用原生 `scoop reset *`，因為此 mode 已明確把 capsule 當成該 user 的 Scoop；其後才可 replay `config/capsulenv.psd1` allow-list 中的 hooks。
3. 兩種 mode 都可對 `Scoop.RelocationRepairs` allow-list 中的 persisted UTF text／JSON 做交易式 OldRoot → NewRoot 修復，並修復 tool/project links。
4. 全部成功後才保存 relocation fingerprint。User mode 同時刷新持久 `SCOOP`／`SCOOP_GLOBAL`／managed PATH，移除 mode state 記錄的舊 drive path。

`capsulenv.cmd hooks ...` 在 ShellOnly 直接拒絕執行；這是刻意的，因為 manifest lifecycle code 並沒有「只許寫 capsule」的 contract。`pre_install` 在 User mode仍需明確呼叫，因為不少 manifest 會做一次性 transformation。

## PowerShell bootstrap

`capsulenv.cmd` 會先從 capsule 自己的 `scoop/apps/pwsh/<version>/pwsh.exe` 尋找 PowerShell 7，並排除可能在搬移後失效的 `current` junction。其後才嘗試 capsule-local `current`、Scoop shim、父層 `PATH` 的 `pwsh.exe`，最後回退至 Windows PowerShell 5.1。local Scoop root 優先於 `scoop-global/`。

所有入口及 child PowerShell 均明確使用 process-scope `-ExecutionPolicy Bypass`；不會執行 `Set-ExecutionPolicy` 或持久修改 registry。Group Policy 的 `MachinePolicy`／`UserPolicy` 仍可覆蓋 process policy。

若 `config/capsulenv.psd1` 把 Scoop roots 改成非預設位置，bootstrap 階段可先指定：

```bat
set CAPSULENV_BOOTSTRAP_SCOOP_ROOT=D:\portable\scoop
set CAPSULENV_BOOTSTRAP_SCOOP_GLOBAL_ROOT=D:\portable\scoop-global
capsulenv.cmd doctor
```


## Build 與安裝

開發 repo 可直接執行 `capsulenv.cmd`，每次按需要重新 merge module。正式 portable 環境可先生成只含 runtime 的目錄：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv
```

或把已 merge 的 module、batch launchers、設定、runtime scripts 與文件安裝／更新到指定位置：

```bat
install.cmd D:\Portable\capsulenv
```

安裝目的地不可位於 source repository 內；source-local staging 應使用 `Build-Capsulenv.ps1`。安裝器只更新 `.capsulenv-install.json` 列出的 managed files，保留 `scoop/`、`scoop-global/`、`cache/`、`tool-data/`、`project-cache/`、`workspace/`、`PowerShell/Modules/`、`.capsulenv/`、local config 與其他未知檔案。更新失敗時會把已動過的 managed files 交易式還原。正常安裝版直接 import `modules\Capsulenv\Capsulenv.psd1`，不需要攜帶 `src/` 或 merge script。詳見 `docs/INSTALL.md`。

### Fresh Scoop bootstrap

不再要求預先把另一份 portable Scoop 複製到 `scoop/`。當 capsule 內沒有 Scoop core／Main bucket 時，Capsulenv 會自行 bootstrap：優先使用 capsule Git，其次借用目前 `PATH` 的 Git 作**下載 transport**，並以 `--depth 1 --single-branch` clone Scoop 與 Main；Git 不可用或 clone 失敗時才下載設定中的 archive。這些 upstream repository 都是 live Scoop data，不是 capsulenv submodule，也不會納入 capsulenv installer 的 managed-file ownership。

Shell-only bootstrap 只建立／更新 capsule 自己的 `scoop/`，不會探測、搬用或更新 `%USERPROFILE%\scoop` 等 host Scoop root。`scoop\config.json` 先於 Scoop core 建立，因此 host 的 Scoop config 亦不會被採用。若使用 archive fallback，Capsulenv 不會為了補 Git metadata 而覆寫一個已健康的 Scoop；日後交由 Scoop 原生 update lifecycle 管理。

## 開始使用

Fresh install 可直接：

```bat
capsulenv.cmd doctor
capsulenv.cmd init
capsulenv.cmd shell
```

需要單獨建立缺失的 Scoop/Main 時亦可執行 `capsulenv.cmd bootstrap`。`init` 會在 bootstrap 後立即做一次完整 rehydrate。日後整個 capsule 被搬到另一個 path、另一部電腦或另一個 Windows user 時，首次 `shell` 會自動再做一次。

只執行一個 command：

```bat
capsulenv.cmd run scoop status
capsulenv.cmd run git status
```

### ShellOnly GUI app launcher

ShellOnly 不會把 Scoop manifest 的 `shortcuts` materialize 到 Windows Start Menu；有 `bin` 的 app 仍直接使用 Scoop shim。只有 shortcut、或想按 manifest shortcut 語意啟動 GUI app 時，可直接讀已安裝版本的 metadata：

```bat
capsulenv.cmd app list
capsulenv.cmd app list <app>
capsulenv.cmd app run <app>
capsulenv.cmd app run <app> "<shortcut name>"
capsulenv.cmd app run <app> -- <runtime arguments...>
```

launcher 只讀 `scoop/apps/<app>/current/manifest.json` / `scoop-global/apps/<app>/current/manifest.json` 與同目錄 `install.json`，遵循已安裝 architecture-specific `shortcuts`，並展開 Scoop shortcut arguments 使用的 `$dir`、`$original_dir`、`$persist_dir`。它直接 `Start-Process` manifest target，不建立 `.lnk`、不修改 Start Menu，也不讀 bucket 中可能已更新的 manifest。

若同一 app 同時存在 user/global portable roots，plain `<app>` 不會猜測；明確使用 `user/<app>` 或 `global/<app>`。若 manifest 有多個 shortcuts，`app run` 亦要求指定 shortcut name。需要把額外 arguments 傳給 app 時，以 `--` 分隔，避免和 shortcut name 混淆。User mode 仍可使用 Scoop 原生 Start Menu shortcuts；這個 launcher 在兩個 mode 都可用。

## Scoop lifecycle

完整重建 links 並重放設定中的安全 hooks：

```bat
capsulenv.cmd rehydrate
```

只做原生 Scoop reset：

```bat
capsulenv.cmd reset
capsulenv.cmd reset firefox zen-browser
```

明確重跑某個 installed manifest hook：

```bat
capsulenv.cmd hooks post_install firefox zen-browser
capsulenv.cmd hooks pre_install some-app
```

第二個指令屬高風險顯式操作。capsulenv 不會自行判斷任意 `pre_install` 是否冪等。

需要暫時略過 hook：

```bat
capsulenv.cmd rehydrate --skip-hooks
```

需要保留原始 persisted 設定、只重建 Scoop 與 hooks：

```bat
capsulenv.cmd rehydrate --skip-persist-repairs
```

預覽或手動重跑路徑修復：

```bat
capsulenv.cmd repair-persist --dry-run
capsulenv.cmd repair-persist firefox zen-browser
capsulenv.cmd repair-persist --last
```

`--last` 使用最後一次成功搬遷所保存的 OldRoot → NewRoot context，適合修復後才新增或恢復的 persisted 設定檔。

### 調整自動重放清單

複製 local config：

```powershell
Copy-Item config\capsulenv.local.psd1.example config\capsulenv.local.psd1
```

例如：

```powershell
@{
    Scoop = @{
        ReplayHooks = @{
            firefox = @('post_install')
            'zen-browser' = @('post_install')
        }
    }
}
```

`Scoop.ReplayHooks` 與 `Scoop.RelocationRepairs` 都是安全 allow-list；local config 中出現時會各自整個取代預設值。設為 `@{}` 即可停用相應自動行為；其他 nested hashtable 仍會 recursive merge。

### Persist relocation repair

Capsulenv 不會 recursive scan `scoop\persist`，也不會碰 SQLite、binary database 或未列出的檔案。每條規則必須指定 app 與相對路徑，可選 `text` 或 `json`；JSON 會在替換前後解析驗證。檔案必須是有效 UTF-8／UTF-16／UTF-32，原 encoding 與 BOM 會保留。

寫入流程會先建立完整 plan、確認相關 process 已關閉、再次核對原始 bytes，再以同目錄 temporary/rollback files 逐檔替換。任何檔案失敗時，已套用的修改會全部回滾，而且新的 relocation fingerprint 不會寫入。

舊路徑來源優先使用 `.capsulenv/scoop-rehydration.json`。若該 state 沒有跟著資料夾搬移，capsulenv 會在 `scoop/shims/*.shim` 與 `scoop-global/shims/*.shim` 中讀取尚未 reset 的 absolute targets，以多數決推斷舊 Scoop root；若兩者都不可得，會安全地跳過無法推斷的 root，而不是猜測。

自訂例子：

```powershell
@{
    Scoop = @{
        RelocationRepairs = @{
            'some-app' = @(
                @{
                    Path = 'config\settings.json'
                    Format = 'json'
                    Processes = @('some-app')
                    MaxBytes = 4194304
                }
            )
        }
    }
}
```

## Firefox 與 Zen Browser

capsulenv 不建立、複製或搬動 browser profile；profile 仍由 Scoop `persist` 保存。搬移時，預設 allow-list 只修復 profile/distribution 中幾個已知 text/JSON 檔案內的舊 absolute root。User mode 可再 replay manifest `post_install` 做正常 user profile registration；ShellOnly 不 replay，避免修改 host browser `profiles.ini` 等 user integration。

Capsulenv browser command 會明確以 `-profile <capsule persist profile>` 啟動，不依賴 host default profile；ShellOnly 另外加入 `-no-remote`，避免命令被既有 host Firefox/Zen process 接走：

```bat
capsulenv.cmd firefox
capsulenv.cmd zen
firefox-capsulenv.cmd
zen-capsulenv.cmd
```

預設修復檔案為：

```text
profile\compatibility.ini
profile\extensions.json
profile\prefs.js
profile\user.js
distribution\policies.json
```

缺失檔案會略過；Firefox／Zen 正在執行時會拒絕修改。若不希望 capsulenv 改寫任何 browser persisted text，可在 local config 設定 `RelocationRepairs = @{}`，或使用 `rehydrate --skip-persist-repairs`。

User mode 若 profile registration 因搬移而失效可執行 `rehydrate`；ShellOnly 的 Capsulenv launcher 不依賴該 registration。不要另建第二份 capsulenv profile store。

## Bitwarden SSH Agent

Bitwarden 的 `bitwarden-appdata` 仍完全由 Scoop manifest `persist` 擁有。Bitwarden 不在通用 `RelocationRepairs` 預設 allow-list 中，避免對 vault/application state 做舊路徑全文替換。capsulenv 不複製 app-data，也不重建 vault；SSH Agent setup 只會對 Scoop-persisted `data.json` 做**窄範圍設定 patch**，處理 Bitwarden Desktop 現行使用的兩類 state key：

- `global_desktopSettings_sshAgentEnabled`
- `user_<account-id>_desktopSettings_sshAgentRememberAuthorizations`

設定前會關閉 Bitwarden，記錄這些 key 原本存在與否及其原始 literal，驗證修改前後都是 JSON object，再以同目錄暫存檔替換。還原時只還原／移除上述 key，不會用舊 `data.json` 覆蓋之後新增的 vault 或其他 application state。

以 elevated terminal 執行完整設定：

```bat
capsulenv.cmd bitwarden setup
```

預設授權策略是 `always`。亦可指定：

```bat
capsulenv.cmd bitwarden setup never
capsulenv.cmd bitwarden setup remember-until-lock
```

完整 setup 會：

1. 關閉 Bitwarden；依目前 mode 修復該 Scoop app 的 `current`／persist link（ShellOnly 使用 portable reset，User 使用 native reset）。
2. 只在 capsule 的 Scoop-persisted `data.json` 啟用 SSH Agent 並設定授權策略。
3. `SSH_AUTH_SOCK=\\.\pipe\openssh-ssh-agent` 永遠先在 Capsulenv process 生效；User mode亦可由 user-environment ownership 持久化。
4. **ShellOnly** 用 `GIT_CONFIG_COUNT`／`GIT_CONFIG_KEY_n`／`GIT_CONFIG_VALUE_n` 建立 process-only Git OpenSSH overlay，不寫 `~/.gitconfig`，且不改 Windows `ssh-agent` service。
5. **User** 才備份並寫 `git config --global core.sshCommand`／`gpg.ssh.program`；若 elevated，才可備份後停用 Windows `ssh-agent` service。
6. 重新啟動 Scoop-installed Bitwarden。Capsulenv 只會識別／停止位於本 capsule `scoop`／`scoop-global` app roots 的 Bitwarden process；若同名但位於 host 安裝位置的 Bitwarden 正在執行，setup/start 會拒絕繼續，絕不借用或終止它。

可略過個別 host integration：

```bat
capsulenv.cmd bitwarden setup --skip-service
capsulenv.cmd bitwarden setup --skip-git
capsulenv.cmd bitwarden setup always --no-start
```

檢查與測試：

```bat
capsulenv.cmd bitwarden status
capsulenv.cmd bitwarden agent-test
```

一鍵精確還原 capsulenv 改動：

```bat
capsulenv.cmd bitwarden restore
```

若 setup 當時未 elevated，service 不會被改動；若 restore 時未 elevated，desktop/Git 設定仍會還原，而 service backup 會保留，待以下命令在 elevated terminal 執行：

```bat
capsulenv.cmd bitwarden restore-windows-agent
```

低階分拆命令仍保留：

```bat
capsulenv.cmd bitwarden start
capsulenv.cmd bitwarden disable-windows-agent
capsulenv.cmd bitwarden configure-git
capsulenv.cmd bitwarden restore-git
```

這個 app-setting patch 依賴 Bitwarden Desktop 目前的公開原始碼 state key，而不是官方穩定 CLI contract；未知 JSON schema、重複 key 或無法驗證的檔案會直接拒絕修改。

## Shell-only 與 User installation

Capsulenv 有兩個刻意分開的 ownership mode。

**ShellOnly（預設）**只在目前 Capsulenv process／child shell 設定 `SCOOP`、`SCOOP_GLOBAL`、PATH 與其他 Capsulenv variables。bootstrap 及 config 全部位於 capsule 內，不會把本機既有 Scoop 當成自己的 root，也不會由 Capsulenv activation 寫入 User-scope `SCOOP`／`SCOOP_GLOBAL`／PATH。這是 `install.cmd D:\Portable\capsulenv` 的預設動機。

**User** 則明確把此 capsule 註冊成目前 Windows user 的 Scoop environment，使一般新 terminal 也會解析到這個 Scoop。可在安裝時直接選擇：

```bat
install.cmd D:\Portable\capsulenv -Mode User
```

或在既有 ShellOnly capsule 中切換：

```bat
capsulenv.cmd install-user
capsulenv.cmd user-shell
capsulenv.cmd restore-user
```

洗機共用電腦可直接把 `user-shell` 當日常入口；它在目前 user 尚未被 capsule 接管時執行/刷新 User takeover，處理 relocation，然後開 shell。離開前可用 `capsulenv.cmd eject` 關閉 capsule-owned processes、檢查 dirty workspace repos、記錄 eject state 並清 host-local scratch；**`eject` 不會呼叫 `restore-user`**。真正要還原 host user integration 時才明確執行 `restore-user`。

`enable-user` 保留為 `install-user` 的 compatibility alias。Capsulenv 的 mode 現在代表**目前 machine/user 的 integration ownership**，不是 USB 的全域 profile：每個 capsule 有 stable UUID，而 User backup/state 放在 `.capsulenv/user-integrations/<machine-user-hash>/`。因此同一支 USB 可在 Laptop 保持 ShellOnly，同時在洗機共用電腦使用 User；共用電腦重置後再次 `install-user` 會辨識該 host 的舊 User ledger、重新 snapshot 乾淨 User environment 後接管，不要求先 `restore-user`。`user-shell` 則把 install/sync、relocation self-heal 與開 shell 合成一個 idempotent 入口。

首次 User install 會精確備份原有 `SCOOP`、`SCOOP_GLOBAL`、`SCOOP_CACHE`、`PATH`、`CAPSULENV_MODULE_ROOT`、`SSH_AUTH_SOCK`、tool cache/home/config variables、自訂 variables，以及 Scoop `use_isolated_path` 指定的 path variable（如 `SCOOP_PATH`）；`restore-user` 會還原「原值」或「原本不存在」。`PSModulePath` 刻意保持 session-only。若 Capsulenv 的 User-mode Bitwarden integration 曾改過 global Git SSH 設定或 Windows `ssh-agent` service，`restore-user` 也會先利用既有 backup 還原它們；service 有待還原時需以 elevated terminal 執行。Managed PATH state 使用 `capsule://...` reference 而不是 drive-specific absolute path；User mode 從 `F:` 搬到 `G:` 時，Capsulenv 仍可用 capsule identity + 同 machine/user relocation fingerprint 辨識舊 User ownership，清掉舊 root entries，再由 native reset 加回新位置。

這個 reversible contract 僅涵蓋 **Capsulenv 自己記錄並擁有的 integration**。在 User mode 由 Scoop manifest 建立的 Start Menu shortcuts、manifest-specific environment keys 或其他 package lifecycle side effects 屬 Scoop/package ownership；Capsulenv 沒有足夠原始狀態可安全地在 `restore-user` 時通用還原，因此不會猜測或刪除它們。
從既有 ShellOnly capsule 執行 `install-user` 時亦不會為了補齊 UI integration 而無條件 `scoop reset *`；它先把 **Scoop root/shims/environment ownership** 切成 User。之後新 `scoop install` 依原生 User semantics 工作；若要把既有 apps 的 shortcuts/env 明確 materialize，可在 User mode 主動執行 `capsulenv.cmd reset`。真正發生 relocation 時則會自動 native reset，因為既有 User integration 的 absolute targets 已需要修復。

Scoop local 與 portable-global shim directories 都會加入 Capsulenv environment plan。ShellOnly 只加入 process PATH；User 才持久加入 User PATH。為避免 capsule 缺少某個 command 時 PATH fall-through 到 host Scoop，session activation 會從**當前 process PATH**移除可由 inherited/User/Machine `SCOOP`／`SCOOP_GLOBAL`（以及 Windows 預設 Scoop roots）證明屬於其他 Scoop installation 的 shim directories；User takeover 也會暫時從 User PATH 移除原 Scoop shims，而 `restore-user` 依完整 PATH backup 精確放回。Capsulenv 會把 Scoop 自己的 `scoop.ps1`／`scoop.cmd` 正規化為以 shim 位置計算的 relative launcher；app `current` junction、app shims 與 persist links 則在 relocation reset 時重建，因此不依賴原 drive letter。`SCOOP_CACHE` 也由 mode-aware environment plan 明確指向 capsule 的 `cache\scoop`，避免 portable `config.json` 中舊的 absolute `cache_path` 在換 drive 後接管 cache。

Project-cache junction／absolute symlink 仍以 registry 的上一個 target 驗證 ownership 才重建。File hardlink 不能跨 volume：registry 現在額外保存 managed file 的 length + SHA-256 fingerprint；若跨 drive copy 把原 hardlink 變成兩份普通檔案，只有兩份內容仍與記錄 fingerprint 相同且新位置仍在同一 volume 時才會重新 hardlink。兩份內容已分岔、沒有舊 fingerprint、或新 link/store 位於不同 volume時一律拒絕覆蓋。

ShellOnly 保證的是 **Capsulenv 自己的 activation/bootstrap/rehydrate/Bitwarden integration 不接管 host Scoop 或持久 user integration**；它不可能禁止使用者在 shell 中親自執行任意會改系統的程式。若直接呼叫 upstream `scoop install/reset`，manifest 本身仍可能依 Scoop 原生語意建立 User shortcut 或 env；要維持 isolation，使用 Capsulenv 的 mode-aware `reset`/`rehydrate`，並把 package action 本身視為顯式 side effect。

## Offline readiness 與 drift

```bat
capsulenv.cmd offline status
capsulenv.cmd offline prefetch
capsulenv.cmd drift
```

`offline status` 檢查目前已安裝 Scoop runtime/apps 是否可直接從 USB 使用，並統計 portable Scoop cache；`offline prefetch` 以目前 local bucket snapshot 為準替已安裝 apps 預熱 `cache/scoop`，不把 prefetch 變成隱式 Scoop update。`drift` 則比較 installed manifest version 與 USB 上 local bucket manifest version，不連網更新 bucket。

## 驗證

在 Windows PowerShell 5.1 或 PowerShell 7 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

Pester 6.1.0+ 是唯一測試入口；repo 不再保留第二套 smoke runner。測試會合併模組、解析 scripts，並驗證 shallow bootstrap、ShellOnly/User ownership、host-scoped integration ledger、capsule identity/state reference、local/global shims、mode-aware reset/hook boundary、portable Git/package-manager config、scratch、offline/drift、browser profile binding、hardlink relocation ownership、prebuilt runtime 與 transactional installer；不會在測試 host 上執行真實 browser/service 或 Git global changes。
