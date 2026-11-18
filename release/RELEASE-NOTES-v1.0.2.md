# v1.0.2 · Windows 工具与 10 页图文教程

**普通用户请优先下载 `Samsung-TV-Unlock-Local-Set-v1.0.2-Windows-x64.zip`。** 无需自行编译；适用于 Windows 10 / 11 x64（Intel / AMD），使用 Windows PowerShell 5.1。

## 下载附件

| 附件 | 用途 |
| --- | --- |
| **`Samsung-TV-Unlock-Local-Set-v1.0.2-Windows-x64.zip`** | 完整工具包，含界面、辅助程序、源码与离线教程；优先下载此文件 |
| `QN90B-Guide-v1.0.2.pdf` | 单独阅读或打印的 **10 页中文图文教程**，包含开发者模式与临时 Root 教程 |
| `SHA256SUMS.txt` | 校验上面两个附件的 SHA256 |

## 开始使用

1. 下载工具 ZIP，右键选择 **“全部解压”**，保留完整目录结构。
2. 双击解压目录中的 **`START.cmd`**，点击 **“检查 / 安装运行环境”**。
3. 按教程开启电视开发者模式、填写电脑与电视各自的 IP，再点击 **“检测当前状态”**。检测通过后，按界面提供的操作继续。

首次准备环境需要联网，组件会优先复用；全部需要下载时约 **137 MB**。工具从固定的官方来源下载并校验 SHA256，无需安装完整 Tizen Studio、Python 或编译环境。首次准备 OpenSSL 需要可处理该归档的系统 `tar.exe`，或电脑上已有可运行的 OpenSSL。

助手按需建立**临时 Root 会话**，没有提供永久 Root。新增教程说明 SDB 连接、`doctor`、预检和 Root 认证之间的区别，并提供只执行 `id` 的手动验证命令及日志判读。

## 当前适用范围

当前配置针对 **国行 75 英寸 QN90B `QA75QN90BAJXXZ`、显示固件 `1710`、内部构建 `T-PTMUABC-REL-202509042046`**。写入前还必须通过 **4 个工厂相关文件的 SHA256**、实时参数和原值备份检查，具体指纹见[兼容性说明](https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/blob/v1.0.2/docs/COMPATIBILITY.md)。仅型号或显示版本相同不足以确认兼容。

- 当前开放目标：新加坡 **`AD_SIN2`**。
- 恢复路径：凭**本机真实原值备份**恢复国行 **`CHI_DTV`** 及对应 Preventing Import 原值；请保留备份。
- 理论适配研究面向所有地区、所有型号的 **Samsung Tizen TV**，**不等于这些设备已经验证或都能适配**。当前检查条件与写入范围保持不变。

临时权限结束不会自动撤销已经写入的工厂参数。地区参数切换也不代表所有应用或流媒体服务已经验证可用。

## 本次验证记录

源码提交：[101c6cfe2694f6dd669ff71104584051f0373fbe](https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/commit/101c6cfe2694f6dd669ff71104584051f0373fbe)。

- **实际 Windows CI 已成功**：[运行 44269322894](https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/actions/runs/44269322894)，在 `windows-2022` / **Windows PowerShell 5.1** 下通过 **40 项 PowerShell 离线测试**（Worker 25 + Launcher 15）和 **31 项 C# 状态机模拟测试**（Stage1 15 + Stage2 16），并完成辅助程序构建与随包文件指纹核验。
- **另有 9 项 OpenSSL 本地离线／模拟测试通过**，包含真实归档提取与失败处理检查；运行于 Linux，**不是 Windows 安装或解包实测**。
- 既有电视证据包括已核对的 Stage1 结果 JSON，以及用户的 Stage2 切换成功反馈。**本次没有新增“Windows 图形界面 + 电视完整操作流程”的端到端实机验证**；CI 没有连接电视、执行 Root 或写入工厂参数。

## 许可与附件内容

本项目自有源码采用 [MIT License](https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/blob/v1.0.2/LICENSE)。上游工具、运行组件和字体分别遵循各自许可，MIT 不覆盖这些第三方内容，详见[第三方声明](https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/blob/v1.0.2/THIRD-PARTY-NOTICES.txt)。

发布附件不包含第三方下载缓存、三星固件二进制、私人日志、真实设备身份信息或原值备份；缺少的依赖在用户电脑首次准备环境时下载。公开反馈请仅提交必要的脱敏信息。
