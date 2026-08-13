# Build and deployment

這份文件是 source checkout -> redistributable runtime -> installed capsule 的 developer/deployment reference。一般使用者第一次安裝與兩種使用模式請從 [`../README.md`](../README.md) 開始；mode ownership 的內部 contract 見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## Runtime build

Development checkout 可直接從 `src/*.ps1` deterministic merge module；正式部署應先產生預建 runtime：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv
```

Minimal runtime 包含 launcher、prebuilt `modules\Capsulenv`、runtime scripts/config、README 與 docs，不需要 `src/`、tests 或 `Merge-ModuleScripts.ps1`。需要 source/tests 的診斷包時才使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv-dev -IncludeDevelopmentFiles
```

Builder 會先清空 output tree，因此拒絕 repository root、repository ancestor，以及不在 `dist/` 下的 source-local output。

## Install or update a destination

最簡入口：

```bat
install.cmd D:\Portable\capsulenv
```

等價 PowerShell invocation：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install-Capsulenv.ps1 -Destination D:\Portable\capsulenv
```

Destination 不可位於 source repository 內；若只想建立 source-local staging tree，使用 build script。

Installer 先在 temporary directory 建立新的 runtime，再以 `.capsulenv-install.json` 的 `ManagedFiles` 作更新邊界。舊 managed files 會先備份，新增/替換採 temporary-file replacement；若 mutation 階段失敗，installer 逆序還原已記錄的 managed files/marker。

Installer 不接管 mutable/user data。以下典型內容跨 update 保留：

```text
scoop/
scoop-global/
cache/
tool-data/
project-cache/
workspace/
PowerShell/Modules/
.capsulenv/
config/capsulenv.local.psd1
```

Destination 中與 install marker 無關的其他檔案同樣不會因正常 update 被刪除。對一個非空、但沒有 `.capsulenv-install.json` 的目錄，必須明確 `-Force` 才採用為 install destination；`-Force` 也不代表刪除未知內容。

## Install mode request

Installer 預設請求 ShellOnly：

```bat
install.cmd D:\Portable\capsulenv
```

要在安裝完成後把 capsule 接管為目前 Windows user 的 Scoop：

```bat
install.cmd D:\Portable\capsulenv -Mode User
```

不帶 `-Mode` 的 update 會讓 runtime 根據目前 machine/user ownership 決定有效模式，而不是把 USB 上「上次在哪台機器使用的 mode」當成全域 profile。詳細判定與 backup contract 只在 [`ARCHITECTURE.md`](ARCHITECTURE.md) 定義。

## Scoop bootstrap during install

正常 Windows install 在 runtime files 到位後初始化 capsule session，確保 capsule-local Scoop config 存在，並在缺少 Scoop/Main 時進行 bootstrap。Bootstrap source/depth 由 `config\capsulenv.psd1` 的 `Scoop.Bootstrap` 控制。

`-SkipScoopBootstrap` 只供 development/offline packaging checks 等已知情境；它不應成為一般 fresh Windows install 的預設。即使略過 bootstrap，installer 仍建立 portable Scoop config boundary，避免之後直接載入 host user config。

Bootstrap implementation 與 host-Git transport boundary 見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## Development-file deployment

`Install-Capsulenv.ps1 -IncludeDevelopmentFiles` 會令 temporary runtime 包含 source/tests/AGENTS/build scripts，再由相同 transactional managed-file mechanism 安裝。這適合需要在 target machine 直接除錯或跑完整 tests 的情境，不是一般 portable runtime 所需。

## Release/update checks

在提交 installer/build 改動前，至少執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

Build/install tests 必須持續驗證：minimal runtime 可直接 import/執行、source-local destructive output guard 有效、重複 update 保留 local config/mutable directories/unmanaged files，以及 failed managed-file mutation 可回滾。
