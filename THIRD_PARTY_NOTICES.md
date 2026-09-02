# 第三方组件声明

当前公开版本使用 Electron、TypeScript、Vite、Vitest、ESLint 和 Electron Builder 构建 Windows 桌面应用，并使用 lucide 提供界面图标。原生 Hook 助手由 `apps/hook-helper/ZCodeStatusHook.cs` 编译，不依赖外部 Python 运行时。

| 组件 | 用途 | 许可证 |
|---|---|---|
| [Electron](https://www.electronjs.org/) | Windows 桌面运行时 | MIT |
| [Vite](https://vite.dev/) | Renderer 构建工具 | MIT |
| [TypeScript](https://www.typescriptlang.org/) | 类型检查与编译 | Apache-2.0 |
| [Vitest](https://vitest.dev/) | 自动化测试 | MIT |
| [ESLint](https://eslint.org/) | 静态检查 | MIT |
| [Electron Builder](https://www.electron.build/) | Windows NSIS 安装器构建 | MIT |
| [lucide](https://lucide.dev/) | 界面图标 | ISC |

实际依赖版本和传递依赖以 `apps/desktop/package-lock.json` 为准。各组件的完整许可证文本、适用条件和源代码获取方式以其上游发布包为准。
