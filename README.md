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
├─ cache/                            portable download/compile caches
├─ tool-data/                        toolchains and global tool state
├─ project-cache/                    linked per-project build caches
├─ workspace/                        recommended portable source workspace
├─ scoop/                            complete portable Scoop root
│  ├─ apps/
│  ├─ buckets/
│  ├─ persist/                       manifest-declared persisted app data/profiles
│  ├─ shims/
│  └─ cache/
├─ scoop-global/                     optional Scoop-owned global root
├─ .capsulenv/                       relocation state, link registry, reversible backups
├─ .build/                           development-only generated module
└─ .capsulenv-runtime.json           installed runtime metadata
```

capsulenv 同時設定 `SCOOP` 與 `SCOOP_GLOBAL`，避免 `reset *` 意外枚舉主機的 `%ProgramData%\scoop`。兩個 root 都仍由 Scoop 本體管理。

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

Windows 不支援 directory hardlink，因此 directory profile 預設使用不需 Administrator 的 junction；`--symlink` 可在 Developer Mode／elevated 環境使用。框架亦支援 `Kind = 'File'` 配合 `LinkType = 'HardLink'` 的自訂 profile。專案 ID 對 capsule 內的 source path 使用相對路徑計算，所以把 repository 放在 `workspace/` 後，整個 capsule與 source 一起搬移仍會找到同一份 project cache。capsule 外的專案則以 absolute path 識別；專案本身搬位後會形成新的 cache ID。File hardlink 只適合位於同一 volume 的明確檔案 profile，建立後會用 Windows file identity 驗證，而不是只比較檔名。

建立 link 時會在 `.capsulenv/project-cache-links.json` 登記 capsule-relative project reference、link type 與最後一次 target。Junction／absolute symlink 搬移後仍可能保存舊 target，因此 `shell`、`init` 會自動嘗試重接；也可手動執行：

```bat
capsulenv.cmd cache repair
capsulenv.cmd cache repair --strict
```

修復器只會替換「目前 stale target 精確等於 registry 記錄的上一個 target」的 reparse point；普通目錄、普通檔案或指向其他位置的 link 一律拒絕改動。外部 project 暫時不在時會保留記錄並跳過，之後可再修復。

若 portable `scoop-global/apps` 內已有應用程式，完整 `rehydrate` 必須在 elevated terminal 執行。Scoop 對非 elevated global reset 只會略過 app；capsulenv 會在 reset 前拒絕繼續，避免 links 尚未重建便錯誤保存新的 relocation fingerprint。

Scoop 原生 `reset` 會重建 app 的 `current` junction、shims、shortcuts、environment entries 與 `persist` links。它不會重跑 manifest 的 `pre_install` / `post_install`，所以 capsulenv 的 rehydrate 流程為：

1. 執行 `scoop reset *`。
2. 從 portable local／global root 中每個已安裝版本自己的 `manifest.json` 與 `install.json` 讀取 lifecycle。
3. 只重放 `config/capsulenv.psd1` 明確列出的 hooks。
4. 對 `Scoop.RelocationRepairs` 明確列出的 persisted UTF text／JSON 檔案，交易式替換舊 capsule、Scoop local/global root。
5. 全部成功後才記錄目前 root、computer 與 user；任一步失敗都不會把搬遷標記為完成。

預設只重放 Firefox／Zen 類 manifest 的 `post_install`，用來重新註冊 Scoop profile。`pre_install` 預設完全不重放，因為不少 manifest 會在其中 rename installer、搬檔或做一次性 migration，第二次執行並不安全。

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

安裝目的地不可位於 source repository 內；source-local staging 應使用 `Build-Capsulenv.ps1`。安裝器只更新 `.capsulenv-install.json` 列出的 managed files，保留 `scoop/`、`scoop-global/`、`cache/`、`tool-data/`、`project-cache/`、`workspace/`、`.capsulenv/`、local config 與其他未知檔案。更新失敗時會把已動過的 managed files 交易式還原。正常安裝版直接 import `modules\Capsulenv\Capsulenv.psd1`，不需要攜帶 `src/` 或 merge script。詳見 `docs/INSTALL.md`。

## 開始使用

把完整 portable Scoop root 放在 repo 的 `scoop/`：

```bat
capsulenv.cmd doctor
capsulenv.cmd init
capsulenv.cmd shell
```

`init` 會立即做一次完整 rehydrate。日後整個 repo 被搬到另一個 path、另一部電腦或另一個 Windows user 時，首次 `shell` 會自動再做一次。

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

capsulenv 不建立、複製或搬動 browser profile；profile 仍由 Scoop `persist` 保存。搬移時，預設 allow-list 只會修復 profile/distribution 中幾個已知 text/JSON 檔案內的舊 absolute root，然後重跑 manifest `post_install` 以重新註冊 Scoop profile。

啟動器只找出 Scoop-installed executable 並正常啟動：

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

若 profile registration 因搬移而失效，執行 `rehydrate`；不要另建 capsulenv profile store。

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

1. 關閉 Bitwarden，並對實際 Scoop app 執行原生 `scoop reset <app>`，先重建 `current` 與 `persist` link。
2. 在 Bitwarden persisted settings 啟用 SSH Agent。
3. 對已出現在 `data.json` 的所有帳戶套用授權策略；未登入過時，Bitwarden 的預設值仍是 `always`。
4. 設定 capsulenv session 的 `SSH_AUTH_SOCK=\\.\pipe\openssh-ssh-agent`。
5. 備份後令 Git 使用 Windows 內建 Microsoft OpenSSH。
6. 若目前 terminal 已 elevated，備份後停用 Windows `ssh-agent` service。
7. 重新啟動 Scoop-installed Bitwarden。

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

## Session 與 User environment

正常 `shell` environment 只影響新開的 child PowerShell。惟首次 relocation rehydrate 會執行原生 `scoop reset`；若某些 manifests 宣告 `env_add_path`／`env_set`，Scoop 會按其原生語意重新套用相應 User environment entries。

需要讓新開的其他 terminal 也固定使用此 Scoop root 時：

```bat
capsulenv.cmd enable-user
capsulenv.cmd restore-user
```

首次 `enable-user` 會精確備份原有 `SCOOP`、`SCOOP_GLOBAL`、`PATH`、`SSH_AUTH_SOCK`、tool cache/home variables 及自訂 variables；restore 會還原「原值」或「原本不存在」。升級或搬位後可用 `capsulenv.cmd enable-user --force` 延伸舊 backup 並重套新值，既有 backup entries 不會被覆寫。

## 驗證

在 Windows PowerShell 5.1 或 PowerShell 7 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

測試會合併模組、用 PowerShell AST 解析所有 scripts，檢查 exports、schema、environment plan、relocation replacement boundary、tool-storage plan、project-link contracts、prebuilt runtime、transactional installer、persisted-file repair 與 lifecycle ownership；不會執行真實 `scoop reset`、hooks、browser、service 或 Git global changes。
