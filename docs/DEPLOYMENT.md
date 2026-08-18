# Build and deployment

這份文件是 source checkout -> release bundle -> installed capsule 的 developer/deployment reference。一般使用者流程見 [`../README.md`](../README.md)；runtime ownership 見 [`ARCHITECTURE.md`](ARCHITECTURE.md)。

## Deployment boundary

Installer 只負責**產生／取得 generated module，並 transactional deploy managed program files**。它不是 portable runtime initializer，也不是 host integration tool。

因此 installer 不會 bootstrap Scoop、不會建立 `scoop/`、`cache/`、`workspace/`、`.capsulenv/` 等 mutable state、不會 import installed Capsulenv module，也不會選擇 ShellOnly/User mode。Fresh deployment 完成後第一次執行 destination 的 `capsulenv.cmd`，runtime 才按目前 drive/host 自行 bootstrap/rehydrate；User integration 只由 `user-shell`／`enable-user`／`restore-user` 等顯式 runtime command 管理。

這個分界也意味著：**換 drive letter、搬整個 directory、換電腦不是 install/update。** 已安裝 capsule 應直接從新位置執行 `capsulenv.cmd`，由 runtime relocation logic 處理。

## Build a release bundle

Development checkout 可 deterministic merge `src/*.ps1` 並建立 release bundle：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv
```

Release bundle 是 staging/distribution artifact，包含：

- `install.cmd` + `scripts/Install-Capsulenv.ps1`；
- `capsulenv.cmd`；
- generated `modules/Capsulenv/`，其中 `runtime/` 擁有 control entrypoint 與 Scoop helper resources；
- default config / launch helpers；
- README/docs；
- `.capsulenv-runtime.json` bundle manifest。

它不需要 `src/`、tests 或 module merger。需要診斷 bundle 時才使用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Build-Capsulenv.ps1 -OutputPath dist\capsulenv-dev -IncludeDevelopmentFiles
```

`.capsulenv-runtime.json` schema 3 把兩個 surface 分開：`ManagedFiles` 描述整個 release bundle，供完整性/packaging 使用；`InstallFiles` 才是 installer 寫入 destination 的 managed payload。正常 minimal payload 只含 portable launcher、config/bin helpers 與 `modules/Capsulenv/**`。Installer、README/docs 與 `.capsulenv-runtime.json` 本身留在 staging bundle，不複製到長期 capsule。

Builder 會先清空 output tree，因此拒絕 repository root、repository ancestor，以及不在 `dist/` 下的 source-local output。

## Install or update a destination

Source checkout 與 release bundle 都提供同一入口：

```bat
install.cmd D:\Portable\capsulenv
```

等價 PowerShell invocation：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Install-Capsulenv.ps1 -Destination D:\Portable\capsulenv
```

從 source checkout 執行時，installer 在 temporary directory 呼叫 builder，取得 generated module + `InstallFiles`；從 release bundle 執行時，驗證 `.capsulenv-runtime.json`，schema 3 使用 `InstallFiles`。為遷移舊 release，schema 2 bundle 仍可使用其 `ManagedFiles` 作 legacy payload。Destination 不可等於、位於 installer source 內或成為其 ancestor。

Destination 的 `.capsulenv-install.json` 是 update ownership boundary。舊 managed files 會先備份；已不屬新 `InstallFiles` 的舊 runtime files會移除；新增/替換採 temporary-file replacement。若 mutation 失敗，installer 逆序還原 managed files 與 marker。這也讓從舊版升級時，曾經安裝到 root 的 `scripts/` runtime helpers、bundle docs/installer metadata 能退出 installed surface，而不碰 unmanaged data。

Installer 不接管以下 mutable/user data：

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

Destination 中與 install marker 無關的其他檔案同樣保留。對非空、但沒有 `.capsulenv-install.json` 的目錄，必須明確 `-Force` 才採用；`-Force` 也不代表刪除未知內容。

## Runtime artifact contract

`capsulenv.cmd` 優先啟動 `modules\Capsulenv\runtime\Invoke-Capsulenv.ps1`。因此 deployed capsule 的 control/runtime code 由同一個 generated module package 擁有，不依賴 root `scripts/`、README/docs、`.capsulenv-runtime.json` 或 source compiler。

Development checkout 則可 fallback 到 source `module-runtime/Invoke-Capsulenv.ps1`；若 `src/`、`Capsulenv.psd1` 與 `Merge-ModuleScripts.ps1` 同時存在，entrypoint 每次從 source clean-merge `.build/Capsulenv`，避免 stale generated module shadow source changes。

在 deployed capsule 設 `CAPSULENV_FORCE_REBUILD=1` 不會嘗試現場 compile，也不會讓 capsule 失去啟動能力；它只提示應從 development checkout 或新版 release bundle deploy 新 generated module。

`install.cmd` 與 installed `capsulenv.cmd` 都固定以 **Windows PowerShell 5.1** 作 control host。Control bootstrap 只用 PowerShell language/.NET 把 `$PSHOME\Modules` 恢復到 inherited `PSModulePath` 最前，不 import/probe Utility 等 built-in modules；Capsulenv `.psd1` 由 module 內建的 safe AST data-file reader 處理。Interactive `shell`/`user-shell` 完成 activation 後才啟動 capsule Scoop 的 PowerShell 7。

## Release/update workflow

Release artifact 應是 `Build-Capsulenv.ps1` output，而不是 source checkout，也不是含 mutable data 的 installed capsule。更新既有 capsule時，取得新版 checkout/bundle，從**外部 staging/source directory**對相同 destination 再跑 installer：

```bat
X:\capsulenv-release\install.cmd F:\capenv
F:\capenv\capsulenv.cmd version
```

Installed capsule 本身故意不再帶 installer。這使「deployment source」與「portable destination」明確分離；destination 只需要能啟動、自行 relocation/rehydrate 的 runtime package。

若只是：

```text
E:\capenv -> F:\capenv
old PC      -> new PC
```

不要跑 installer。直接執行 `F:\capenv\capsulenv.cmd`。

## Development-file deployment

`Install-Capsulenv.ps1 -IncludeDevelopmentFiles` 從 source checkout 執行時會讓 temporary build 的 development source/tests 也列入 `InstallFiles`；prebuilt bundle 必須本身以 `Build-Capsulenv.ps1 -IncludeDevelopmentFiles` 建立才有這些檔案。此模式只供 target-machine debugging，不是正常 portable runtime contract。

## Release/update checks

提交 build/installer/runtime packaging 改動前，執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Test-Capsulenv.ps1
```

Tests 必須持續驗證：release bundle 與 destination payload 分離、installed runtime 不依賴 bundle metadata/root scripts、舊 managed runtime 可退出 installed surface、update 保留 local config/mutable directories/unmanaged files，以及 failed mutation 可 rollback。
