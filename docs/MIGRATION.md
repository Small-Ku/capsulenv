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
