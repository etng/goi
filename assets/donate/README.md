# 捐助二维码

把收款码图片放到本目录（PNG/JPG），文件名会作为二维码下方的标签显示，例如：

- `微信.png`
- `支付宝.png`

`scripts/make-app.sh` 打包时会把它们复制进 `Goi.app/Contents/Resources/donate/`，
App 的「关于」页会自动展示。README 的捐助小节也引用这里的图片。
