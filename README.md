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
├─ cache/                            portable download/compile caches
├─ tool-data/                        toolchains and global tool state
├─ project-cache/                    linked per-project build caches
├─ workspace/                        recommended portable source workspace
├─ scoop/                            complete portable Scoop root
│  ├─ apps/
│  ├─ buckets/
│  ├─ persist/                       manifest-declared persisted app data/profiles
│  ├─ shims/
│  ├─ config.json                     portable Scoop config boundary
│  └─ cache/
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

## Portable tool storage

開發工具自己的 cache、toolchain 與 global-tool data 會透過官方環境變數放在 capsule 內，而不是使用主機 `%LOCALAPPDATA%` 或 user home：

```text
cache/
├─ uv/
├─ uv-python/
├─ pixi/
├─ sccache/
└─ ccache/
tool-data/
├─ uv/python/
├─ uv/tools/
├─ pixi/
├─ rustup/
└─ cargo/
project-cache/
└─ <stable-project-id>/
```

預設管理 `UV_CACHE_DIR`、`UV_PYTHON_CACHE_DIR`、`UV_PYTHON_INSTALL_DIR`、`UV_PYTHON_BIN_DIR`、`UV_TOOL_DIR`、`UV_TOOL_BIN_DIR`、`PIXI_HOME`、`PIXI_CACHE_DIR`、`RUSTUP_HOME`、`CARGO_HOME`、`SCCACHE_DIR`、`CCACHE_DIR` 與 `CCACHE_TEMPDIR`。`bin/` 同時作為 uv-managed Python 與 uv tool executable 目錄；Cargo/Pixi global bin 亦加入 capsule session 的 `PATH`。Scoop 自己的下載 cache 已位於 `scoop/cache`，不重複 redirect，並只由 Scoop 按需要建立。 `tool-data/` 可能包含 Cargo registry credentials 或其他工具登入狀態，與 Scoop persist 一樣應視為私人 portable data；已預設 git-ignore，不應直接公開整個 runtime。

設定環境變數不會代替安裝工具；工具仍由 portable Scoop 管理。Scoop 自己的 package download cache 會顯示為 `SCOOP_CACHE`。`cache/` 與 `project-cache/` 是可重建資料；`tool-data/` 則含 rustup toolchains、Cargo/uv/Pixi global tools 等，不應當成純 cache 隨意刪除。這些內容亦不適合由多部電腦同時寫入同一個同步資料夾。capsulenv 不會預設設定 `RUSTC_WRAPPER=sccache`，以免尚未安裝 sccache 時令 Cargo 失敗；需要時可在 local config 的 `ToolStorage.Variables` 明確加入。uv 與 Pixi 自己建立的 virtual environment、executable wrapper、trampoline 與 prefix metadata 不是 capsulenv-managed junction。搬移後，capsulenv 會逐一以原有 managed Python key 重裝 uv Python，從 tool receipt 保留 global tool 的完整安裝意圖，並修復明確登記、具 lock file 的 uv/Pixi workspace：

```bat
capsulenv.cmd tools register uv workspace\python-app
capsulenv.cmd tools register pixi workspace\science-app
capsulenv.cmd tools repair all --dry-run --last
```

uv global tool 修復只把當前已安裝版本加在命令參數，不改寫 receipt 的 registry、local path、URL 或 VCS requirement。登記的 uv workspace 會先備份原環境，以 uv 原生 `venv --relocatable` 重建，再按 `uv.lock` 做 locked sync；environment path 必須位於 workspace 或 capsule 內。Pixi workspace 使用 `--locked` 重新安裝；Pixi global manifest 可能包含版本範圍，因此 `pixi global sync` 預設只在明確傳入 `--include-global` 時執行，避免 relocation 暗中升級。詳見 `docs/TOOLS.md`。

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
capsulenv.cmd restore-user
```

`enable-user` 保留為 `install-user` 的 compatibility alias。首次 User install 會精確備份原有 `SCOOP`、`SCOOP_GLOBAL`、`SCOOP_CACHE`、`PATH`、`CAPSULENV_MODULE_ROOT`、`SSH_AUTH_SOCK`、tool cache/home variables、自訂 variables，以及 Scoop `use_isolated_path` 指定的 path variable（如 `SCOOP_PATH`）；`restore-user` 會還原「原值」或「原本不存在」，再把 mode 記回 ShellOnly。`PSModulePath` 刻意保持 session-only。若 Capsulenv 的 User-mode Bitwarden integration 曾改過 global Git SSH 設定或 Windows `ssh-agent` service，`restore-user` 也會先利用既有 backup 還原它們；service 有待還原時需以 elevated terminal 執行。User mode state 另外記錄 Capsulenv 自己 prepend 的 PATH entries；整個 capsule 從 `F:` 搬到 `G:` 時，rehydrate 除了移除舊 managed entries，亦只針對 relocation context 已知的舊 `ScoopRoot`／`ScoopGlobalRoot` 清掉 manifest app PATH（或 isolated Scoop path variable）中的舊 drive entries，再由 native reset 加回新位置。

這個 reversible contract 僅涵蓋 **Capsulenv 自己記錄並擁有的 integration**。在 User mode 由 Scoop manifest 建立的 Start Menu shortcuts、manifest-specific environment keys 或其他 package lifecycle side effects 屬 Scoop/package ownership；Capsulenv 沒有足夠原始狀態可安全地在 `restore-user` 時通用還原，因此不會猜測或刪除它們。
從既有 ShellOnly capsule 執行 `install-user` 時亦不會為了補齊 UI integration 而無條件 `scoop reset *`；它先把 **Scoop root/shims/environment ownership** 切成 User。之後新 `scoop install` 依原生 User semantics 工作；若要把既有 apps 的 shortcuts/env 明確 materialize，可在 User mode 主動執行 `capsulenv.cmd reset`。真正發生 relocation 時則會自動 native reset，因為既有 User integration 的 absolute targets 已需要修復。

Scoop local 與 portable-global shim directories 都會加入 Capsulenv environment plan。ShellOnly 只加入 process PATH；User 才持久加入 User PATH。為避免 capsule 缺少某個 command 時 PATH fall-through 到 host Scoop，session activation 會從**當前 process PATH**移除可由 inherited/User/Machine `SCOOP`／`SCOOP_GLOBAL`（以及 Windows 預設 Scoop roots）證明屬於其他 Scoop installation 的 shim directories；User takeover 也會暫時從 User PATH 移除原 Scoop shims，而 `restore-user` 依完整 PATH backup 精確放回。Capsulenv 會把 Scoop 自己的 `scoop.ps1`／`scoop.cmd` 正規化為以 shim 位置計算的 relative launcher；app `current` junction、app shims 與 persist links 則在 relocation reset 時重建，因此不依賴原 drive letter。`SCOOP_CACHE` 也由 mode-aware environment plan 明確指向 capsule 的 `scoop\cache`，避免 portable `config.json` 中舊的 absolute `cache_path` 在換 drive 後接管 cache。

Project-cache junction／absolute symlink 仍以 registry 的上一個 target 驗證 ownership 才重建。File hardlink 不能跨 volume：registry 現在額外保存 managed file 的 length + SHA-256 fingerprint；若跨 drive copy 把原 hardlink 變成兩份普通檔案，只有兩份內容仍與記錄 fingerprint 相同且新位置仍在同一 volume 時才會重新 hardlink。兩份內容已分岔、沒有舊 fingerprint、或新 link/store 位於不同 volume時一律拒絕覆蓋。

ShellOnly 保證的是 **Capsulenv 自己的 activation/bootstrap/rehydrate/Bitwarden integration 不接管 host Scoop 或持久 user integration**；它不可能禁止使用者在 shell 中親自執行任意會改系統的程式。若直接呼叫 upstream `scoop install/reset`，manifest 本身仍可能依 Scoop 原生語意建立 User shortcut 或 env；要維持 isolation，使用 Capsulenv 的 mode-aware `reset`/`rehydrate`，並把 package action 本身視為顯式 side effect。

## 驗證

在 Windows PowerShell 5.1 或 PowerShell 7 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

Pester 6.1.0+ 是唯一測試入口；repo 不再保留第二套 smoke runner。測試會合併模組、解析 scripts，並驗證 shallow bootstrap、ShellOnly/User ownership、local/global shims、mode-aware reset/hook boundary、Git process overlay、browser profile binding、hardlink relocation ownership、prebuilt runtime 與 transactional installer；不會在測試 host 上執行真實 browser/service 或 Git global changes。
