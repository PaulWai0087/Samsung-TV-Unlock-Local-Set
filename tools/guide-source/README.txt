QN90B 区域助手图文指南源文件

create_guide.py：生成离线 HTML、10 页 PDF、精确矢量示意图及 content.json。
render_preview.py：将与 SVG 相同的矢量场景正常渲染为 assistant.png，并检查 HTML 本地链接。
运行依赖：Python 3、ReportLab、fontTools、PyMuPDF；制图机器需有 Noto Sans CJK SC 字体。
这些文档构建脚本只处理本地文件，不连接电视，也不是 Windows 助手的运行依赖。

字体说明
guide-sc-regular.ttf 和 guide-sc-bold.ttf 是 Noto Sans CJK SC 的子集与轮廓格式转换版，
字体名称已改为 QN90B Guide SC；修改内容由 create_guide.py 中 make_font 函数记录。
本次实际源字体的版权记录为 © 2014-2021 Adobe (http://www.adobe.com/)。
子集字体的 name 表保留原字体的版权、许可证说明与链接；以后重新生成时也会保留。
完整 SIL Open Font License 1.1 与来源、修改说明见 FONT-LICENSE.txt。
这两个字体文件依照 OFL-1.1 分发，不属于仓库的 MIT 许可证范围。
PDF 内嵌的字体用于离线显示中文。HTML 使用操作系统已有的中文字体。

验证说明
PDF 由 Poppler 渲染所有 10 页，再逐页检查文字、图表和页边距。
第 5 页说明自动临时 Root 流程，第 6 页说明手动 id 验证的成功判读。
Root 流程与结果字段示意图分别为 root-flow.svg、root-proof.svg；完整手动命令链接到 docs/ROOT-GUIDE.md。
所有图片均为重新绘制并标注的界面／设备示意，非用户截图或 Windows 实机截图。
新 GUI 的实际 Windows 运行验证与本教程的渲染检查是不同事项。
