[English](README.md) | 繁體中文

# capsulenv

Capsulenv 是一個隨身碟上的可攜式 Windows 開發環境。提供隔離的工作 Shell、套件啟動器、工具快取儲存空間，以及裝置/磁碟代號搬移後的自動修復。

預設的 **ShellOnly** 模式會將環境變數與 PATH 變更限制在 Capsulenv 行程樹內。若需要持久的 Windows 使用者整合，請明確選擇 **User** 模式。

## 安裝與首次啟動

需求環境：Windows PowerShell 5.1。

1. 將 release bundle 解壓縮至暫存目錄。
2. 在該目錄的命令提示字元（Command Prompt）中執行安裝程式：

   ```bat
   install.cmd D:\Portable\capsulenv
   ```

3. 啟動已安裝的膠囊環境：

   ```bat
   D:\Portable\capsulenv\capsulenv.cmd
   ```

首次啟動時會視需要自動 bootstrap 未修改的 upstream Scoop 與 Main bucket。安裝完成後直接啟動即可，無需執行 `init`。

在 Capsulenv PowerShell session 中，使用 `capsulenv` 指令。該指令已綁定到目前的膠囊：

```powershell
capsulenv status
capsulenv help
```

若要從原始碼 checkout 進行安裝，請執行 `scripts\install.cmd <destination>`。開發者專用進入點請參閱 [開發指南](docs/DEVELOPMENT.md#local-development-entrypoint)。

## 選擇 Session 模式

| 模式 | 適用時機 | 影響範圍 |
|---|---|---|
| **ShellOnly**（預設） | 使用他人電腦或保持主機乾淨 | 環境變數與 PATH 僅影響目前的行程樹 |
| **User** | 需要持久的 Windows 使用者整合 | 套用由 Capsulenv 擁有且具備備份、可還原的使用者設定 |

開啟 User shell：

```powershell
capsulenv user-shell
```

離開共用主機前，還原 Capsulenv 使用者整合：

```powershell
capsulenv restore-user
```

全新獨立啟動預設一律為 ShellOnly。關閉 User shell 不會自動還原持久設定。Session 模式與主機離線請參閱 [Session modes](docs/USAGE.zh-TW.md#session-modes)。

## 常見工作

安裝套件前先檢查 plan：

```powershell
capsulenv app plan <app>
capsulenv app install <app>
```

Capsulenv 僅在其完整相依圖均屬於 **PortableSafe** 子集時才會安裝。若 plan 被阻擋，可使用 `capsulenv app review <app>` 檢查原因。

`--allow-trusted` 與直接執行的 `scoop ...` 指令會呼叫未修改的 upstream Scoop。第三方指令碼與主機變更屬於 **TrustedExecution**，不受 Capsulenv 可還原性保證。ShellOnly 模式不會改變此信任界限。

| 工作 | 指令 |
|---|---|
| 查看已安裝套件 | `capsulenv app list` |
| 啟動應用程式 | `capsulenv app run <app>` |
| 更新 PortableSafe 套件 | `capsulenv app update --all` |
| 在膠囊環境中執行指令 | `capsulenv run git status` |
| 查看工具儲存路徑 | `capsulenv cache paths` |
| 診斷問題 | `capsulenv doctor` |
| 查看指令說明 | `capsulenv help app update` |

詳細操作步驟請參閱 [使用指南](docs/USAGE.zh-TW.md)（[English](docs/USAGE.md)）。

## 搬移、更新與移除

移動到其他磁碟代號或電腦後，從新位置啟動 `capsulenv.cmd` 即可。Runtime 會自動修復 projection。若仍有未解決項目，請執行 `doctor` 並依循 [修復流程](docs/USAGE.zh-TW.md#repair)。

若要更新 Capsulenv，請從**新的 release bundle** 執行安裝程式並指向現有的膠囊：

```bat
X:\capsulenv-release\install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd version
```

更新會保留個人設定、套件資料與 workspace。原始碼修改或 Git commit 必須重新部署後才會在安裝後的 runtime 中生效。

永久移除前，請在曾使用過 User 模式的主機上執行 `restore-user`，接著執行 `eject`。確認備份無誤後，即可刪除膠囊目錄。`eject` 會終止膠囊行程並回報未 commit 的 workspace 變更；它不會自動執行 `restore-user`。

## 文件導覽

| 主題 | 文件 |
|---|---|
| 安裝套件、啟動應用程式、設定整合或修復 | [USAGE](docs/USAGE.zh-TW.md)（[English](docs/USAGE.md)） |
| 執行不變量、信任層級與所有權規則 | [ARCHITECTURE](docs/ARCHITECTURE.md) |
| 工具儲存路徑、快取、種子匯入與 uv/Pixi 修復 | [TOOLS](docs/TOOLS.md) |
| 建置 release bundle 與安裝機制 | [DEPLOYMENT](docs/DEPLOYMENT.md) |
| 修改原始碼、執行測試與維護文件 | [DEVELOPMENT](docs/DEVELOPMENT.md) |
| CLI 設計、錯誤提示與 review UX 規範 | [CLI-UX](docs/CLI-UX.md) |
| 舊版本升級操作指南 | [MIGRATION](docs/MIGRATION.md) |

