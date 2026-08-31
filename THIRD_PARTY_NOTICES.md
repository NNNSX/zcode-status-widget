# 第三方组件声明

本项目首发构建链路使用以下第三方软件：

| 组件 | 用途 | 许可证 |
|---|---|---|
| [PyInstaller](https://pyinstaller.org/) | 打包 Windows 单文件 EXE | GPL-2.0-or-later，附 bootloader exception |
| [pystray](https://github.com/moses-palmer/pystray) | Windows 系统托盘图标和菜单 | LGPL-3.0-or-later |
| [Pillow](https://python-pillow.github.io/) | 生成托盘图标位图 | HPND License |

完整许可证文本、适用条件和源代码获取方式以各组件的上游发布包为准。`hook_handler.py` 只使用 Python 标准库，不依赖上述组件。
