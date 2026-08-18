# Migration guide

這份文件只記錄**升級時需要做的事**。目前行為不要從舊 release notes 推斷；請以 [`../README.md`](../README.md)、[`ARCHITECTURE.md`](ARCHITECTURE.md) 與 [`TOOLS.md`](TOOLS.md) 為準。

## 從 `portable-scoop.ps1` 遷移

舊 session 入口可直接改成：

```bat
capsulenv.cmd shell
```

舊 `EnableUser` / `RestoreUser` 對應：

```bat
capsulenv.cmd install-user
capsulenv.cmd restore-user
```

`enable-user` 目前仍保留 compatibility alias，但新文件與腳本應使用 `install-user`。

不要把舊腳本「永遠 `scoop reset *`」的假設搬過來。現在 ShellOnly/User 的 reset 與 hook semantics 不同；若你曾依賴某個 manifest `pre_install`/`post_install` 在每次搬移都被執行，先審核它是否安全，再放入 `Scoop.ReplayHooks` 或於 User mode 明確執行 `capsulenv.cmd hooks ...`。詳見 [`ARCHITECTURE.md`](ARCHITECTURE.md#relocation-lifecycle)。

## 從 v0.1.x 的平行 `data/` model 遷移

早期版本曾建立：

```text
data/bitwarden
data/browsers/firefox/profile
data/browsers/zen/profile
data/xdg
```

目前版本完全不讀寫這些路徑，也不會自動刪除。先依**已安裝 app** 的 `manifest.json` `persist` 欄位確認資料已合併到相應 Scoop persist store，例如 `scoop/persist/bitwarden/...`、`scoop/persist/firefox/profile`、`scoop/persist/zen-browser/profile`；確認後才手動刪除舊 `data/`。

如果 v0.1.x 曾直接修改 host browser `profiles.ini`／`user.js` 並保留舊版 restore 能力，應在淘汰舊版前先用舊版 restore 還原。新版本不接管那套舊 backup。

## 從 v0.4.x / v0.5.x persisted repair 遷移

自 v0.5 起，relocation path repair 改成 `Scoop.RelocationRepairs` 明確 allow-list，而不是掃描整個 persist。升級一個已經換過 drive letter、但尚未由新版 rehydrate 的 capsule 時，可先預覽：

```bat
capsulenv.cmd doctor
capsulenv.cmd repair-persist --dry-run
capsulenv.cmd rehydrate
```

如果你不接受任何 built-in persisted-file rewrite，在 `config/capsulenv.local.psd1` 明確設：

```powershell
@{
    Scoop = @{
        RelocationRepairs = @{}
    }
}
```

Local `RelocationRepairs` 是整個 allow-list replacement，不是逐 app recursive merge。

## 從 v0.6/v0.7 tool storage 遷移

這些版本開始把 uv/Pixi/npm/pnpm/Bun/Go/Rust/compiler tool state 與 caches 導入 `tool-data/`/`cache/`，並加入 explicit project-cache links/native uv-Pixi repair。

舊 capsule 若仍有自己手工設定的環境變數或 cache paths，先用：

```bat
capsulenv.cmd cache paths
capsulenv.cmd tools status
```

確認目前 canonical path，再把必要的 persistent data 搬入 `tool-data/`。不要把整個舊 `CARGO_HOME`、package-manager global state 或 config 當作 disposable cache。完整分類見 [`TOOLS.md`](TOOLS.md)。

早期已建立 project-cache junction/symlink 的 repository，應保留 `.capsulenv/project-cache-links.json` 與 backing store，然後執行：

```bat
capsulenv.cmd cache repair
```

uv/Pixi project environment 不會被全盤自動發現；需要 relocation repair 的 lock-backed workspace 請明確 `tools register`。

## 從 v0.8.x portable PowerShell module root 遷移

私人 modules 現在應放到預設 `PowerShell/Modules/`（或 `Environment.ModulePath` 自訂位置）。在 Capsulenv shell 內，第一個 module root 會以 `CAPSULENV_MODULE_ROOT` 暴露。

若你的私人 module build script 仍硬編碼 `%USERPROFILE%\Documents\PowerShell\Modules`，建議改成：顯式 `-InstallRoot` > `$env:CAPSULENV_MODULE_ROOT` > 原生 Documents fallback。Capsulenv 不會自動複製 host module directories。

## 從 v0.9.x install-mode state 遷移

v0.9 引入 ShellOnly/User，但較早的實作曾把 mode/backup 看成接近 capsule-global state。現在 ownership 是 machine/user scoped，backup/ledger 位於：

```text
.capsulenv/user-integrations/<machine-user-hash>/
```

舊 `.capsulenv/user-environment-backup.json`／`install-mode.json` 不應手工複製到另一台主機來宣告 User ownership。Runtime 只會在能證明目前 Windows user 正在使用該 capsule integration 時遷移 legacy state。

在 reset-on-shutdown 共用電腦上，重開機後直接重新執行：

```bat
capsulenv.cmd user-shell
```

不需要先用舊 ledger `restore-user`；Capsulenv 會從當前乾淨 User environment 建立新的 host-scoped backup。

## 從 v0.10.x storage ownership 遷移

Scoop download cache 的 canonical location 是頂層 `cache/scoop`，Git global config、uv/Pixi config、npm user config 等 persistent config 位於 `tool-data/`。如果舊 local config 仍把它們指到過時路徑，先以 `config/capsulenv.local.psd1.example` 與 `capsulenv.cmd cache paths` 對照後移除不必要 override。

Capsulenv 不再用 session-wide `XDG_CONFIG_HOME` 強行捕捉 pnpm/Bun 的所有 global config。若舊 workflow 依賴那個 side effect，請改用 package manager 支援的 portable variables/project-local config，而不是把 XDG override 重新加回全 session。

## 從 v0.12.x PowerShell profile isolation / seed 遷移

PowerShell executable 與 `$PSHOME` profiles 仍由 Scoop package/persist 管理；ShellOnly 不再讓 host CurrentUser profiles 在隔離完成後自動執行。

如果你過去靠 host PowerShell profile 自動注入 aliases/modules/config，請把真正要 portable 的 profile 一次性 seed 到 capsule：

```bat
capsulenv.cmd seed powershell
```

私人 module 本體仍應部署到 `PowerShell/Modules/`。若需要把 host Git/Scoop inventory 也轉成 USB-owned source of truth，可分別執行 `seed git` / `seed scoop`。Seed 不是雙向同步；詳細 filtering/overwrite semantics 見 [`TOOLS.md`](TOOLS.md#one-way-host-seeding)。

## 從 v0.14.x app preset/path candidates 遷移

v0.15 把 browser、Bitwarden、sing-box，以及 Scoop-installed uv/Pixi 的 executable identity 統一到 installed Scoop app selector。Runtime 讀 selected app 的 installed `manifest.json`／`install.json`，不再靠一組 `scoop\apps\...\current` candidates 猜是哪一個 package。

舊 `UserIntegration.DefaultBrowser = 'Firefox'`／`'LibreWolf'` 仍能按 app 名匹配；但舊 `Firefox` preset 曾順帶 fallback 到 `firefox-esr`，v0.15 不再跨 manifest 猜 package，若實際安裝 ESR 請指定 `firefox-esr`。舊 `Zen` preset 同樣應改成實際 manifest selector：

```powershell
@{
    UserIntegration = @{ DefaultBrowser = 'zen-browser' }
}
```

若 local config 曾覆寫 `Bitwarden.ExecutableCandidates`，改為 `Bitwarden.App`，並按需要指定 `ShortcutName`／`BinName`／`ExecutablePath`；persisted `data.json` 仍留在該 Scoop app 的 persist root，不要搬到 Capsulenv 自建資料夾。自訂 Gecko manifest 則加入一個 `Browsers` entry，至少指定 `App`、`ProfilePath`、`ProfileArgument`，interactive executable 可由 manifest 唯一 `bin` 自動解出或以 `BinName`／`ExecutablePath` 消歧。只有當 manifest 公開的是不適合 Windows running-instance URL delegation 的 portable wrapper 時，才另設 app-relative `DefaultExecutablePath`；profile storage 仍不另建副本。

`Scoop.ReplayHooks`、`Scoop.RelocationRepairs` 與 reset 現在也接受 `user/<app>`／`global/<app>`。只有在同名 app 同時存在兩個 root 或 rule 本身必須精確限制 scope 時才需要加 prefix；無 scope 的既有設定仍保留原有語義。

## 從 v0.15.0–v0.15.5 source-only 更新遷移

若曾把 Git/source 增量 patch 套到一個 minimal installed capsule，卻沒有用新版 runtime bundle installer 更新 `modules/Capsulenv`，可能會出現「source 已修，但 `capsulenv.cmd` 仍執行舊行為」。Minimal runtime 故意不攜帶 `src/`／module compiler，不能靠 `CAPSULENV_FORCE_REBUILD=1` 在現場把 module 重新 merge。

升級到 v0.15.6 時，請把新版 runtime bundle 解壓到 capsule **外部** staging directory，再執行：

```bat
X:\capsulenv-0.15.6\install.cmd F:\capenv
F:\capenv\capsulenv.cmd version
```

這會 transactional replacement managed runtime，包括 prebuilt `modules/Capsulenv`，並保留 Scoop/persist/local config/workspace 等 mutable state。Development checkout 則相反：launcher 現在每次從 source merge，不再讓殘留 prebuilt module shadow 新 source。

Windows default-browser detection 也不再只讀 legacy `UserChoice`；v0.15.6 以 Shell effective association 為準，因此 Windows 11 使用 rotated `UserChoiceLatest` 的 host 不會再被誤判。

### v0.15.7：修復已追蹤但仍殘留舊 command 的 default-browser registration

若曾使用 v0.15.3 或更早版本註冊 Capsulenv Gecko browser，registry 中可能仍保留含 `-osint` 或直接指向 `scoop\persist` profile target 的舊 `shell\open\command`。Windows 可以繼續把該 ProgID 視為 effective default，但 Gecko 會在收到不合法的 `-profile ... -osint -url ...` 組合時立即退出。

v0.15.7 起，只要 User integration state 仍追蹤該 browser registration，普通 User-mode activation 與 `install-user --force` 都會原地刷新 Capsulenv 自己擁有的 ProgID，即使目前 `UserIntegration.DefaultBrowser` 已留空。留空只會停止 Default Apps 提示，不會阻止 runtime upgrade 修復既有 registration。更新後可用 `capsulenv.cmd doctor` 直接比較 tracked URL handler 的 actual/expected command；不應再需要用 ProcMon 才能確認是否仍在執行舊 handler。

### v0.15.8：control host 隔離 built-in PowerShell modules

若從 Capsulenv interactive shell 再執行 `capsulenv.cmd` 時遇到 `Import-PowerShellDataFile` 無法辨識，請直接用 v0.15.8 或更新的 **外部 runtime bundle** 覆蓋 managed runtime，而不要在故障中的 capsule 內嘗試 `CAPSULENV_FORCE_REBUILD`：

```bat
X:\capsulenv-0.15.8\install.cmd E:\capenv
E:\capenv\capsulenv.cmd version
```

v0.15.8 的 control entrypoint 會先以 `$PSHOME/Modules` 隔離並載入 Windows PowerShell 自己的 built-in Utility module，因此從 portable/private `PSModulePath` 繼承回來的 module 不再能 shadow control plane；batch launcher 也明確拒絕 Windows PowerShell 5.0。這只改 managed runtime/bootstrap，不移動 Scoop apps、persist、workspace 或 local config。


### v0.16.0：deployment 與 portable relocation 分離

v0.16.0 把 release bundle 與 installed capsule 的 ownership 明確拆開。Release bundle 的 `.capsulenv-runtime.json` schema 3 同時列出完整 `ManagedFiles` 與 destination-only `InstallFiles`；正常安裝只把 `capsulenv.cmd`、config/bin helpers 與 generated `modules/Capsulenv/**` 寫到長期 capsule。Installer、README/docs 與 bundle metadata 留在 staging directory。

更新自 v0.15.x 時仍從新版 development checkout／release bundle 對既有 destination 執行一次 installer。新版 install marker 會把舊版本曾管理的 root `scripts/` helper、installed installer/docs/runtime metadata 從 managed surface 移除，同時保留 Scoop/persist/cache/workspace/private modules/local config 等 mutable data。

完成這次程式更新後，日常 relocation 不再與 installer 有任何關係。例如把 `E:\capenv` 整個搬到 `F:\capenv` 或插到另一台 Windows，只需：

```bat
F:\capenv\capsulenv.cmd
```

Installed launcher 直接進 `modules\Capsulenv\runtime\Invoke-Capsulenv.ps1`；gateway/reset/replay/policy/control-host bootstrap 也都由同一 module package 擁有。`.capsulenv-runtime.json` 缺席不影響啟動。`CAPSULENV_FORCE_REBUILD=1` 在 deployed runtime 只會提示從 development checkout／新版 bundle 更新 generated module，不再嘗試依靠 installed source/compiler 自救。

Installer 自 v0.16.0 起也不再 bootstrap Scoop、建立 mutable directories、import installed module 或切換 ShellOnly/User。Fresh deploy 後第一次 `capsulenv.cmd` 自己完成必要 bootstrap/rehydrate；User integration 仍以 runtime commands 顯式管理。


## 升級後驗證

完成任何跨代 migration 後建議：

```bat
capsulenv.cmd doctor
capsulenv.cmd cache paths
capsulenv.cmd tools status
capsulenv.cmd offline status
```

若 capsule 剛換過 path/drive，再執行一次 `capsulenv.cmd rehydrate`。不要為了「清乾淨」而先手動刪 `.capsulenv/`：identity、上一個 relocation context、User backup 和 link registries 正是新版用來安全判斷 ownership 的證據。

## ShellOnly Scoop host-state cleanup (0.14.1)

Older Capsulenv builds exposed Scoop's raw shim in ShellOnly. A direct `scoop install/update/reset/shim` could therefore let upstream Scoop persist capsule paths into the Windows User PATH and create `Scoop Apps` Start Menu shortcuts. 0.14.1 routes those commands through the ShellOnly Scoop gateway, but it does **not** blindly delete historical host state during upgrade because Capsulenv cannot prove that every existing shortcut or user variable was created by the old bug.

After upgrading, inspect User PATH for entries under the current capsule root and remove only entries that actually point into this capsule. Likewise remove only Start Menu `.lnk` files whose resolved target is under the capsule. Existing `scoop/apps`, `scoop/persist`, shims and installed manifests do not need to be deleted or reinstalled. See the ShellOnly Scoop command gateway section in [`ARCHITECTURE.md`](ARCHITECTURE.md#shellonly-scoop-command-gateway) for the new behavior.
