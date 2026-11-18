# 兼容性与验证边界

## 理论研究范围

本项目以**所有地区、所有型号的 Samsung Tizen TV**为适配研究对象。理论上可以研究 Local Set / 区域限制的读取和修改；能否在某一台电视上实现，必须逐项确认：

| 条件 | 需要确认的事实 |
| --- | --- |
| 连接 | 该设备是否提供可用的开发者模式与 SDB 连接 |
| 权限 | 是否存在适用于该固件的 root 方法，并能证明所需权限 |
| 工厂接口 | 真实路径、导出接口、ABI、缓冲区结构、返回语义是否已经核实 |
| 参数 | UID / TPID、数值范围、Local Set 的 store / enum / 名称映射是否一致 |
| 持久化与恢复 | 写入会改变什么、是否联动其他项、真实原值如何恢复并验证 |

这些条件在不同系列、年份、地区、尺寸或固件中可能不同。因此，“研究范围覆盖全部地区与型号”不是“已经适用于所有电视”的承诺，也不表示每种硬件或固件最终都能适配。非 Tizen 电视不在当前项目研究范围内。

## 当前可直接使用的唯一配置

| 字段 | 核对值 |
| --- | --- |
| 完整型号 | `QA75QN90BAJXXZ` |
| 系列 / 尺寸 / 销售地区 | QN90B / 75 英寸 / 中国大陆 |
| 固件显示版本 | `1710` |
| 精确构建 | `T-PTMUABC-REL-202509042046` |
| 电脑 | Windows 10 / 11，x64（Intel / AMD），PowerShell 5.1；不支持 ARM64 |
| 允许的目标 | 新加坡 `AD_SIN2`，或按真实备份恢复国行 `CHI_DTV` |
| 其他配置 | 未验证；当前写入逻辑不开放 |

显示型号、SW Model 或版本号相同，只能作为信息线索，不能代替本机文件与参数核验。所有必需检查通过后，才允许对应操作。

### 四个文件指纹

当前辅助程序在调用 native 工厂接口前检查以下 SHA256；这些是本配置的兼容性约束。**仅把新设备的哈希填入清单，并不能完成适配。**

| 本机路径 | SHA256 |
| --- | --- |
| `/usr/lib/libfactory-interface-DVBISDB.so` | `5f418d8a41fd6f307c76d013e36a1e6637496a7583c12f5bfff7baae8ac95670` |
| `/usr/lib/libfactory-data-config.so.00.00.0057` | `d469fa60c691729bba332ede19ab7d35b593944912fe8afbb44149f8c5902c35` |
| `/usr/bin/TIFSDaemon` | `550d7260e6f2f6e0d41d83d95f51a15cfd90b4f839609ffcad67b5e1d29320db` |
| `/factory_peq/factory-data/FactoryIndexFile_Part1.dat` | `8c15d893bafc042683ed3c64e95c97d669f07188367a7b240bc912091c5d8fb5` |

公开仓库记录指纹与分析结论，不包含上述三星固件文件。实际检查代码见 [`app/Worker.ps1`](../app/Worker.ps1) 和 [`source/`](../source/)。

## 当前映射与操作范围

以下数值仅用于说明这一配置，**不得作为其他型号的通用写入表**。

| 参数 | 本机 UID | 本机 TPID | 当前工具使用的状态 |
| --- | --- | --- | --- |
| Preventing Import | `761` | `140202` | 原值 `13`；解锁后的值 `0` |
| Local Set | `194` | `401` | `CHI_DTV` 或 `AD_SIN2` |

| Local Set 名称 | store 索引 | global enum |
| --- | --- | --- |
| `CHI_DTV` | `43` | `65` |
| `AD_SIN2` | `3` | `25` |

这台电视的 Local Set native getter 返回 global enum，而当前 setter 使用 store 索引。两者不是同一个数字体系；读取显示名称、转换接口和列表值需要交叉核对。实现见 [`NativeDevice.cs`](../source/stage2/source/NativeDevice.cs)。

本机读取到的列表上界为 `54`，解锁后可见 `0..54` 共 55 项。**“可读取 55 个条目”不等于“支持切换 55 个地区”。** 当前工具只开放 `AD_SIN2` 目标与 `CHI_DTV` 原值恢复，其余条目的写入与服务行为未验证。

### 三种已识别状态

| 状态 | Local Set | Preventing Import | 当前流程 |
| --- | --- | --- | --- |
| `CHI13` | `CHI_DTV` | `13` | 原始国行；切换时先 Stage1，再 Stage2 |
| `CHI0` | `CHI_DTV` | `0` | 已解锁；可按检查结果继续 Stage2 或恢复 Stage1 |
| `SG0` | `AD_SIN2` | `0` | 已到新加坡目标；再次切换不写入 |

完整恢复从 `SG0` 开始时，先 Stage2 恢复 Local Set，再 Stage1 恢复 Preventing Import。所需原始备份保存在本机：

```text
%LOCALAPPDATA%\QN90B-root\stage1\<电视IP>\Original-Baseline.json
%LOCALAPPDATA%\QN90B-root\stage2\<电视IP>\Original-Baseline.json
```

Stage1 备份对应 `CHI13`；Stage2 备份对应改 Local Set 前的 `CHI0`。恢复只接受与本机、固件匹配的真实备份。参数备份不是完整 EEPROM / NVRAM 镜像，不覆盖其他工厂设置。

每个阶段核对实时状态并回读；阶段失败会停止后续写入。已经成功的前一阶段不会因后一阶段失败而被默认为已撤销，必须依据结果和再次检测判断。界面已显示“新加坡参数”时，无需为了重复验证而再次写入。

## 已有证据与尚未验证事项

| 项目 | 当前证据 |
| --- | --- |
| 本机接口、UID 与数值映射 | 对照本机文件和只读返回值进行了核验 |
| Stage1 | 已核对实机结果 JSON：Import `13 → 0`，Local Set 保持 `CHI_DTV`，可见列表 `2 → 55` |
| Stage2 | 有用户切换成功反馈；新版图形封装准备时未取得新的 Stage2 完整结果 JSON |
| 新版 Windows 图形封装 | 已进行离线逻辑与结构检查；未在所有 Windows 环境实机点测 |
| 完整恢复与重启后状态 | 以对应设备的实际执行、回读和重启后再次检测为准；不由离线测试替代 |
| 海外应用与流媒体 | 不作统一可用性承诺，需要分别验证 |
| 其他地区、型号与固件 | 未验证 |

具体测试范围见 [`VALIDATION.txt`](../VALIDATION.txt)。检测成功、root 成功、参数写入成功和服务可用是不同层面的结果，应分别记录。

## 新设备如何申请适配

请先阅读[贡献指南](../CONTRIBUTING.md)，使用[兼容性反馈模板](https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/issues/new?template=compatibility.yml)提交脱敏后的只读信息。未知字段可填“未知”。不要上传三星固件二进制、真实设备身份、完整私人日志或原始备份，也不要通过修改型号、绕过检查或使用其他设备备份来试写。
