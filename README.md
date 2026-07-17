# Goi（語彙）

*[English version: README.en.md](README.en.md) · 以下为中文说明*

用 Swift 编写的 macOS 原生词典应用——动态加载 MDX/MDD 词典、菜单栏 Spotlight
式查词、英日词形还原、带熟悉度的生词本，以及通过 AnkiConnect 与 Anki 双向同步。

> 状态：可用原型。

## 安装

从 [最新发布](https://github.com/etng/goi/releases/latest) 下载 `Goi.dmg`（通用版，
Apple 芯片和 Intel 都可用），双击打开后把 Goi 拖入「应用程序」。当前发布版尚未完成
Apple Developer 公证；如果首次打开提示「无法验证」或「已损坏」，请确认安装包来自上述
官方发布页，然后在「终端」复制执行：

```sh
xattr -dr com.apple.quarantine "/Applications/Goi.app" && open "/Applications/Goi.app"
```

这只放行当前安装的 Goi，不会关闭 Mac 的全局安全保护；若提示没有权限，在命令前加
`sudo`。不使用终端也可以到「系统设置 → 隐私与安全性」点「仍要打开」。新下载的版本
如果再次被拦截，需要对新 App 再执行一次。[带图步骤见手册](https://etng.github.io/goi/guide/install)。

## 功能

- **就地加载 MDX/MDD 词典**——导入采用 APFS 写时复制克隆：不占额外磁盘空间，
  且删除或移动原始文件都不会影响应用运行。
- **即时查词**——常驻菜单栏，全局快捷键唤起 Spotlight 式面板；在任意应用里选中
  文字按快捷键即可查询（并捕获所在句子作为上下文）。
- **跨程序查词**——浏览器、启动器和其他应用可通过
  `goi://search?word=justforfun` 直接打开 Goi 查询指定词语。
- **词形还原**——复数、时态、日语活用都会先还原为原型再查询。
- **熟悉度模型**——每次查询都会记录；反复查的词自动进入生词本，手动加入的权重更高。
- **Anki 集成**——生词以公开、文档化的笔记类型经 AnkiConnect 同步到 Anki；复习
  数据回流调整熟悉度。同时支持完整的 JSON/CSV 导入导出。

## 致谢

- **minilzo**（Markus F.X.J. Oberhumer，GPL-2.0-or-later）——MdictKit 中的 LZO1X
  块解压是其算法的 Swift 移植。
- **readmdict / js-mdict**——MDict（MDX/MDD）容器格式的逆向工程文档。未包含其代码。
- **RIPEMD-128**——按公开的 COSIC 规范实现，用于加密的 MDX 键索引。
- 可选的运行时集成（未捆绑）：**mecab + IPADIC**（日语活用还原）、
  **Anki + AnkiConnect**（间隔重复同步）。

## 赞助

如果 Goi 对你有帮助，欢迎请作者喝杯咖啡——扫描下方任一二维码（也可在应用「关于」
页扫描）。捐款墙筹备中。

| 微信支付 | 支付宝 |
|---|---|
| <img src="assets/donate/微信支付.png" width="220" alt="微信支付"> | <img src="assets/donate/支付宝.jpg" width="220" alt="支付宝"> |

## 构建

使用 [Claude Code](https://claude.com/claude-code) 开发。

## 许可证

[GPLv3](LICENSE)。
