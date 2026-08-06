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
