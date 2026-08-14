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
