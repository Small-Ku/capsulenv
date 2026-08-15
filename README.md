# capsulenv

`capsulenv` 是一個可隨 USB／portable disk 搬移的 Windows 開發環境啟動層。它把 Scoop、常用 package manager 的 cache/tool state、私人 PowerShell modules 與 workspace 放在 capsule 內，並在 drive letter、電腦或 Windows user 改變後修復需要重建的連結與工具 metadata。

Capsulenv 不另造一套 app profile store：Scoop app、`persist`、browser profile、shortcut／shim lifecycle 仍由 Scoop 管理。預設的 **ShellOnly** 模式只影響 Capsulenv 開出的 process tree；需要把整台臨時／洗機電腦暫時當成自己的工作環境時，才使用 **User** 模式。

## 快速開始

把 release bundle 解壓到任意暫存目錄，再從 bundle 內安裝到 portable drive：

```bat
install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd
```

Source checkout 也使用同一個 `install.cmd <destination>` 入口。Installer 完成後會直接印出下一個 launcher command。**不需要先跑 `doctor` 或 `init`**；沒有參數的 `capsulenv.cmd` 本身就是 `shell`。

第一次啟動若 capsule 內還沒有 Scoop core／Main，Capsulenv 會自行 bootstrap。這只建立 package-manager 基礎，**不代表 Git、pwsh、uv、Pixi、Node、Rust 等 toolset 已預裝**。全新環境可在 capsule shell 裡按需要安裝，例如：

```powershell
scoop install git pwsh
```

ShellOnly 中的 `scoop` 入口會保持安裝資料、`persist`、shims 在 capsule 內，但不把 Scoop/app PATH 寫入 Windows User/Machine environment，也不建立 Start Menu shortcuts。Manifest 若帶有 `pre_install`／`post_install`／installer 等任意 lifecycle code，只有內容與已審核 fingerprint 完全一致才會執行；未知或已變更的 script 會在 mutation 前停止並印出 fingerprint。不要直接執行 `scoop\apps\scoop\current\bin\scoop.ps1` 來繞過這層 ShellOnly policy。

之後搬到另一個 drive letter 或另一台電腦，直接再執行 `capsulenv.cmd`；shell 啟動會按需要自動 rehydrate。

日常常用入口：

```bat
capsulenv.cmd
capsulenv.cmd run git status
capsulenv.cmd status
capsulenv.cmd version
```

`status` 只讀本地狀態，快速顯示 mode、Scoop app 數量、relocation、managed project links／tool workspaces 與 offline run readiness；深入檢查才使用 `doctor`。命令概覽與分層說明：

```bat
capsulenv.cmd help
capsulenv.cmd help seed
capsulenv.cmd help repair
```

## ShellOnly 與 User

| 模式 | 適合情境 | 對 Windows user 的影響 |
|---|---|---|
| **ShellOnly**（預設） | 私人 Laptop、已有自己環境的電腦 | `SCOOP`、PATH、tool vars 只存在 Capsulenv process tree |
| **User** | 你在一段時間內獨佔、重開機會洗掉狀態的共用電腦 | 把此 capsule 註冊成目前 Windows user 的 Scoop；Capsulenv 會保存可還原的原始 user environment |

ShellOnly 不需要額外設定，直接 `capsulenv.cmd shell`。它也會排除可辨識的 foreign Scoop shims，避免 capsule 缺少某個 command 時意外落到主機 Scoop。

在共用／洗機電腦上，可把以下命令當日常入口：

```bat
capsulenv.cmd user-shell
```

它會在需要時安裝／刷新 User ownership、處理 relocation，然後開 shell。工作完畢可執行：

```bat
capsulenv.cmd eject
```

`eject` 會收尾 capsule-owned process、檢查 `workspace/` 第一層 Git repository 是否 dirty，並清理 host-local scratch。若仍有 capsule-owned process，普通 `eject` 會以 blocked/failure 結束而不宣稱已完成；需要明確終止它們才用 `eject --force`。**`eject` 不會自動撤銷 User mode**，而且 User mode 下會直接提示 integration 仍然有效。真正要把目前 Windows user 還原成接管前狀態時才使用：

```bat
capsulenv.cmd restore-user
```

也可明確切換：

```bat
capsulenv.cmd install-user
capsulenv.cmd restore-user
```

同一支 USB 可以在一台機器保持 ShellOnly，在另一台機器使用 User；mode 是「目前 machine/user 是否由此 capsule 接管」，不是 USB 的永久 profile。

User mode 也可以把 capsule 裡指定的 Gecko browser 註冊成 Windows 的 default-app candidate。這是 opt-in；在 `config/capsulenv.local.psd1` 加入例如：

```powershell
UserIntegration = @{
    DefaultBrowser = 'LibreWolf'
}
```

支援 `Firefox`、`Zen`、`LibreWolf`。下一次 `install-user`／`enable-user`／`user-shell` 會建立 Capsulenv-owned 的 `http`、`https`、`.htm`、`.html` registration，handler 直接綁定 capsule 的實體 Gecko executable 與 Scoop-persisted profile，然後在尚未選中時開啟該 application 的 Windows **Default Apps** 頁。現代 Windows 11 不允許一般程式可靠地靜默覆寫 `http/https` 的 `UserChoice`，所以最後的 **Set default** 仍由使用者在 Settings 確認；Capsulenv 不偽造 association hash。`restore-user` 若發現 Capsulenv browser 仍是 default，會先要求改選另一個 browser，再移除自己精確記錄的 registration。

## 啟動 Scoop GUI app

有 shim／`bin` 的 app 直接在 shell 內執行即可。ShellOnly 不會為 manifest `shortcuts` 建立 Start Menu `.lnk`；只有 shortcut 的 GUI app 可用 Capsulenv launcher：

```bat
capsulenv.cmd app list
capsulenv.cmd app list <app>
capsulenv.cmd app run <app>
capsulenv.cmd app run <app> "<shortcut name>"
capsulenv.cmd app run <app> -- <runtime arguments...>
```

Launcher 讀取**已安裝版本**的 Scoop `manifest.json`／`install.json`，直接啟動 shortcut target，不建立 `.lnk`。同一 app 同時存在 local/global root 時，使用 `user/<app>` 或 `global/<app>` 明確指定。

Firefox、Zen 與 LibreWolf 另有 profile-aware 入口：

```bat
capsulenv.cmd firefox
capsulenv.cmd zen
capsulenv.cmd librewolf
```

它們使用 Scoop `persist` 中的 capsule profile；ShellOnly 會額外避免把請求交給主機既有 browser process。若只想借用這台機器**同一 browser product** 的 Gecko executable，而仍打開 capsule profile，可明示 `--host`，例如 `capsulenv.cmd firefox --host`。Capsulenv 不會自動用 Firefox 代開 LibreWolf/Zen（或反向），亦不會在普通 browser command 中偷偷 fallback 到 host browser。

## 從日用機一次性匯入

`seed` 是一次性 migration，不是持續同步。匯入後 USB 上的 portable state 就是 source of truth：

```bat
capsulenv.cmd seed powershell
capsulenv.cmd seed git
capsulenv.cmd seed scoop
capsulenv.cmd seed weasel
```

`seed powershell` 匯入目前 user 的 PowerShell 7 profiles；**capsule 內必須先已有 Scoop `pwsh`**。`seed git` 匯入 host global Git config，預設排除 credential／HTTP header 等敏感設定。`seed scoop` 先保存 foreign host Scoop 的 apps+buckets inventory。`seed weasel` 只在偵測到正式 machine-installed 小狼毫時，冷備份目前 Rime user data 到 `tool-data/weasel`；要把該備份寫回另一台已安裝小狼毫的 Windows，使用 `capsulenv.cmd seed weasel restore`，Capsulenv 會先保存該 host 的 rollback snapshot。要同時把 Scoop app set 搬進 capsule：

```bat
capsulenv.cmd seed scoop --apply
```

在 **ShellOnly**，`--apply` 不執行 native `scoop import/install`，而是從仍存在的來源 host Scoop 複製已安裝 version state、persist data 與可用 bucket snapshot，再用 portable reset 重建 capsule-owned `current`／shim／persist links；因此不會為了 migration 執行任意 installer/hook 或建立 host shortcut/environment。若 inventory 含 global apps，請用 elevated terminal 執行，且 Capsulenv 會在複製任何 snapshot 前先檢查權限。若只剩 `Scoopfile.json`、原 host app files 已不可讀，ShellOnly 會拒絕假裝能安全重建；回來源機再跑一次，或在明確選擇 User mode 後讓 Scoop 原生 import。

在 **User** mode，`--apply` 使用 Scoop 原生 import，因為該 mode 本來就允許 Scoop 正常建立 current-user integration。已有 portable seed destination 時，capture 要 `--force` 才覆寫；已存在於 capsule 的 app state 不會被 ShellOnly snapshot migration 覆蓋。Git credential／HTTP extra header 只有明確加入 `--include-sensitive` 才會匯入。

## PowerShell 私人 modules

預設私人 module root 是：

```text
PowerShell\Modules\
```

Capsulenv shell 會把它 prepend 到 `PSModulePath`，並把第一個 configured module root 暴露為 `CAPSULENV_MODULE_ROOT`。因此私人 module repository 可在自己的 install script 中優先使用該變數，而不必把 module 複製到 `%USERPROFILE%\Documents\PowerShell\Modules`。

PowerShell executable 與 `$PSHOME` profiles 仍屬 Scoop package／persist。ShellOnly 不會重新載入 host CurrentUser profile；User mode 則保留 PowerShell 正常 profile chain。

## Portable storage

日常判斷「哪些資料可刪、哪些要備份」可按下表：

| 路徑 | 用途 | 建議 |
|---|---|---|
| `scoop/`, `scoop-global/` | Scoop apps、buckets、persist、shims | portable runtime/data；不要當 cache 清除 |
| `PowerShell/Modules/` | 私人 PowerShell modules | user data；更新 Capsulenv 不會刪除 |
| `tool-data/` | Git config、toolchains、global tools、package-manager persistent state | **需要保存**；可能含 token/credential |
| `cache/` | Scoop/uv/Pixi/npm/pnpm/Bun/Go/compiler reusable caches | 原則上可重建；有 linked/virtual-store 模式時優先用 tool-native clean |
| `project-cache/` | 明確登記的 project build/cache backing store | 由 `cache link` 管理 |
| `workspace/` | 建議放 portable source repositories | user data |
| `.capsulenv/` | identity、relocation state、link registry、User backup | Capsulenv 狀態；不要手動當 cache 刪除 |

建立／查看 portable tool storage：

```bat
capsulenv.cmd cache init
capsulenv.cmd cache paths
```

把 Rust `target/` 搬入 capsule 並在原位置建立 managed junction：

```bat
capsulenv.cmd cache link cargo-target D:\src\project --move
capsulenv.cmd cache status D:\src\project
capsulenv.cmd cache unlink cargo-target D:\src\project --restore
```

uv／Pixi workspace 要先登記，Capsulenv 才會在 relocation 時重建它們的 environment：

```bat
capsulenv.cmd tools register uv workspace\python-app
capsulenv.cmd tools register pixi workspace\science-app
capsulenv.cmd tools status
```

完整 storage ownership、cache 例外、uv/Pixi repair 與 project-link safety 見 [`docs/TOOLS.md`](docs/TOOLS.md)。

## Relocation、offline 與 repair

正常搬移後直接開 shell 即可；要明確執行完整修復：

```bat
capsulenv.cmd rehydrate
```

User mode 使用 Scoop 原生 reset 來修復已存在的 user integration；ShellOnly 只重建 capsule-owned `current`／shim／persist links，不 materialize Start Menu shortcut 或 manifest environment。需要手動 reset 時：

```bat
capsulenv.cmd reset
capsulenv.cmd reset <app> [app...]
```

檢查離線可用性、預熱已安裝 apps 的 Scoop download cache、或比較 installed version 與 USB local bucket snapshot：

```bat
capsulenv.cmd offline status
capsulenv.cmd offline prefetch
capsulenv.cmd drift
```

進階 relocation 規則、manifest hook replay 與 persisted-file repair 的 ownership boundary 見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## Bitwarden SSH Agent

Capsulenv 可把 Scoop-installed Bitwarden Desktop 的 SSH Agent 設定接到目前模式：

```bat
capsulenv.cmd bitwarden setup
capsulenv.cmd bitwarden status
capsulenv.cmd bitwarden agent-test
```

ShellOnly 只使用 process-only Git SSH 設定且不改 Windows `ssh-agent` service；User mode 可在有明確權限時建立可還原的 user/global integration。還原 Capsulenv 自己改過的部分：

```bat
capsulenv.cmd bitwarden restore
```

Capsulenv 不複製、重建或重新序列化 Bitwarden vault/app state；更精確的 safety contract 見 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。

## 更新與移除

下載／建立新版 release bundle 後，**從新版 bundle** 對同一個 destination 再執行 installer：

```bat
X:\capsulenv-release\install.cmd D:\Portable\capsulenv
D:\Portable\capsulenv\capsulenv.cmd version
```

Installer 只替換 bundle manifest 列出的 managed runtime files；`scoop/`、`tool-data/`、`cache/`、`workspace/`、`PowerShell/Modules/`、`.capsulenv/`、local config 與其他 unmanaged files 會保留，mutation 失敗時會回滾 runtime replacement。不要用舊 installed capsule 內附的 installer 當成「自動更新器」；它只帶著當時那一版 payload。

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
