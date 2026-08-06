# capsulenv

`capsulenv` 把原本單一 `portable-scoop.ps1` 擴展為可模組化、可還原的 Windows portable development capsule。

每次由 `capsulenv.cmd` 啟動時，會先以 `Merge-ModuleScripts.ps1` 合併 `src/*.ps1`，生成 `.build/Capsulenv/Capsulenv.psm1`，再載入模組。執行 `shell` 時會開啟一個繼承 portable 環境的子 PowerShell，因此 `SCOOP`、`XDG_CONFIG_HOME`、`PATH`、Bitwarden app-data 與 SSH socket 在該 shell 內均有效。Scoop config 亦會透過 repo-local `XDG_CONFIG_HOME=data/xdg` 隔離，不會回寫使用者家目錄。

## 目錄

```text
capsulenv.cmd                  Batch 入口
Merge-ModuleScripts.ps1       Deterministic module builder
Capsulenv.psd1                Source module manifest
src/                           PowerShell module sources
config/capsulenv.psd1         Tracked defaults
config/capsulenv.local.psd1   Local override; git-ignored
scoop/                         Portable Scoop root; git-ignored
data/                          Portable app/profile data and XDG config; git-ignored
.capsulenv/                    Reversible-operation backups; git-ignored
.build/                        Generated module; git-ignored
```

## 開始使用

把既有 portable Scoop 目錄放在 repo 根目錄的 `scoop/`，然後執行：

```bat
capsulenv.cmd doctor
capsulenv.cmd init
capsulenv.cmd shell
```

若只想執行一個 command：

```bat
capsulenv.cmd run scoop status
capsulenv.cmd run git status
```

`init` 預設不搬動既有 browser profile。需要複製現有預設 profile 時：

```bat
capsulenv.cmd init copy
```

`move` 會移動原 profile，風險較高，必須先完全關閉 browser：

```bat
capsulenv.cmd init move
```

## Session 與 User 環境

`capsulenv.cmd shell` 只影響新開的子 shell。若確實要把 `SCOOP`、`XDG_CONFIG_HOME`、`PATH`、`BITWARDEN_APPDATA_DIR`、`SSH_AUTH_SOCK` 等寫到 User environment：

```bat
capsulenv.cmd enable-user
capsulenv.cmd restore-user
```

首次 `enable-user` 會把所有即將改動的 User values 精確備份到 `.capsulenv/user-environment-backup.json`。後續 restore 會恢復原值，而不是猜測或只移除 path fragment。

## Bitwarden SSH Agent

capsulenv 會：

1. 把 Bitwarden desktop app-data 指向 `data/bitwarden`。
2. 在 capsule session 設定 `SSH_AUTH_SOCK=\\.\pipe\openssh-ssh-agent`。
3. 可選擇停用與 Bitwarden 競爭同一 Windows named pipe 的原生 `ssh-agent` service。
4. 可選擇令 Git 明確使用 Microsoft OpenSSH。

Bitwarden desktop 內的 **Settings → Enable SSH agent** 仍須由使用者啟用；capsulenv 不會直接改寫 vault/application internal state。

```bat
capsulenv.cmd bitwarden start
capsulenv.cmd bitwarden disable-windows-agent
capsulenv.cmd bitwarden agent-test
capsulenv.cmd bitwarden configure-git
```

停用 Windows service 與改動 global Git config 都會先備份，並可還原：

```bat
capsulenv.cmd bitwarden restore-windows-agent
capsulenv.cmd bitwarden restore-git
```

停用/還原 Windows service 需要 elevated terminal。

## Firefox 與 Zen Browser profiles

Profile data 分別放在：

```text
data/browsers/firefox/profile
data/browsers/zen/profile
```

cache 被導向各自的 `cache/`。`init` 會在 Firefox/Zen 的 `profiles.ini` 註冊名為 `capsulenv` 的 absolute profile，修改前先把原檔保存在 `.capsulenv/browsers/...`。預設不改變一般 Firefox/Zen 啟動所用的 default profile；capsulenv launcher 會明確傳入 portable profile。

Browser launcher 同時使用 Mozilla 的 `--profile <path>`，因此不依賴 installation-specific default profile：

```bat
capsulenv.cmd firefox
capsulenv.cmd zen
firefox-capsulenv.cmd
zen-capsulenv.cmd
```

重新註冊或還原：

```bat
capsulenv.cmd browser configure firefox copy
capsulenv.cmd browser restore firefox
capsulenv.cmd browser configure zen none
capsulenv.cmd browser restore zen
```

還原會恢復 `profiles.ini` / `installs.ini`，並移除 capsulenv 在 `user.js` 寫入的 managed block。`copy` 建立的 portable profile data 會保留；`move` 搬入的 profile 則會連同後續更新移回原位置。

`MakeDefaultProfile` 與 `RegisterInstallDefaults` 均預設為 `$false`，避免 capsulenv 改變一般 browser 啟動或鎖定同一產品的所有 installation。明確啟用後，才會調整 `profiles.ini` default 或既有 `installs.ini` sections。

## 本機設定

複製範例後修改：

```powershell
Copy-Item config\capsulenv.local.psd1.example config\capsulenv.local.psd1
```

Local config 會 recursively merge over tracked defaults，array/scalar 則整項取代。`Environment.PathVariables` 的相對路徑會以 repo root 解算；`Environment.Variables` 則保留為一般字串值。

## 驗證

在 Windows PowerShell 5.1 或 PowerShell 7 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

測試會重新合併 module、載入 manifest、檢查 exports、config 與 CLI help，不會修改 User environment、Git config、Windows service 或真實 browser profiles。
