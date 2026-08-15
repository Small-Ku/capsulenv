# Build and deployment

這份文件是 source checkout -> installable runtime bundle -> installed capsule 的 developer/deployment reference。一般使用者第一次安裝與兩種使用模式請從 [`../README.md`](../README.md) 開始；mode ownership 的內部 contract 見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## Runtime build

Development checkout 可直接從 `src/*.ps1` deterministic merge module；正式部署應先產生預建 runtime：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv
```

Minimal runtime bundle 包含 `install.cmd`／installer、launcher、prebuilt `modules\Capsulenv`、runtime scripts/config、README 與 docs，不需要 `src/`、tests、`Merge-ModuleScripts.ps1` 或 build script。`.capsulenv-runtime.json` schema 2 列出版本、source commit 與完整 `ManagedFiles`，因此 bundle 本身就是 installer payload。需要 source/tests 的診斷包時才使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv-dev -IncludeDevelopmentFiles
```

Builder 會先清空 output tree，因此拒絕 repository root、repository ancestor，以及不在 `dist/` 下的 source-local output。

## Install or update a destination

Source checkout 與 prebuilt bundle 都提供同一入口：

```bat
install.cmd D:\Portable\capsulenv
```

等價 PowerShell invocation：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install-Capsulenv.ps1 -Destination D:\Portable\capsulenv
```

從 source checkout 執行時，installer 先在 temporary directory 呼叫 builder 產生新 runtime；從 prebuilt bundle 執行時，直接驗證 `.capsulenv-runtime.json` schema 2／`ManagedFiles` 並以該 bundle 作 payload，不需要 `src/` 或 build script。Destination 不可等於、位於 installer source 內或成為其 ancestor。

`install.cmd` 的 bootstrap 不信任 PATH 上僅能被 `where.exe` 找到的 `pwsh.exe`：source-local Scoop candidates 與每個 PATH candidate 都必須實際以 `-NoProfile -Command "exit 0"` 成功啟動後才可選用。這使先前 capsule 搬動 drive letter 後殘留的 Scoop shim（例如仍指向舊 `E:\capenv`）不會阻止從另一個 source tree 更新到目前 destination；無可用 PowerShell 7 時才回退到 Windows PowerShell 5.1。

兩條路徑最後都以 `.capsulenv-install.json` 的 `ManagedFiles` 作 update boundary。舊 managed files 會先備份，新增/替換採 temporary-file replacement；若 mutation 階段失敗，installer 逆序還原已記錄的 managed files/marker。成功後 installer 會印出 installed/updated destination 與下一個 `capsulenv.cmd` command。

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

## Release bundle contract

Release artifact 應發佈 `Build-Capsulenv.ps1` 的 minimal output，而不是 source checkout，也不是某個已經使用過、含 mutable data 的 installed capsule。使用者應把 bundle 解壓到 staging directory，再用其中的 installer 寫入長期 portable destination。

更新同理：取得**新版** bundle，從新版 bundle 對既有 destination 再跑 `install.cmd`。Installed capsule 內也有 installer 檔案，是因為它們屬 runtime managed surface；但該 installer 只附帶當前版本 payload，並不自行下載新版本。

`capsulenv.cmd version` 讀取 local runtime metadata；`capsulenv.cmd status` 則在版本之外提供 mode 與本地 readiness 概覽。

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

`Install-Capsulenv.ps1 -IncludeDevelopmentFiles` 從 source checkout 執行時會令 temporary runtime 包含 source/tests/AGENTS/build scripts，再由相同 transactional managed-file mechanism 安裝。Prebuilt minimal bundle 無法憑空加入未打包的 development files；若需要它們，release/build 階段就必須使用 `-IncludeDevelopmentFiles`。這適合需要在 target machine 直接除錯或跑完整 tests 的情境，不是一般 portable runtime 所需。

## Release/update checks

在提交 installer/build 改動前，至少執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

Build/install tests 必須持續驗證：minimal runtime 可直接 import/執行、source-local destructive output guard 有效、重複 update 保留 local config/mutable directories/unmanaged files，以及 failed managed-file mutation 可回滾。
