# 遷移到 Scoop-owned data model

## 從 portable-scoop.ps1 遷移

舊 `Session`：

```bat
capsulenv.cmd shell
```

舊 `EnableUser` / `RestoreUser`：

```bat
capsulenv.cmd enable-user
capsulenv.cmd restore-user
```

舊腳本只做 `scoop reset *`。新版在搬移後會：

1. 設定 portable `SCOOP`、`SCOOP_GLOBAL` 與 shims PATH。
2. 執行原生 `scoop reset *`，由 Scoop 重建 `current`、shims、shortcuts、environment 與 `persist` links。
3. 按 allow-list 重放 installed manifest 的安全 hook。
4. 以舊 relocation state（或 stale Scoop `.shim`）推斷 OldRoot，交易式修復 allow-listed persisted UTF text／JSON。
5. 全部成功後才保存新的 relocation fingerprint。

## 從 capsulenv v0.1.0 遷移

v0.1.0 曾建立 repo-local：

```text
data/bitwarden
data/browsers/firefox/profile
data/browsers/zen/profile
data/xdg
```

v0.2.0 不再讀寫這些路徑，也不會自動刪除它們。先確認資料已按你所用 manifest 合併到相應 Scoop persist store，例如：

```text
scoop/persist/bitwarden/bitwarden-appdata
scoop/persist/firefox/profile
scoop/persist/zen-browser/profile
```

實際名稱以已安裝 app 的 `manifest.json` 中 `persist` 欄位為準。確認後可自行刪除舊 `data/`。

原本由 v0.1.0 修改的 browser `profiles.ini`／`user.js`，應先用 v0.1.0 的 `browser restore` 還原，再切換到 v0.2.0。v0.2.0 不會繼續管理那些 backup。

## Hook 安全性

`post_install` 常用於依目前 absolute path 重新註冊 application integration，適合有選擇地重放。

`pre_install` 常包含 installer rename、首次資料複製或檔案 transformation。它不保證冪等，因此只可透過明確 command 重放：

```bat
capsulenv.cmd hooks pre_install app-name
```

自動配置中只加入已審視且確定可重入的 hooks。

## 從 capsulenv v0.4.0 遷移到 v0.5.0

v0.5.0 將配置 schema 升至 3，新增 `Scoop.RelocationRepairs`。內建規則只涵蓋 `firefox`、`firefox-esr`、`zen-browser` 的明確 profile/distribution text files；不會遞迴掃描 `persist`，Bitwarden 亦不在通用規則中。

首次以 v0.5.0 在已搬移的 capsule 上執行時：

```bat
capsulenv.cmd doctor
capsulenv.cmd repair-persist --dry-run
capsulenv.cmd rehydrate
```

若不希望套用內建規則，在 `config/capsulenv.local.psd1` 加入：

```powershell
@{
    Scoop = @{
        RelocationRepairs = @{}
    }
}
```

`RelocationRepairs` 是 allow-list，local value 會整個取代預設 map。自訂規則必須使用 app persist root 內的相對檔案路徑；wildcard、recursive scan 與 binary format 均不支援。

若舊 `.capsulenv/scoop-rehydration.json` 沒有隨 capsule 搬移，請在第一次 `scoop reset` 前執行 capsulenv。v0.5.0 可由 stale `.shim` absolute targets 推斷舊 Scoop root；一旦先由其他方式 reset shims，這項 fallback evidence 便可能消失。

完成後可重用最後一次 context：

```bat
capsulenv.cmd repair-persist --last --dry-run
capsulenv.cmd repair-persist --last firefox
```

## v0.6.0

v0.6.0 將配置 schema 升至 4，新增 `ToolStorage`。uv、Pixi、rustup/Cargo、sccache、ccache 的 cache/home 會透過各自環境變數解析到 capsule 內；Scoop download cache 仍由 `scoop\cache` 原生擁有。`enable-user` 的原始環境備份亦會涵蓋這些變數。

若已在舊版執行過 `enable-user`，使用以下命令延伸原 backup 並套用新工具變數；原本已備份的值不會被覆寫：

```bat
capsulenv.cmd enable-user --force
```

新增 `cache link` profile framework。預設 `cargo-target` 可把 repository 的 `target\` 搬入 `project-cache\<project-id>\` 並在原位置建立 junction。Directory profile 不接受 hardlink；file hardlink 會以 Windows volume/file identity 驗證。推薦把 portable source 放在 `workspace\`，讓 project ID 在整個 capsule 搬移後保持穩定。

受管 link 會記錄在 `.capsulenv/project-cache-links.json`。由於 Windows junction／absolute symlink 保存 absolute target，整個 capsule 搬位後 `shell`／`init` 會只對 registry 可驗證的 stale target 自動重接；普通 path 與不相符的 link 不會被替換。可手動檢查：

```bat
capsulenv.cmd cache repair
capsulenv.cmd cache repair --strict
```

另外新增 `Build-Capsulenv.ps1`、`Install-Capsulenv.ps1` 與 `install.cmd`。安裝版直接載入 `modules\Capsulenv` 中的 deterministic merged module；更新只管理 `.capsulenv-install.json` 列出的 runtime files，保留 Scoop、cache、tool data、workspace、local config 與未知檔案，失敗時回滾已修改的 managed files。


## v0.7.0

v0.7.0 將配置 schema 升至 5，新增 tool-native relocation repair。uv managed Python、uv global tool environment、Pixi global trampoline，以及 project workspace environment 不能只靠重接 junction 修復；capsulenv 現在交回 uv/Pixi 原生命令重建。

uv managed Python 會按 `uv python list` 回報的既有 installation key 逐一重裝；global tool 則從 receipt 與環境取得原始安裝意圖和當前版本，不會因 relocation 自動升級。

Project environment 必須先明確登記：

```bat
capsulenv.cmd tools register uv workspace\python-app
capsulenv.cmd tools register pixi workspace\science-app
capsulenv.cmd tools status
```

只有具 `uv.lock` 或 `pixi.lock` 的登記 workspace 會自動重建。uv 會先交易式備份原環境，以 `uv venv --relocatable` 重建，再執行 `uv sync --locked --reinstall`；舊版 uv 沒有 `--relocatable` 時會退回完整重建後 locked sync。`UV_PROJECT_ENVIRONMENT` 只接受 workspace 或 capsulenv root 內的路徑，避免誤刪外部／系統環境。Pixi 使用 `pixi reinstall --all --locked`。Registry 位於 `.capsulenv/tool-workspaces.json`，capsule 內 workspace 與 uv environment 均以相對 reference 保存。

Pixi global manifest 沒有由 capsulenv 可依賴的 lock file，而且 dependency 可使用版本範圍，因此 `pixi global sync` 預設不會在 relocation 中自動執行。明確接受重新解析時使用：

```bat
capsulenv.cmd tools repair pixi --last --include-global
```

或在 local config 將 `ToolStorage.Relocation.Pixi.RepairGlobal` 設為 `$true`。完整說明見 `docs/TOOLS.md`。

## v0.7.2

v0.7.2 將 build/install 驗證改為真正由 PowerShell runtime 執行，而不再只依賴文字級 parser 檢查。修正 StrictMode 下未初始化 `$LASTEXITCODE`、CRLF export marker 未被 module merger 收集，以及 PowerShell 7.6 對 generic `List<T>` 直接 `@(...)` 展開可能觸發 binder 例外的問題。

`Test-Capsulenv.ps1` 現在會額外實際執行 runtime build、首次 install、重複 update、prebuilt module import 與 installed entrypoint smoke test；更新測試亦驗證 local config、cache 與未知 destination files 不會被 installer 覆寫。

## v0.8.0 portable PowerShell module root

配置 schema 升至 6。`Environment.ModulePath` 預設為 `PowerShell\Modules`；所有項目會在 capsulenv session 中 prepend 到 `PSModulePath`，第一項另外暴露為 `CAPSULENV_MODULE_ROOT`。`CAPSULENV_MODULE_ROOT` 會納入 `enable-user` 的 reversible backup，但 `PSModulePath` 刻意不寫入 User scope，以保留 PowerShell 5.1／7 各自的預設 module-path construction。Capsulenv installer 只建立 module root，不管理其中內容，因此私人 modules 可跟 capsule 一起搬移及跨 capsulenv 更新保留。


## v0.8.1 Scoop lifecycle replay argument binding

Scoop custom commands are dispatched by collecting trailing CLI tokens into a `string[]` and array-splatting that array into `scoop-<command>.ps1`. PowerShell array splatting binds those values positionally; a string value such as `-Hook` is not reinterpreted as a named parameter token. Earlier capsulenv releases therefore invoked the temporary lifecycle replay command with an empty mandatory `Hook` parameter during `init`/`rehydrate`.

v0.8.1 makes the replay protocol explicitly positional: `scoop <temporary-command> post_install <app...>`. The runner binds `Hook` at position 0 and the remaining app names from position 1 onward. Regression coverage executes the replay runner through the same `string[]` array-splat semantics used by Scoop.

## v0.9.0 self-bootstrap and installation modes

v0.9.0 將配置 schema 升至 7，加入 `Scoop.Bootstrap`。Capsulenv 不再要求 source/release 以 submodule 或預先複製的方式攜帶 Scoop；fresh capsule 缺少 Scoop core／Main 時會優先以 shallow single-branch Git clone 建立 live repository，Git 不可用或 clone 失敗時再使用 archive fallback。`scoop\config.json` 會在第一次載入 Scoop 前建立，隔離 `%USERPROFILE%\.config\scoop\config.json`。

安裝 ownership 現在明確分成兩個 mode：

```bat
install.cmd D:\Portable\capsulenv              rem ShellOnly，預設
install.cmd D:\Portable\capsulenv -Mode User   rem 註冊為目前 user 的 Scoop
```

`ShellOnly` 的 Capsulenv activation/bootstrap 只改 process scope 並只管理 capsule 內的 Scoop，不接管 host Scoop。`User` mode 延續舊 `enable-user` 的 reversible backup contract；主要命令改為 `capsulenv.cmd install-user`，而 `enable-user` 仍可使用。`restore-user` 精確還原原 User environment 並回到 ShellOnly。

升級 v0.8.x 時不需要先 restore：若 `.capsulenv\user-environment-backup.json` 已存在，v0.9.0 會把既有安裝推斷為 User mode；沒有 backup 的既有／fresh installation 則視為 ShellOnly。之後不帶 `-Mode` 重跑 installer 會保留目前 mode，避免 update 意外改變 machine-user ownership。
