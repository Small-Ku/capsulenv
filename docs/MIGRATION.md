# 從 portable-scoop.ps1 遷移

舊腳本的 `Session` 對應：

```bat
capsulenv.cmd shell
```

舊腳本的 `EnableUser` / `RestoreUser` 對應：

```bat
capsulenv.cmd enable-user
capsulenv.cmd restore-user
```

主要差異：

- 舊 `Session` 在獨立 PowerShell process 結束後即失效；capsulenv 會保留一個繼承環境的 child shell。
- 舊 backup 只保存 `SCOOP` 與 `PATH`；capsulenv 會按實際 plan 保存每個改動值與「原本不存在」狀態。
- Scoop config 亦經 `XDG_CONFIG_HOME` 隔離到 `data/xdg/`，避免 portable Scoop 仍使用 `%USERPROFILE%\.config`。
- 舊腳本無條件把 `SSH_AUTH_SOCK` 寫入 User scope；capsulenv 預設只在 capsule session 設定，持久寫入必須明確執行 `enable-user`。
- Bitwarden service、Git config、Firefox/Zen registry files 各自有獨立且可還原的 backup。
