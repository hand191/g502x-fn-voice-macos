# G502XFnVoice

把 Logitech G502 X 的 G6（DPI Shift / “狙击键”）变成豆包输入法语音输入的按住说话键：

- 按住 G6：发送虚拟 `Fn Down`，开始语音识别；
- 松开 G6：可靠结束语音识别，再安全释放虚拟 Fn；
- 只监听 G6，不拦截鼠标的其他按键；
- 常驻 macOS 菜单栏，可以临时停用、重连鼠标和设置开机启动。

这是一个针对个人设备做的小型实验工具。目前只在下方列出的硬件和输入法组合上验证过，并不是通用鼠标改键器。

## 已验证环境

- Logitech G502 X，USB VID/PID `046d:c099`
- G6 / DPI Shift，HID button usage `5`
- macOS 15+
- 豆包输入法 0.9.7

版本 `0.3.1 (build 4)` 已完成短句、长句和连续复验。结果均为：松开后停止、文字只输入一次、光标与鼠标指针不移动。详细记录见 [docs/validation.md](docs/validation.md)。

## 为什么不是简单发送 Fn Up

测试中，macOS 已经收到虚拟 Fn Up，但豆包输入法 0.9.7 偶尔仍会继续识别；再次按 G6 才停止，并可能把同一段文字提交两次。直接点击编辑框虽然能可靠停止，却会移动插入点并扰乱输入。

最终流程是：

1. G6 按下时，通过 CoreHID 虚拟键盘发送 Fn Down。
2. G6 松开时，在当前指针下方短暂放置一个 `64 × 64` 的透明、不可激活点击接收层。
3. 向该接收层发送一次系统左键点击，用豆包能够稳定识别的鼠标事件结束语音；点击不会落到编辑器正文。
4. 等待 800 ms 让输入法完成提交，再发送 Fn Up。
5. 清理期间拒绝新的 G6 按下，避免两个语音周期交叠。

应用退出、停用、鼠标断开或系统休眠时都会强制释放虚拟 Fn。鼠标设备以共享方式打开，因此工具本身不会吞掉 G6 的原始 HID 事件。

## 使用

1. 启动 `G502XFnVoice.app`。
2. 在菜单栏图标中授予“输入监控”和“辅助功能”权限。
3. 把光标放进可输入文字的位置。
4. 按住 G6 说话，松开 G6 结束；连续两次使用之间建议留约 1 秒。

菜单栏提供：

- 启用/停用 `G6 → Fn`
- 开机自动启动
- 重新检查输入监控、辅助功能权限
- 重新连接 G502 X
- 退出工具

## 从源码构建

需要 Swift 6、包含 CoreHID 的 macOS SDK，以及有权使用
`com.apple.developer.hid.virtual.device` entitlement 的 Apple 签名身份。

先运行测试：

```sh
swift test
```

再打包并签名本地 `.app`：

```sh
CODE_SIGN_IDENTITY="Apple Development: ..." ./scripts/package-app.sh
```

产物位于 `dist/G502XFnVoice.app`。脚本不会覆盖已经存在的同名产物。

仓库只发布源码，不发布开发签名的 App 二进制：本机开发签名不可移植，而且这个 CoreHID entitlement 需要由构建者自己的签名环境满足。

## 权限与数据

- “输入监控”用于读取 G502 X 的 G6 HID 输入。
- “辅助功能”用于验证输入焦点，并发送被透明接收层截获的停止点击。
- 工具本身不录音、不联网、不保存语音或转写内容；语音数据如何处理取决于豆包输入法本身。

如果菜单栏显示未连接或缺少权限，请先用菜单里的对应项目重新检查；若输入法已经卡在识别状态，可先实体左键点击一次，再退出并重新打开本工具。

## 已知边界

- 设备匹配目前固定为 `046d:c099`，其他 G502 型号不会自动工作。
- 仅针对豆包输入法 0.9.7 的实际行为设计，其他输入法未经验证。
- 释放时依赖当前仍是同一个前台文本输入控件；焦点已变化时会安全失败并释放 Fn。
- 这是个人学习与实验项目，不隶属于或受 Logitech、Apple、字节跳动/豆包认可。

## License

原创代码使用 [MIT License](LICENSE)。虚拟键盘 HID report descriptor 改编自 Apple CoreHID sample，适用条款见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 和 [Apple Sample Code License](https://developer.apple.com/support/downloads/terms/apple-sample-code/Apple-Sample-Code-License.pdf)。
