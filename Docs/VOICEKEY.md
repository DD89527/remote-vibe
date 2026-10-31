# VoiceKey 适配测试版

这是 DD89527 fork 的适配，不是上游正式发布。微信模式保留，默认仍选择微信；不需要替换或修改语音驱动。

## 使用

1. 打开 VoiceKey，并允许它使用麦克风和辅助功能。
2. 在 VoiceKey 的音频页选择 **Chromecast Mic** 或系统默认输入，然后离开音频页，停止电平预览。
3. 设置独立的长按键，例如 **右 ⌘**；点按键可使用 **Fn**，但不要和长按键复用同一个修饰键。
4. 在 Remote Vibe 窗口顶部选择 **语音：VoiceKey**，点击目标输入框，按住遥控器语音键说话，松开结束。

Google 与小米共用现有的遥控器音频通路。遥控器普通按键、自定义键位、鼠标模式不变。

## 行为

- 在每次语音开始前，只读 `~/Library/Application Support/VoiceKey/settings.json` 中的长按快捷键与麦克风设置。支持右 Option、右 Command、右 Control、Fn，以及 VoiceKey 的自定义长按组合（含 F18）。不读取凭据，不改写该文件。
- 触发的是**长按**快捷键，而不是点按开关。会话使用开始时的快捷键快照；中途调整设置，结束仍释放原来的键。
- 长按与点按复用同一个修饰键时拒绝启动，避免短按或取消变成持续录音。选错麦克风、配置损坏、VoiceKey 未运行时显示具体原因，不静默回落微信。
- 沿用音频预缓冲、尾段排空和恢复原系统默认输入的逻辑。正常结束、断连、中止和退出均成对释放快捷键。没有新增常开麦、静音流或后台定时器。
- VoiceKey 的识别渠道、模型、上屏和网络请求仍由 VoiceKey 自己管理；Remote Vibe 不读取识别文本。音频设置页的电平预览由 VoiceKey 控制，Remote Vibe 不强制关闭它。

## 验证边界

回归测试使用配置样例和不向系统投递的 CGEvent，检查预设与组合键、按下／释放顺序、权限失败、同键点按冲突、设备选择错误和会话快照。真实遥控器收音、VoiceKey 上屏、尾音与空闲释放仍须实机确认；云端构建成功不能代替这些验证。

适配依据为 [VoiceKey v1.7.1 设置格式](https://github.com/J3n5en/voicekey/blob/v1.7.1/app/src-tauri/src/settings.rs) 与 [快捷键状态机](https://github.com/J3n5en/voicekey/blob/v1.7.1/app/src-tauri/src/hotkey.rs)。VoiceKey 更改配置格式时需重新核对。
