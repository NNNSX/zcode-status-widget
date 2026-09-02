# GitHub 发布流程

本项目将源码和 Windows 安装器分开发布：源码进入 Git 提交并由 tag 标记，GitHub 会自动生成该 tag 的 Source code ZIP/TAR；安装器、`.blockmap` 和 `SHA256SUMS.txt` 作为同一 Release 的资产上传。

## 发布边界

- Electron 源码：`apps/desktop/`
- 原生 Hook 源码：`apps/hook-helper/ZCodeStatusHook.cs`
- 发布文档：根目录 `README.md`、`CHANGELOG.md` 和本文件
- Release 资产：`artifacts/release-v<version>/` 中的安装器、`.blockmap`、`SHA256SUMS.txt`、`RELEASE_NOTES.md` 和标题文件
- 不发布：`node_modules/`、`out/`、`dist/`、`apps/desktop/artifacts/`、日志、截图、配置、备份、`install-state.json` 和旧 Python 构建产物

## alpha.4 操作顺序

以下命令只在确认工作树中的 Electron 源码和发布文档已审查后执行：

```powershell
cd <workspace>

# 只暂存 Electron 发布相关文件，不要使用 git add -A
# 检查暂存清单后再提交

git add .gitignore README.md CHANGELOG.md docs/releasing.md apps/desktop apps/hook-helper

git diff --cached --check
git diff --cached --stat
git status --short

git commit -m "feat: publish Electron desktop runtime"
git push origin main

git tag -a v0.2.0-alpha.4 -m "ZCode 状态灯 v0.2.0-alpha.4"
git push origin v0.2.0-alpha.4
```

提交前确认未暂存的根目录 Python 修改仍保持未提交状态。若提交后的 SHA 与预期一致，再在 GitHub 创建 `v0.2.0-alpha.4`，标记为 prerelease，并将以下三个文件作为 Release 资产上传：

```text
artifacts/release-v0.2.0-alpha.4/ZCode Status Light Setup 0.2.0-alpha.4.exe
artifacts/release-v0.2.0-alpha.4/ZCode Status Light Setup 0.2.0-alpha.4.exe.blockmap
artifacts/release-v0.2.0-alpha.4/SHA256SUMS.txt
```

Release 正文使用 `artifacts/release-v0.2.0-alpha.4/RELEASE_NOTES.md`，标题使用同目录的 `release-title.txt`。GitHub 自动生成的源码压缩包不需要手工复制到资产目录。

## 发布前验证

在 `apps/desktop/` 执行：

```powershell
npm test -- --run
npm run typecheck
npm run lint
npm run build
npm run dist:win
```

重建安装器后，必须重新计算并更新 `SHA256SUMS.txt`，再从 Release 目录执行：

```powershell
Get-FileHash '.\ZCode Status Light Setup 0.2.0-alpha.4.exe' -Algorithm SHA256
Get-FileHash '.\ZCode Status Light Setup 0.2.0-alpha.4.exe.blockmap' -Algorithm SHA256
```

安装器当前未配置 Authenticode 签名，发布说明必须保留 SmartScreen 可能提示未知发布者的说明。Python `0.1.x` 与 Electron `0.2.0-alpha.4` 共用 `127.0.0.1:57310`，不能同时运行。
