# 使用指南

[English](USAGE.md) | 繁體中文

這份文件按工作列出操作步驟。第一次安裝見 [README](../README.zh-TW.md)。執行規則見 [ARCHITECTURE](ARCHITECTURE.md)；工具資料規則見 [TOOLS](TOOLS.md)。

## Command conventions

以下命令在 Capsulenv 開出的 PowerShell 中執行。將 `<app>` 等預留值換成實際名稱，不要輸入角括號。

從外部命令提示字元執行時，將 `capsulenv` 換成完整的 `D:\Portable\capsulenv\capsulenv.cmd`。從外部 PowerShell 執行路徑時，可用 `& 'D:\Portable\capsulenv\capsulenv.cmd' status`。

查詢目前版本的完整參數：

```powershell
capsulenv help
capsulenv help app update
capsulenv app update --help
```

## Session modes

一般工作使用預設的 ShellOnly shell。需要 Windows 使用者整合時，執行：

```powershell
capsulenv user-shell
```

新 shell 及其子程序會繼承 User 模式。只要同步整合而不開啟新 shell 時，使用 `capsulenv install-user`。

用 `capsulenv status` 分別查看目前模式與持續的 User 整合。主機上的備份紀錄不會讓下一次獨立啟動自動進入 User 模式。

離開仍會繼續使用的主機前：

1. 儲存工作。
2. 執行 `capsulenv restore-user`。
3. 執行 `capsulenv eject`。
4. 處理命令回報的程序或未提交檔案。

關閉 shell 或執行 `eject` 都不會自動還原 User 整合。Capsulenv 只還原自己有所有權證據的設定。模式與還原所有權規則見 [ARCHITECTURE](ARCHITECTURE.md#shellonly-and-user-session-modes)。

## Packages

### Install and review

1. 檢查套件與相依項目：

   ```powershell
   capsulenv app plan <app>
   ```

2. 若全部為 PortableSafe，執行安裝：

   ```powershell
   capsulenv app install <app>
   ```

可以用 `<bucket>/<app>` 指定來源 bucket。這是安裝來源，與下一節的已安裝 app selector 用途不同。

若計畫需要人工審核：

```powershell
capsulenv app review <app>
capsulenv app review <app> --raw
```

先檢查 blocker path、來源和腳本，再決定是否執行。`--raw` 展開相依圖中所有來源 manifest；`--json` 提供機器可讀的結果。審核結果不代表腳本已被證明安全。

只有接受第三方腳本與主機修改時，才執行：

```powershell
capsulenv app install <app> --allow-trusted
```

這會交給未修改的 upstream Scoop。直接執行 `scoop install <app>` 具有同樣的信任界線。詳細分類見 [PortableSafe 範圍](ARCHITECTURE.md#package-planner-and-portablesafe-subset)；審核介面呈現見 [CLI-UX](CLI-UX.md#trusted-package-review)。

### Update

更新單一 PortableSafe 套件，或更新所有 Capsulenv 套件：

```powershell
capsulenv app update capsule/<app>
capsulenv app update --all
```

預設先更新 Scoop 與 bucket metadata。加上 `--local` 可使用目前的本地 bucket。`--all` 只更新 Capsulenv 擁有的 PortableSafe 套件。

更新 upstream Scoop app 前，先更新 metadata，再審核：

```powershell
capsulenv bucket update
capsulenv app review scoop/<app>
```

確認接受變更後，使用同一份本地 metadata：

```powershell
capsulenv app update scoop/<app> --allow-trusted --local
```

Review 會比較已安裝與目前 bucket 的相依圖及執行效果。若舊資料不完整，先處理輸出的不確定項目。

### Buckets

```powershell
capsulenv bucket list
capsulenv bucket known
capsulenv bucket add <name> <repository>
capsulenv bucket remove <name>
capsulenv bucket update
```

這些命令使用 upstream Scoop 管理 metadata。`bucket update` 更新 Scoop 與 bucket；它不更新已安裝 app。

## Installed apps

先用 `capsulenv app list` 查可啟動的 app 與 shortcut。

| Selector | 指定對象 |
|---|---|
| `capsule/<app>` | Capsulenv 擁有的 PortableSafe app |
| `scoop/<app>` | upstream Scoop app |
| `scoop:user/<app>` | Scoop user root 中的 app，供同名消歧 |
| `scoop:global/<app>` | Scoop global root 中的 app，供同名消歧 |

省略前綴時，優先選擇 Capsulenv app。同名 app 同時存在兩個 Scoop root 時，指定 Scoop scope。

啟動 app 或具名 shortcut：

```powershell
capsulenv app run capsule/<app>
capsulenv app run scoop/<app> "<shortcut name>"
```

執行 manifest 宣告的 bin，並傳入參數：

```powershell
capsulenv app exec capsule/<app> <bin> -- <arguments>
```

一般外部命令則使用 `capsulenv run <command> <arguments>`。Selector 的內部解析規則見 [ARCHITECTURE](ARCHITECTURE.md#provisioning-and-runtime-separation)。

## Configuration

從 capsule 根目錄執行一次：

```powershell
Copy-Item config\capsulenv.local.psd1.example config\capsulenv.local.psd1
```

若 local config 已存在，直接編輯該檔案。將個人設定寫入 `config/capsulenv.local.psd1`，保留預設檔供更新。

設定欄位與範例以 [local config 範例](../config/capsulenv.local.psd1.example)為準。以下片段應合併到現有的最外層 hashtable，避免重複同名 key。

### Private PowerShell modules

將私人 module 放在 `PowerShell/Modules/`。Capsulenv shell 會將設定的 module root 加入 `PSModulePath`。

在 module 部署腳本中，可使用 `$env:CAPSULENV_MODULE_ROOT` 取得第一個 module root。用 `Environment.ModulePath` 自訂位置。

### Browser

啟動已安裝的 Gecko browser：

```powershell
capsulenv browser capsule/librewolf
capsulenv browser scoop/firefox
```

只有需要借用同一產品的主機 executable 時，才加 `--host`。Profile 仍使用所選 app 的資料。

要讓 Windows 顯示 capsule browser 為預設瀏覽器候選，設定：

```powershell
UserIntegration = @{
    DefaultBrowser = 'scoop/firefox'
}
```

執行 `capsulenv install-user`，再於 Windows Settings 確認預設 app。自訂 Gecko app 的 profile 與參數放在 `Browsers` 設定。

### Bitwarden SSH Agent

先安裝相容的 Bitwarden Desktop。若 app 名稱不同，設定 `Bitwarden.App` 為對應 selector。

```powershell
capsulenv bitwarden setup
capsulenv bitwarden status
capsulenv bitwarden agent-test
```

ShellOnly 使用程序內的 Git SSH 設定。User 模式可套用有備份的持續整合。Capsulenv 不搬移或複製 vault。

還原 Capsulenv 修改的 SSH 整合：

```powershell
capsulenv bitwarden restore
```

設定修改範圍見 [Bitwarden 所有權](ARCHITECTURE.md#bitwarden-ssh-ownership)。

### Lifecycle routines

需要在 capsule 事件發生時呼叫外部工作流程，可設定 `Routines`：

```powershell
Routines = @{
    Network = @{
        Trigger = @('OnEnter', 'OnRehydrate')
        Command = 'powershell.exe'
        Arguments = @('-NoLogo', '-NoProfile', '-Command', "Import-Module NyaModule -Force; Invoke-NyaJob -Name 'portable-network'")
        MinimumIntervalSeconds = 60
        FailurePolicy = 'Warn'
    }
}
```

可用事件為 `OnEnter`、`OnExit`、`OnRehydrate`、`OnEject`。Routine 也可用 `App` 與 `BinName` 指定已安裝 app。

查看狀態或明確執行事件：

```powershell
capsulenv routine list
capsulenv routine run OnEnter Network
```

只有需要略過執行間隔時，才加 `--force`。外部命令可從繼承的 `CAPSULENV_ROOT` 與 `CAPSULENV_LAUNCHER` 取得目前位置。排程、重試與同步方向由外部工作流程管理。

## Tool storage

初始化並查看工具路徑：

```powershell
capsulenv cache init
capsulenv cache paths
```

保存 `tool-data/`，其中可能有全域工具、設定或憑證。清理 `cache/` 前，確認工具沒有把它當成使用中的相依儲存區。各路徑用途見 [TOOLS](TOOLS.md#storage-classes)。

將 Rust 專案的 `target/` 移入登記的快取位置：

```powershell
capsulenv cache link cargo-target D:\src\project --move
capsulenv cache status D:\src\project
```

還原專案內的目錄：

```powershell
capsulenv cache unlink cargo-target D:\src\project --restore
```

只有明確登記的 uv/Pixi workspace 會自動修復。uv 需要 `pyproject.toml` 與 `uv.lock`；Pixi 需要 `pixi.lock` 及專案 manifest。

```powershell
capsulenv tools register uv D:\Portable\capsulenv\workspace\python-app
capsulenv tools register pixi D:\Portable\capsulenv\workspace\science-app
capsulenv tools status
```

停止登記時，使用 `tools unregister <uv|pixi> <workspace>`。連結與修復條件見 [TOOLS](TOOLS.md#project-cache-links)。

## Seed from a host

Seed 是一次性匯入。依需要選擇命令：

| 工作 | 命令 | 前提或結果 |
|---|---|---|
| 匯入 PowerShell 7 profiles | `capsulenv seed powershell` | Capsule 中已有可解析且具 profile persist 的 `pwsh` |
| 匯入 Git global config | `capsulenv seed git` | 預設排除 credential 與 HTTP header |
| 保存 Scoop inventory | `capsulenv seed scoop` | 只保存 apps 與 buckets |
| 備份小狼毫資料 | `capsulenv seed weasel` | 主機已有可確認的正式安裝 |
| 還原小狼毫資料 | `capsulenv seed weasel restore` | 先備份目前的主機資料 |

有既存資料時，先檢查內容；只有接受覆寫時才加 `--force`。

要套用 Scoop inventory，執行 `capsulenv seed scoop --apply`。先確認 `capsulenv status` 顯示的模式：

- ShellOnly 複製來源主機上既存的套件資料。來源必須仍可讀；global app snapshot 需要提升權限。
- User 使用 upstream `scoop import`。這是明確的 TrustedExecution，可能執行套件腳本與主機修改。

篩選、覆寫與備份規則見 [Seed 資料規則](TOOLS.md#one-way-host-seeding)。

## Repair

搬移後直接啟動 capsule。若有警告，先執行：

```powershell
capsulenv status
capsulenv doctor
```

需要明確重跑完整修復時，執行 `capsulenv rehydrate`。

| 問題 | 下一步 |
|---|---|
| 個別 app 連結需要重建 | `capsulenv reset capsule/<app>` 或 `capsulenv reset scoop/<app>` |
| 已登記的專案快取連結失效 | `capsulenv cache repair --strict` |
| 要預覽允許的文字路徑修復 | `capsulenv repair-persist --dry-run` |
| uv/Pixi 搬移修復失敗 | 先用 `capsulenv tools repair all --last --dry-run` 檢查 |
| 確認可重試工具修復 | `capsulenv tools repair all --last --strict` |

`capsulenv reset` 只修復 projection。若診斷表示 Scoop active version 不明確或資料已分歧，先確認要保留的版本與資料。再依診斷明確使用 upstream Scoop 修復或重新安裝。不要刪除 `.capsulenv/` 來消除警告。修復與所有權界限見 [ARCHITECTURE](ARCHITECTURE.md#relocation-projection-repair)。

Pixi global sync 可能重新解析版本。只有接受這個變更時，才使用 `tools repair pixi --last --include-global`。失敗、略過與重試規則見 [TOOLS](TOOLS.md#failure-and-retry)。

## Offline checks

離線前檢查現有環境，並預先下載所需 app 的檔案：

```powershell
capsulenv offline status
capsulenv offline prefetch
capsulenv drift
```

這些命令以本地 Scoop 狀態與 bucket 為準。`offline status` 不保證任意新套件都能離線安裝。`drift` 不會更新網路 metadata。詳細範圍見 [離線快取](TOOLS.md#host-local-scratch-and-offline-cache)。
