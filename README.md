# capsulenv

`capsulenv` 是一個可隨 USB／portable disk 搬移的 Windows 開發環境啟動層。它把 Scoop、常用 package manager 的 cache/tool state、私人 PowerShell modules 與 workspace 放在 capsule 內，並在 drive letter、電腦或 Windows user 改變後修復需要重建的連結與工具 metadata。

Capsulenv 不另造一套 app profile store：Scoop app、`persist`、browser profile、shortcut／shim lifecycle 仍由 Scoop 管理。預設的 **ShellOnly** 模式只影響 Capsulenv 開出的 process tree；需要把整台臨時／洗機電腦暫時當成自己的工作環境時，才使用 **User** 模式。

## 快速開始

把 runtime 安裝到 portable drive：

```bat
install.cmd D:\Portable\capsulenv
cd /d D:\Portable\capsulenv
capsulenv.cmd doctor
capsulenv.cmd init
capsulenv.cmd shell
```

第一次執行時若 capsule 內還沒有 Scoop core／Main，Capsulenv 會自行 bootstrap。之後搬到另一個 drive letter 或另一台電腦，第一次 `shell` 會按需要自動 rehydrate。

日常通常只需要：

```bat
capsulenv.cmd shell
```

在 shell 內直接使用 Scoop、Git、PowerShell、uv、Pixi、npm/pnpm、Bun、Go、Rust/Cargo 等工具即可。只想執行單一命令時可用：

```bat
capsulenv.cmd run scoop status
capsulenv.cmd run git status
```

完整命令列表：

```bat
capsulenv.cmd help
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

`eject` 會收尾 capsule-owned process、檢查 `workspace/` 第一層 Git repository 是否 dirty，並清理 host-local scratch；**它不會自動撤銷 User mode**。真正要把目前 Windows user 還原成接管前狀態時才使用：

```bat
capsulenv.cmd restore-user
```

也可明確切換：

```bat
capsulenv.cmd install-user
capsulenv.cmd restore-user
```

同一支 USB 可以在一台機器保持 ShellOnly，在另一台機器使用 User；mode 是「目前 machine/user 是否由此 capsule 接管」，不是 USB 的永久 profile。

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

Firefox 與 Zen 另有 profile-aware 入口：

```bat
capsulenv.cmd firefox
capsulenv.cmd zen
```

它們使用 Scoop `persist` 中的 capsule profile；ShellOnly 會額外避免把請求交給主機既有 browser process。

## 從日用機一次性匯入

`seed` 是一次性 migration，不是持續同步。匯入後 USB 上的 portable state 就是 source of truth：

```bat
capsulenv.cmd seed powershell
capsulenv.cmd seed git
capsulenv.cmd seed scoop
```

`seed powershell` 匯入目前 user 的 PowerShell 7 profiles；`seed git` 匯入 host global Git config，預設排除 credential／HTTP header 等敏感設定；`seed scoop` 只保存 host Scoop 的 apps+buckets inventory。要在 User mode 套用已保存的 Scoop inventory：

```bat
capsulenv.cmd seed scoop --apply
```

已有 portable destination 時，seed 會要求 `--force` 才覆寫。Git credential／HTTP extra header 只有明確加入 `--include-sensitive` 才會匯入。

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
- [`docs/INSTALL.md`](docs/INSTALL.md)：runtime build、installer/update 與 deployment contract。
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)：source layout、module build、測試與 contributor workflow。
- [`docs/MIGRATION.md`](docs/MIGRATION.md)：舊 portable-scoop/capsulenv 版本升級到目前 ownership model 的必要步驟。
