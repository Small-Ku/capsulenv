# capsulenv

`capsulenv` 是一個可搬移的 Windows Scoop 啟動與修復層。它不再自行管理 `data/`、Bitwarden app-data、Firefox profile 或 Zen profile；這些一律交回 Scoop manifest 的 `persist`、`pre_install` 與 `post_install`。

每次由 `capsulenv.cmd` 啟動時，`Merge-ModuleScripts.ps1` 會 deterministic merge `src/*.ps1`，生成 `.build/Capsulenv/Capsulenv.psm1`。`shell` 會開啟繼承 portable Scoop environment 的子 PowerShell。

## 所有權模型

```text
capsulenv/
├─ capsulenv.cmd
├─ src/                              capsulenv orchestration only
├─ scripts/scoop-capsulenv-replay.ps1
├─ config/
├─ scoop/                            complete portable Scoop root
│  ├─ apps/
│  ├─ buckets/
│  ├─ persist/                       manifest-declared persisted app data/profiles
│  ├─ shims/
│  └─ cache/
├─ scoop-global/                     optional Scoop-owned global root
├─ .capsulenv/                       relocation marker and reversible backups
└─ .build/                           generated module
```

capsulenv 同時設定 `SCOOP` 與 `SCOOP_GLOBAL`，避免 `reset *` 意外枚舉主機的 `%ProgramData%\scoop`。兩個 root 都仍由 Scoop 本體管理。

Scoop 原生 `reset` 會重建 app 的 `current` junction、shims、shortcuts、environment entries 與 `persist` links。它不會重跑 manifest 的 `pre_install` / `post_install`，所以 capsulenv 的 rehydrate 流程為：

1. 執行 `scoop reset *`。
2. 從 portable local／global root 中每個已安裝版本自己的 `manifest.json` 與 `install.json` 讀取 lifecycle。
3. 只重放 `config/capsulenv.psd1` 明確列出的 hooks。
4. 成功後記錄目前 root、computer 與 user；同一位置不會每次開 shell 都重跑。

預設只重放 Firefox／Zen 類 manifest 的 `post_install`，用來重新註冊 Scoop profile。`pre_install` 預設完全不重放，因為不少 manifest 會在其中 rename installer、搬檔或做一次性 migration，第二次執行並不安全。

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

需要暫時略過 hook，只修復 Scoop links：

```bat
capsulenv.cmd rehydrate --skip-hooks
```

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

`Scoop.ReplayHooks` 會整個取代預設 allow-list，因此設為 `@{}` 即可停用所有自動 hook；其他 nested hashtable 仍會 recursive merge。

## Firefox 與 Zen Browser

capsulenv 不建立、複製、搬動或改寫 browser profile。官方／所選 Scoop manifest 應透過 `persist` 保存 profile，並在 `post_install` 中註冊它。

啟動器只找出 Scoop-installed executable 並正常啟動：

```bat
capsulenv.cmd firefox
capsulenv.cmd zen
firefox-capsulenv.cmd
zen-capsulenv.cmd
```

若 profile registration 因搬移而失效，執行 `rehydrate`；不要另建 capsulenv profile store。

## Bitwarden SSH Agent

Bitwarden 的 `bitwarden-appdata` 由 Scoop manifest `persist`。capsulenv 僅負責 host integration：

- session／可選 User scope 的 `SSH_AUTH_SOCK=\\.\pipe\openssh-ssh-agent`
- 啟動 Scoop-installed Bitwarden Desktop
- 可備份後停用 Windows `ssh-agent` service
- 可備份後令 Git 明確使用 Microsoft OpenSSH

Bitwarden Desktop 內的 **Enable SSH agent** 仍由 Bitwarden persisted settings 保存；capsulenv 不改寫 vault/application internals。

```bat
capsulenv.cmd bitwarden start
capsulenv.cmd bitwarden disable-windows-agent
capsulenv.cmd bitwarden configure-git
capsulenv.cmd bitwarden agent-test
```

還原：

```bat
capsulenv.cmd bitwarden restore-windows-agent
capsulenv.cmd bitwarden restore-git
```

停用／還原 Windows service 需要 elevated terminal。

## Session 與 User environment

正常 `shell` environment 只影響新開的 child PowerShell。惟首次 relocation rehydrate 會執行原生 `scoop reset`；若某些 manifests 宣告 `env_add_path`／`env_set`，Scoop 會按其原生語意重新套用相應 User environment entries。

需要讓新開的其他 terminal 也固定使用此 Scoop root 時：

```bat
capsulenv.cmd enable-user
capsulenv.cmd restore-user
```

首次 `enable-user` 會精確備份原有 `SCOOP`、`SCOOP_GLOBAL`、`PATH`、`SSH_AUTH_SOCK` 及自訂 variables；restore 會還原「原值」或「原本不存在」。

## 驗證

在 Windows PowerShell 5.1 或 PowerShell 7 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

測試會合併模組、用 PowerShell AST 解析所有 scripts、檢查 exports、schema、environment plan 與 lifecycle ownership，不會執行 `scoop reset`、hooks、browser、service 或 Git global changes。
