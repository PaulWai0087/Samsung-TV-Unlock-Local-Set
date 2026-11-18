#!/usr/bin/env python3
"""Build the offline Chinese guide, SVG illustrations and vector PDF.

No TV calls. Requires reportlab/fontTools and system Noto Sans CJK fonts.
Illustrations are deliberately labelled diagrams, never user screenshots.
"""
from __future__ import annotations
import base64, html, json, pathlib, re, sys
from fontTools.ttLib import TTFont as FontToolsFont
from fontTools import subset
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib import colors
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak, Flowable, KeepTogether
from reportlab.graphics.shapes import Drawing, Rect, String, Circle, Line, Polygon
from reportlab.graphics import renderPDF, renderSVG

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
GUIDE = ROOT / 'guide'
ASSETS = GUIDE / 'assets'
GUIDE.mkdir(parents=True, exist_ok=True); ASSETS.mkdir(parents=True, exist_ok=True)

INK='#15283e'; MUTED='#536679'; TEAL='#0c7e78'; LIGHT='#e8f5f2'; BLUE='#edf3fb'
BORDER='#d5e0e8'; PAPER='#f5f8fb'; WHITE='#ffffff'; AMBER='#996316'; WARM='#fff5df'
FONT='GuideSC'; BOLD='GuideSC-Bold'

SOURCES = [
 ('1','Samsung Developer：连接电视、开发者模式与 Host PC IP','https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html'),
 ('2','Samsung Developer：Apps 页面输入 12345（早期界面示例）','https://developer.samsung.com/tizen/blog/en/2019/07/16/connecting-smart-tv-and-visual-studio'),
 ('3','Samsung 官方：数字／彩色键与屏幕数字盘','https://www.samsung.com/ae/support/tv-audio-video/navigate-your-samsung-tv-using-the-smart-remote-control/'),
 ('4','Samsung 官方：2022 年及以后电视的网络状态入口','https://www.samsung.com/ca/support/tv-audio-video/verify-network-status-on-your-samsung-tv/'),
 ('5','原作者 samsung-tv-root v0.0.13；本包固定版本','https://github.com/chris-ritsen/samsung-tv-root/tree/v0.0.13'),
 ('6','SDB 官方下载目录；本包使用 4.2.36','https://download.tizen.org/sdk/tizenstudio/official/binary/sdb_4.2.36_windows-64.zip'),
 ('7','便携 OpenSSL 的发行来源：Git for Windows 2.56.1','https://github.com/git-for-windows/git/releases/tag/v2.56.1.windows.1'),
]

def p(text): return {'type':'p','text':text}
def callout(title,text,tone='teal'): return {'type':'callout','title':title,'text':text,'tone':tone}
def steps(items): return {'type':'steps','items':items}
def table(head,rows,widths=None): return {'type':'table','head':head,'rows':rows,'widths':widths}
def figure(name,caption,width=515): return {'type':'figure','name':name,'caption':caption,'width':width}
def root_guide_link():
    return {'type':'related','title':'手动故障排查与可复制命令','text':'完整步骤见 ROOT-GUIDE.md；正常使用图形界面时无需先运行手动命令。',
            'href':'../docs/ROOT-GUIDE.md','web':'https://github.com/PaulWai0087/Samsung-TV-Unlock-Local-Set/blob/HEAD/docs/ROOT-GUIDE.md'}

PAGES = [
 {'id':'quick','eyebrow':'01 / 快速开始','title':'QN90B 区域助手','subtitle':'图文使用指南 · 从检测到切换，再到恢复原值', 'blocks':[
  figure('cover','图 1  操作关系示意。所有插图均为界面／设备示意，非实机截图。'),
  callout('如果你已经成功换区，从检测开始','使用保留原值备份的电脑和 Windows 账户。下载 ZIP 并全部解压，打开 START.cmd，联网准备运行环境后点击“检测当前状态”。如果显示“新加坡参数”，本次无需再次切换。'),
  steps([('打开工具','右键 ZIP 选择“全部解压”，再双击解压文件夹里的 START.cmd。'),('检查环境，然后检测','先点“检查 / 安装运行环境”，按第 3 页启用开发者模式。填对电视 IP 后点“检测当前状态”；所需临时 Root 由工具自动建立。'),('按状态选择下一步','要切换时点“切换新加坡”；要回到原值时点“恢复国行参数”。已是目标状态时保留即可。')]),
  p('本指南只适用于已核对的 75 英寸国行 QN90B。开发者模式看第 3 页；临时 Root 与成功判读看第 5–6 页；备份与恢复看第 8 页。')
 ]},
 {'id':'scope','eyebrow':'02 / 适用范围','title':'先看型号，再看状态','subtitle':'“新加坡参数”表示本机 Local Set 已设为 AD_SIN2。', 'blocks':[
  table(['项目','本工具要求'],[
   ['完整型号','QA75QN90BAJXXZ · 75 英寸 · 国行'],
   ['电视显示的固件版本','1710'],
   ['精确系统构建','T-PTMUABC-REL-202509042046'],
   ['电脑环境','Windows 10 / 11，x64（Intel / AMD）；不支持 ARM64。使用系统 PowerShell 5.1。'],
  ],[0.29,0.71]),
  p('助手还会核对系统文件的指纹。仅看到“QN90B”或“1710”不足以保证匹配；检测不通过时，先导出诊断。'),
  figure('states','图 2  三种已识别状态示意。数值供核对，无需手动输入。'),
  table(['状态','你应当怎样做'],[
   ['国行参数（CHI13）','Local Set 为 CHI_DTV，Preventing Import 为 13。需要换区时点击“切换新加坡”。'],
   ['地区列表已解锁（CHI0）','仍为 CHI_DTV，Preventing Import 已为 0。再次检测后，工具可继续到新加坡。'],
   ['新加坡参数（SG0）','Local Set 为 AD_SIN2，Preventing Import 为 0。已经达到本工具的目标。'],
  ],[0.32,0.68]),
  callout('本工具完成什么','切换地区列表限制和 Local Set 两项参数。它不会承诺海外应用商店、账户、授权、DRM 或每个流媒体服务都能正常使用。服务是否可用需要单独验证。','blue'),
 ]},
 {'id':'prepare','eyebrow':'03 / 首次准备','title':'把电视和电脑连对','subtitle':'已开启开发者模式且能连接电视的用户，可直接看第 4 页。', 'blocks':[
  figure('network','图 3  地址填写示意。电视 192.168.1.100、电脑 192.168.1.10 均为示例，请填写实际地址。'),
  steps([
   ('连到同一个家庭局域网','电视和电脑接入同一路由器。电视可用网线，电脑可用 Wi-Fi；避免访客网络或设备隔离。助手中的“本机局域网 IP”要选择连接该路由器的网卡。[1]'),
   ('查看电视 IP','在电视“设置 > 所有设置 > 连接 > 网络 > 网络状态 > IP 设置”查看地址；部分界面在“通用 > 网络”。把这个地址填到助手的“电视 IP”。只查看即可。[4]'),
   ('开启开发者模式','打开电视“应用 / Apps”。有“应用设置 / App Settings”的界面进入该页。按遥控器数字／彩色键（通常标为 123）调出屏幕数字盘，用方向键和确认键依次选择 1、2、3、4、5；若要求提交，选择“完成 / 输入数字”。[1][2][3]'),
   ('填写电脑地址并重启电视','在 Developer Mode 窗口把开关设为 On，将 Host PC IP 填成助手显示的电脑地址，例如 192.168.1.10，确认后重启电视。这个位置不能填电视自己的 .100。[1]'),
  ]),
  callout('太阳能遥控器没有数字键，也能输入','使用的是电视屏幕上的数字盘，无需购买另一支遥控器。按键标识和 Apps 布局可能因地区界面不同而变化；无法出现开发者窗口时，保留当前页面和提示再排查。','blue'),
 ]},
 {'id':'launch','eyebrow':'04 / 打开与配置','title':'打开 START.cmd','subtitle':'GitHub 源码发行不含第三方运行包，首次准备环境需要联网。', 'blocks':[
  figure('assistant','图 4  区域助手界面示意，非 Windows 实机截图。IP 仅为示例，请填写实际地址。',485),
  steps([
   ('完整解压后打开','在 GitHub 点击“Code > Download ZIP”，使用“全部解压”。保留 app、engines、guide 等全部同级内容，然后双击 START.cmd。不要在压缩包预览窗口里运行。'),
   ('保存地址，检查运行环境','“电视 IP”填当前电视地址并点“保存”；核对“本机局域网 IP”。点击“检查 / 安装运行环境”，等待完成。'),
  ]),
  p('工具从上游固定版本地址下载组件并核对 SHA256，后续可复用已核验的缓存。优先使用本机可运行的 OpenSSL；没有可用版本时，首次合计下载约 137 MB。通常无需管理员权限，也不要求安装 Python 或完整 Tizen Studio。'),
  p('首次准备 OpenSSL 需要系统内置 tar.exe，只从官方 Git 归档提取所需文件，无需运行 Git 安装器。旧系统提示 tar.exe 缺失或不支持解压时，请更新 Windows，或安装官方 Git for Windows 后重试。'),
 ]},
 {'id':'root-flow','eyebrow':'05 / 临时 Root','title':'检测时自动建立临时 Root','subtitle':'推荐使用图形界面的检测流程，无需预先设置永久 Root。', 'blocks':[
  figure('root-flow','图 5  临时 Root 的自动流程示意，非实机截图；检测只读取地区参数。'),
  steps([
   ('先准备电脑环境','打开 START.cmd，点击“检查 / 安装运行环境”。固定使用 samsung-tv-root v0.0.13、SDB 4.2.36 与 Windows x64；本机电视使用 .NET runtime 3.1。[5][6]'),
   ('启用电视开发者模式','按第 3 页配置 Developer Mode 与 Host PC IP，确认电脑和电视处于同一局域网，并按要求重启电视。'),
   ('点击“检测当前状态”','后台流程会连接 SDB、尝试临时 Root，权限通过后读取本机参数并显示状态。Root 或参数核验失败时停止，保留日志再排查。'),
  ]),
  callout('“临时”说的是会话持续时间','本次命令结束后会话退出，下一次检测或切换会建立新的临时会话。它不是常驻后台的永久 Root；在会话中已经写入的工厂参数不会因为会话结束而自动恢复。','blue'),
  p('手动验证只运行 id 时不会调用工厂参数 setter。archive-root probe 也会实际尝试 Root，不能把它当作纯电脑环境检查。'),
  root_guide_link(),
 ]},
 {'id':'root-proof','eyebrow':'06 / Root 成功判读','title':'确认 Root，要看整组结果','subtitle':'下表针对手动仅运行一次 id 的验证；GUI 会另行核对完整检测结果。', 'blocks':[
  figure('root-proof','图 6  id 验证的结果字段示意，非真实日志或实机截图。'),
  table(['需要核对的层次','本指南的成功判据'],[
   ['外层进程','命令行工具退出码为 0。'],
   ['认证与数字身份','authenticated = true；uid、euid、gid、egid 均为 0。'],
   ['唯一验证命令','commands 恰好包含 1 条命令，command 为 id。'],
   ['id 的执行结果','exit_code = 0；timed_out = false；stdout 中显示 uid=0。'],
   ['暂存清理','另外确认 staging_cleaned = true。'],
   ['上游检查的两文件','另外确认 system_files_unchanged = true：只表示 /etc/passwd 与 /usr/share/sdbd/public.pem 保持一致，不代表整机全量校验。'],
  ],[0.27,0.73]),
  p('uid=0(owner) 中的数字 0 仍表示该命令的 UID 为 0。model: null 在 generic archive 模式中正常；它本身不是失败信号。'),
  callout('不要把准备状态当作 Root 结果','Setup / doctor 与 Ready: yes 只说明电脑端准备情况；SDB 中的 device 只证明连接。capabilities 或 Smack: User 也不能单独决定成功或失败，应结合上表中的权限和命令结果判断。','blue'),
 ]},
 {'id':'singapore','eyebrow':'07 / 检测与切换','title':'先检测，再切换新加坡','subtitle':'点击切换按钮就会执行；工具会在写入前再次核对。', 'blocks':[
  figure('switch','图 7  一次“切换新加坡”背后的顺序示意。中间状态无需手动处理。'),
  steps([
   ('点击“检测当前状态”','等待显示当前 Local Set、Preventing Import、备份状态。检测阶段只读取地区参数；连接所需的临时权限由工具处理。'),
   ('确认状态与备份提示','如果显示“新加坡参数”，已经完成，无需重复。若显示“国行参数”或“地区列表已解锁”，且“切换新加坡”可用，可继续。'),
   ('点击“切换新加坡”并等待','工具会保存真实原值，按需解锁地区列表，再设置 AD_SIN2，并逐步回读核对。运行期间保持电视开机、电脑不休眠。'),
   ('查看完成结果','成功应显示“新加坡参数”：Local Set 为 AD_SIN2，Preventing Import 为 0。再次点击“检测当前状态”可复核。'),
  ]),
  callout('已经显示新加坡参数？','保留当前状态即可。若你已经在之前的 Stage2 操作中成功，本工具的首次检测应以当前电视读数为准，不需要为了“安装新版界面”再改一次。'),
  p('运行过程中请等待底部日志结束，不要同时运行旧版脚本或拔电。完成后若正常重启了电视，再检测一次，才能核对重启后参数是否保留。'),
 ]},
 {'id':'restore','eyebrow':'08 / 恢复原值','title':'用真实备份恢复国行参数','subtitle':'恢复按钮会自动按正确顺序完成两步，无需手动填数值。', 'blocks':[
  figure('restore','图 8  恢复顺序示意：先恢复 Local Set，再恢复地区列表限制。'),
  steps([
   ('使用原来操作的电脑和账户','先检测。助手会查找本机已有的两份 Original-Baseline.json，并校验它们是否属于当前这台电视。'),
   ('点击“恢复国行参数”','按钮可用表示所需条件已满足。工具先将 Local Set 恢复为 CHI_DTV，再把 Preventing Import 恢复到原值 13。每一步都会回读。'),
   ('检查最终状态','成功后应显示“国行参数”：Local Set 为 CHI_DTV，Preventing Import 为 13。它恢复的是本次修改的这两项原值。'),
  ]),
  callout('两份原值文件都要留好','Stage1 备份记录原始的 CHI_DTV + 13；Stage2 备份记录改 Local Set 前的 CHI_DTV + 0。工具会复用旧版在原电脑留下的这两份文件。缺少真实备份时不会伪造原值。','blue'),
  {'type':'code','text':'%LOCALAPPDATA%\\QN90B-root\\stage1\\<电视IP>\\Original-Baseline.json\n%LOCALAPPDATA%\\QN90B-root\\stage2\\<电视IP>\\Original-Baseline.json'},
  p('点击“打开备份位置”，把这两份原值文件另存一份。不要改文件内容，也不要用别人的备份替换。若电视 IP 改了或换了 Windows 账户导致备份不匹配，请导出诊断。'),
 ]},
 {'id':'help','eyebrow':'09 / 遇到问题','title':'按提示定位，不反复写入','subtitle':'先看底部日志，再用“导出诊断”保留本次结果。', 'blocks':[
  table(['看到的情况','先做这一步'],[
   ['双击后没有窗口','确认已经全部解压，运行的是 START.cmd。若有命令窗口错误，完整保留错误文字。公司电脑的脚本限制需由管理员处理。'],
   ['电视连接失败 / 26101 不通','确认电视开机、电视 IP 正确、两者在同一家庭局域网；再核对开发者模式的 Host PC IP 是电脑地址。更改开发者设置后重启电视。[1]'],
   ['本机 IP 下拉有多个地址','选择与电视所在家庭网络对应的网卡。不要选断开的网卡或无关虚拟网卡；图中 192.168.1.10 只是电脑地址示例。'],
   ['缺运行环境 / 403 / 缓存损坏','首次配置需能访问上游下载站点。确认网络后点“检查 / 安装运行环境”重试；仍失败就导出诊断。不要自行替换版本或跳过文件校验。'],
   ['权限失败 / 检测超时','确认开发者模式与电脑 IP，检查防火墙是否允许本工具在家庭／专用网络通信。不要关闭整机防火墙；保留完整日志再排查。'],
   ['切换 / 恢复按钮是灰色','先安装环境并检测。缺真实原值备份、固件指纹不匹配或未知状态都会阻止写入，按状态卡和日志说明处理。'],
   ['操作失败或提示已回退','不要把失败当成功。重新检测，确认当前参数，再导出诊断。只在明确满足条件后继续。'],
  ],[0.30,0.70]),
  callout('诊断包怎么用','点击“导出诊断”将结果保存在本机。公开反馈时只提供型号、构建、操作步骤和经过人工脱敏的必要错误片段；不要直接上传完整诊断包、Original-Baseline.json 或设备身份信息。','blue'),
  p('官方说明 26101 是电视内部连接端口，不能单独打开；排查应从电视开发者模式与网络连接入手。[1]'),
 ]},
 {'id':'backup','eyebrow':'10 / 保留与参考','title':'留住备份，知道验证边界','subtitle':'把完整工具包、两份原值文件和成功结果一起保存。', 'blocks':[
  p('<b>建议保留：</b>完整工具包、Stage1 和 Stage2 的 Original-Baseline.json、最近一次成功结果／导出诊断。参数原值备份用于回退这两项设置，不是整机 EEPROM 或全部工厂参数镜像。'),
  p('<b>已有验证情况：</b>Stage1 已对照实机 JSON 确认从 13 改为 0，Local Set 未变，列表从 2 项扩展为 55 项；Stage2 有用户切换成功反馈。新版图形封装完成离线检查，尚未完成 Windows 实机点测。重启后的最终状态以再次检测为准。'),
  p('<b>操作范围：</b>本包围绕已核对的地区参数进行读取、切换与回退。海外应用和流媒体是否可用，不由 Local Set 一项决定。这里不重新展开刷固件、Smart Hub 区域或网络出口设置。'),
  {'type':'sources','items':SOURCES},
  p('资料核对日期：2026-11-18。开发者模式和数字盘步骤依据三星官方资料整理；本机参数映射依据本次实机读数与本机文件核验。所有插图为重新绘制的示意，不是用户电视或 Windows 的实机截图。'),
 ]},
]

def plain(s): return re.sub(r'<[^>]+>','',s)

def make_font(weight='Regular'):
    """Subset installed OFL CFF outlines and convert them to embedded TrueType."""
    out=HERE/('guide-sc-'+weight.lower()+'.ttf')
    # Include the complete source text to keep labels and future edits covered.
    text=pathlib.Path(__file__).read_text() + json.dumps(PAGES,ensure_ascii=False)
    t=FontToolsFont('/usr/share/fonts/opentype/noto/NotoSansCJK-'+weight+'.ttc',fontNumber=2)
    # Retain the original font's copyright and OFL notice when rebuilding its
    # name table. The subset has its own family name and remains under OFL 1.1.
    font_notices={key:t['name'].getDebugName(name_id) for key,name_id in
                  [('copyright',0),('licenseDescription',13),('licenseInfoURL',14)]}
    if not all(font_notices.values()):
        raise RuntimeError('The source font must include copyright and license metadata.')
    opt=subset.Options(); opt.layout_features=[]; opt.name_IDs=['*']; opt.name_legacy=True
    sub=subset.Subsetter(options=opt); sub.populate(text=text); sub.subset(t)
    glyphset=t.getGlyphSet(); order=t.getGlyphOrder(); glyf={}
    for name in order:
        pen=TTGlyphPen(glyphset)
        glyphset[name].draw(Cu2QuPen(pen, 1.0, reverse_direction=True))
        glyf[name]=pen.glyph()
    fb=FontBuilder(t['head'].unitsPerEm,isTTF=True)
    fb.setupGlyphOrder(order); fb.setupCharacterMap(t.getBestCmap()); fb.setupGlyf(glyf)
    fb.setupHorizontalMetrics({n:t['hmtx'].metrics[n] for n in order})
    fb.setupHorizontalHeader(ascent=t['hhea'].ascent,descent=t['hhea'].descent,lineGap=t['hhea'].lineGap)
    fb.setupNameTable({**font_notices,'familyName':'QN90B Guide SC','styleName':weight,'uniqueFontIdentifier':'QN90BGuideSC-'+weight,'fullName':'QN90B Guide SC '+weight,'psName':'QN90BGuideSC-'+weight,'version':'Version 1.0'})
    os2=t['OS/2']
    fb.setupOS2(sTypoAscender=os2.sTypoAscender,sTypoDescender=os2.sTypoDescender,sTypoLineGap=os2.sTypoLineGap,usWinAscent=os2.usWinAscent,usWinDescent=os2.usWinDescent,usWeightClass=700 if weight=='Bold' else 400)
    fb.setupPost(); fb.setupMaxp(); fb.save(out)
    pdfmetrics.registerFont(TTFont(BOLD if weight=='Bold' else FONT,str(out)))

def C(v): return colors.HexColor(v)
class Scene:
    def __init__(self,w,h): self.w=w; self.h=h; self.d=Drawing(w,h)
    def rect(self,x,y,w,h,fill=WHITE,stroke=None,r=0,sw=1):
        self.d.add(Rect(x,self.h-y-h,w,h,rx=r,ry=r,fillColor=C(fill) if fill else None,strokeColor=C(stroke) if stroke else None,strokeWidth=sw))
    def line(self,x1,y1,x2,y2,color=BORDER,sw=1):
        self.d.add(Line(x1,self.h-y1,x2,self.h-y2,strokeColor=C(color),strokeWidth=sw))
    def text(self,x,y,s,size=18,color=INK,bold=False,anchor='start'):
        self.d.add(String(x,self.h-y-size*.85,s,fontName=BOLD if bold else FONT,fontSize=size,fillColor=C(color),textAnchor=anchor))
    def circle(self,x,y,r,fill=TEAL): self.d.add(Circle(x,self.h-y,r,fillColor=C(fill),strokeColor=None))
    def arrow(self,x1,y1,x2,y2,color=TEAL):
        self.line(x1,y1,x2,y2,color,3)
        if abs(x2-x1)>abs(y2-y1): pts=[x2,self.h-y2,x2-10,self.h-y2+6,x2-10,self.h-y2-6]
        else: pts=[x2,self.h-y2,x2-6,self.h-y2+10,x2+6,self.h-y2+10]
        self.d.add(Polygon(pts,fillColor=C(color),strokeColor=None))
    def badge(self,x,y,label,w=None):
        w=w or len(label)*15+24; self.rect(x,y,w,31,LIGHT,r=15); self.text(x+12,y+6,label,15,TEAL,True)
    def caption(self): self.text(self.w-18,self.h-24,'界面／设备示意 · 非实机截图',12,MUTED,anchor='end')

def scenes():
    out={}
    s=Scene(920,330)
    s.rect(0,0,920,330,PAPER,r=20)
    s.rect(28,27,536,253,INK,r=12); s.rect(39,38,514,228,'#153e4d',r=6)
    s.badge(64,61,'本机已核对',150); s.text(65,112,'QN90B',43,WHITE,True)
    s.text(66,172,'Local Set',18,'#b7d6db'); s.text(66,201,'AD_SIN2',34,WHITE,True)
    s.rect(249,280,90,9,INK,r=3); s.rect(205,289,178,7,INK,r=3)
    s.rect(588,51,302,233,WHITE,BORDER,r=14); s.text(612,73,'在电脑上完成',22,INK,True)
    for i,label in enumerate(['检测当前状态','切换新加坡','恢复国行参数']):
        y=119+i*48; s.circle(626,y+13,13,TEAL if i<2 else '#6f8397'); s.text(626,y+3,str(i+1),15,WHITE,True,'middle'); s.text(650,y+2,label,20,INK,True)
    s.caption(); out['cover']=s

    s=Scene(920,210); s.rect(0,0,920,210,PAPER,r=16)
    labels=[('国行参数','CHI_DTV','13','CHI13'),('地区列表已解锁','CHI_DTV','0','CHI0'),('新加坡参数','AD_SIN2','0','SG0')]
    for i,(title,name,imp,code) in enumerate(labels):
        x=20+i*301; s.rect(x,18,278,153,WHITE,BORDER,r=12); s.badge(x+17,32,code,75)
        s.text(x+17,76,title,21,INK,True); s.text(x+17,112,'Local Set: '+name,16); s.text(x+17,140,'Preventing Import: '+imp,15,MUTED)
    s.caption(); out['states']=s

    s=Scene(920,386); s.rect(0,0,920,386,PAPER,r=18)
    s.rect(22,26,280,195,WHITE,BORDER,r=12); s.text(44,45,'电脑',22,INK,True); s.badge(44,85,'192.168.1.10',217); s.text(44,138,'本机局域网 IP',17); s.text(44,168,'填进电视的 Host PC IP',16,TEAL,True)
    s.rect(341,72,235,106,INK,r=12); s.text(458,96,'同一个路由器',21,WHITE,True,'middle'); s.text(458,134,'家庭局域网',16,'#c8d7e5',False,'middle')
    s.arrow(305,126,336,126); s.arrow(581,126,612,126)
    s.rect(619,26,280,195,WHITE,BORDER,r=12); s.text(641,45,'电视',22,INK,True); s.badge(641,85,'192.168.1.100',235); s.text(641,138,'电视 IP',17); s.text(641,168,'填进电脑助手的“电视 IP”',16,TEAL,True)
    s.text(23,238,'两个地址分开填写；图中地址只是示例，请以实际地址为准。',17,MUTED)
    s.rect(23,279,874,66,WHITE,BORDER,r=10); s.text(40,301,'屏幕数字盘',17,INK,True)
    for i in range(5):
        x=150+i*43; s.rect(x,294,34,34,LIGHT,r=5); s.text(x+17,302,str(i+1),19,TEAL,True,'middle')
    s.arrow(374,311,414,311)
    s.text(435,291,'Developer Mode: On',17,INK,True)
    s.text(435,318,'Host PC IP: 192.168.1.10',16,TEAL)
    s.caption(); out['network']=s

    # Schematic of the final WinForms layout: initial state, 2 x 2 main buttons.
    blue='#2563eb'; ui_ink='#182840'; ui_muted='#6c7b91'; disabled='#e2e8f0'
    s=Scene(920,760); s.rect(0,0,920,760,'#f2f5fa',BORDER,r=11)
    s.rect(0,0,920,31,ui_ink,r=11); s.text(17,7,'QN90B 区域助手',15,WHITE,True); s.text(891,7,'×',17,WHITE,False,'middle')
    s.text(28,49,'QN90B 区域助手',28,ui_ink,True)
    s.text(28,89,'仅适用于 QA75QN90BAJXXZ · 75 英寸国行 · 固件 1710',16,ui_muted)
    s.rect(27,123,866,127,WHITE,BORDER,r=5)
    s.text(43,142,'电视 IP',17,ui_ink,True); s.rect(159,134,255,32,WHITE,BORDER,r=4); s.text(172,140,'192.168.1.100',17,ui_ink)
    s.rect(428,134,82,32,blue,r=4); s.text(469,140,'保存',17,WHITE,True,'middle')
    s.text(532,142,'电脑与电视需连接同一局域网。',15,ui_muted)
    s.text(43,185,'本机局域网 IP',16,ui_ink,True); s.rect(194,177,540,32,WHITE,BORDER,r=4); s.text(207,183,'192.168.1.10（示例，请填实际地址）',16,ui_ink)
    s.line(712,190,718,196,ui_muted,1.5); s.line(718,196,724,190,ui_muted,1.5)
    s.text(43,222,'Host PC IP 请填电脑地址；多网卡时，选择与电视在同一网络的地址。',15,ui_muted)
    s.rect(27,266,866,125,WHITE,BORDER,r=5)
    s.text(43,280,'当前状态',18,ui_ink,True); s.text(865,280,'尚未检测',19,ui_muted,True,'end')
    s.text(43,315,'Local Set',16,ui_muted); s.text(628,315,'Preventing Import',16,ui_muted)
    s.text(43,341,'尚未读取',20,ui_ink,True); s.text(628,341,'—',20,ui_ink,True)
    s.text(43,371,'备份：检测后显示；已有备份不会覆盖。',14,ui_muted)
    button_labels=['检查 / 安装运行环境','检测当前状态','切换新加坡','恢复国行参数']
    for i,lab in enumerate(button_labels):
        x=27+(i%2)*439; y=408+(i//2)*48
        fill=blue if i==0 else ('#eaf0fc' if i==1 else disabled)
        fg=WHITE if i==0 else (blue if i==1 else ui_muted)
        s.rect(x,y,427,40,fill,r=5); s.text(x+213,y+11,lab,18,fg,True,'middle')
    s.text(28,515,'先准备环境，再检测电视',17,ui_ink,True)
    s.rect(27,545,866,7,disabled,r=3)
    s.rect(27,565,866,86,WHITE,BORDER,r=5)
    s.text(42,580,'打开助手不会连接电视或修改参数。先点击“检查 / 安装运行环境”，',16,ui_muted)
    s.text(42,609,'再点击“检测当前状态”。检测通过后，切换按钮会按状态与原机备份启用。',16,ui_muted)
    for i,lab in enumerate(['导出诊断','查看图文教程','打开备份位置']):
        x=27+i*293; s.rect(x,672,280,37,WHITE,BORDER,r=5); s.text(x+140,681,lab,16,blue,True,'middle')
    s.text(28,736,'图中 IP 仅为示例，请填写实际地址。',12,ui_muted)
    s.caption(); out['assistant']=s

    s=Scene(920,330); s.rect(0,0,920,330,PAPER,r=16)
    s.text(24,20,'点击“检测当前状态”时发生什么',24,INK,True)
    for x,number,title,detail in [
      (24,'1','电脑：准备运行环境','START.cmd → 检查 / 安装运行环境'),
      (476,'2','电视：开启开发者模式','Host PC IP 填电脑地址，并重启电视')
    ]:
        s.rect(x,68,420,78,WHITE,BORDER,r=10); s.circle(x+26,92,13)
        s.text(x+26,82,number,15,WHITE,True,'middle'); s.text(x+49,81,title,19,INK,True)
        s.text(x+17,116,detail,16,MUTED)
        s.arrow(x+210,149,x+210,171)
    s.rect(24,178,872,93,LIGHT,BORDER,r=10)
    s.text(44,195,'3   检测当前状态：自动建立临时 Root 会话',22,TEAL,True)
    s.text(44,235,'连接 SDB  →  验证临时权限  →  只读参数  →  显示当前状态',19,INK)
    s.text(24,292,'任务结束后退出会话；下一次操作会建立新会话。',16,MUTED)
    s.text(901,308,'流程示意 · 非实机截图',12,MUTED,anchor='end'); out['root-flow']=s

    s=Scene(920,238); s.rect(0,0,920,238,PAPER,r=16)
    s.text(24,19,'手动 id 验证：外层进程退出码为 0',23,INK,True)
    s.rect(24,65,421,128,WHITE,BORDER,r=10)
    s.text(42,81,'权限认证',20,INK,True)
    s.text(42,118,'authenticated: true',18,TEAL,True)
    s.text(42,155,'uid: 0   euid: 0   gid: 0   egid: 0',17,INK)
    s.rect(475,65,421,128,WHITE,BORDER,r=10)
    s.text(493,81,'commands：仅 1 条 id',20,INK,True)
    s.text(493,118,'exit_code: 0   timed_out: false',17,TEAL,True)
    s.text(493,155,'stdout: "uid=0(owner) ..."',17,INK)
    s.text(24,210,'清理结果还要另外核对。',15,MUTED)
    s.text(901,214,'字段示意 · 非真实日志',12,MUTED,anchor='end'); out['root-proof']=s

    for name,heading,states_,sub in [
      ('switch','点击一次“切换新加坡”',[('保存原值','保留真实备份'),('按需解锁','CHI_DTV + 0'),('设置并回读','AD_SIN2 + 0')],'从已解锁状态开始时，工具继续执行所需步骤。'),
      ('restore','点击一次“恢复国行参数”',[('核对两份备份','匹配当前电视'),('先恢复 Local Set','CHI_DTV + 0'),('再恢复限制','CHI_DTV + 13')],'顺序由工具完成；任一步失败会停止并报告当前状态。')
    ]:
        s=Scene(920,252); s.rect(0,0,920,252,PAPER,r=16); s.text(24,23,heading,24,INK,True)
        for i,(t,v) in enumerate(states_):
            x=24+i*301; s.rect(x,77,269,102,WHITE,BORDER,r=10); s.text(x+17,94,t,20,INK,True); s.text(x+17,136,v,18,TEAL,True)
            if i<2:s.arrow(x+275,128,x+296,128)
        s.text(24,201,sub,17,MUTED); s.caption(); out[name]=s
    return out

class SceneFlow(Flowable):
    def __init__(self,scene,w):
        super().__init__(); self.scene=scene; self.width=w; self.height=scene.h*w/scene.w
    def draw(self):
        self.canv.saveState(); k=self.width/self.scene.w; self.canv.scale(k,k); renderPDF.draw(self.scene.d,self.canv,0,0); self.canv.restoreState()

def write_svg(s,name):
    content=renderSVG.drawToString(s.d)
    if isinstance(content,bytes): content=content.decode()
    content=content.replace('<defs>','<defs><style>text { font-family: "Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC", sans-serif !important; }</style>',1)
    (ASSETS/(name+'.svg')).write_text(content,encoding='utf-8')

def styles():
    return {
      'eyebrow':ParagraphStyle('eyebrow',fontName=BOLD,fontSize=9.2,leading=13,textColor=C(TEAL),spaceAfter=8,wordWrap='CJK'),
      'title':ParagraphStyle('title',fontName=BOLD,fontSize=25,leading=33,textColor=C(INK),spaceAfter=7,wordWrap='CJK'),
      'subtitle':ParagraphStyle('subtitle',fontName=FONT,fontSize=11,leading=17,textColor=C(MUTED),spaceAfter=17,wordWrap='CJK'),
      'body':ParagraphStyle('body',fontName=FONT,fontSize=10.25,leading=16.5,textColor=C(INK),spaceAfter=10,wordWrap='CJK',splitLongWords=True),
      'small':ParagraphStyle('small',fontName=FONT,fontSize=8.1,leading=12.5,textColor=C(MUTED),spaceAfter=10,wordWrap='CJK',splitLongWords=True),
      'cell':ParagraphStyle('cell',fontName=FONT,fontSize=9.5,leading=15,textColor=C(INK),wordWrap='CJK',splitLongWords=True),
      'head':ParagraphStyle('head',fontName=BOLD,fontSize=9.7,leading=15,textColor=WHITE,wordWrap='CJK'),
      'step':ParagraphStyle('step',fontName=FONT,fontSize=10.1,leading=16,textColor=C(INK),wordWrap='CJK'),
      'source':ParagraphStyle('source',fontName=FONT,fontSize=7.7,leading=10.5,textColor=C(MUTED),wordWrap='CJK',splitLongWords=True,spaceAfter=7),
      'code':ParagraphStyle('code',fontName=FONT,fontSize=8.3,leading=13,textColor=C(INK),wordWrap='CJK',splitLongWords=True),
    }

def footer(c,doc):
    w,h=A4; c.setStrokeColor(C(BORDER)); c.setLineWidth(.6); c.line(40,37,w-40,37)
    c.setFont(FONT,8); c.setFillColor(C(MUTED)); c.drawString(40,22,'QN90B 区域助手 · 本机专用图文指南')
    c.drawRightString(w-40,22,f'{doc.page} / {len(PAGES)}')

def pdf_blocks(block,sty,scene_map):
    kind=block['type']; out=[]; width=A4[0]-80
    if kind=='p': out=[Paragraph(block['text'],sty['body'])]
    elif kind=='figure':
        f=SceneFlow(scene_map[block['name']],min(width,block.get('width',width))); f.hAlign='CENTER'
        out=[f,Spacer(1,6),Paragraph(block['caption'],sty['small'])]
    elif kind=='callout':
        bg=LIGHT if block['tone']=='teal' else BLUE if block['tone']=='blue' else WARM
        txt='<b>'+block['title']+'</b><br/>'+block['text']
        t=Table([[Paragraph(txt,sty['body'])]],colWidths=[width]); t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),C(bg)),('BOX',(0,0),(-1,-1),.5,C(BORDER)),('LEFTPADDING',(0,0),(-1,-1),13),('RIGHTPADDING',(0,0),(-1,-1),13),('TOPPADDING',(0,0),(-1,-1),10),('BOTTOMPADDING',(0,0),(-1,-1),3)])); out=[t,Spacer(1,12)]
    elif kind=='steps':
        rows=[]
        for i,(title,txt) in enumerate(block['items'],1):
            rows.append([Paragraph(f'<b>{i:02d}</b>',sty['eyebrow']),Paragraph('<b>'+title+'</b><br/>'+txt,sty['step'])])
        t=Table(rows,colWidths=[32,width-32]);t.setStyle(TableStyle([('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),0),('RIGHTPADDING',(0,0),(-1,-1),3),('TOPPADDING',(0,0),(-1,-1),2),('BOTTOMPADDING',(0,0),(-1,-1),10)]));out=[t,Spacer(1,4)]
    elif kind=='table':
        ww=block.get('widths') or [1/len(block['head'])]*len(block['head']); data=[[Paragraph(x,sty['head']) for x in block['head']]]
        data += [[Paragraph(x,sty['cell']) for x in row] for row in block['rows']]
        t=Table(data,colWidths=[width*x for x in ww],repeatRows=1);t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,0),C(INK)),('ROWBACKGROUNDS',(0,1),(-1,-1),[C(PAPER),WHITE]),('VALIGN',(0,0),(-1,-1),'TOP'),('LINEBELOW',(0,0),(-1,-1),.5,C(BORDER)),('LEFTPADDING',(0,0),(-1,-1),10),('RIGHTPADDING',(0,0),(-1,-1),10),('TOPPADDING',(0,0),(-1,-1),9),('BOTTOMPADDING',(0,0),(-1,-1),9)]));out=[t,Spacer(1,13)]
    elif kind=='code':
        t=Table([[Paragraph(html.escape(block['text']).replace('\n','<br/>'),sty['code'])]],colWidths=[width]);t.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),C(PAPER)),('BOX',(0,0),(-1,-1),.5,C(BORDER)),('LEFTPADDING',(0,0),(-1,-1),10),('RIGHTPADDING',(0,0),(-1,-1),10),('TOPPADDING',(0,0),(-1,-1),8),('BOTTOMPADDING',(0,0),(-1,-1),8)]));out=[t,Spacer(1,12)]
    elif kind=='sources':
        out.append(Paragraph('<b>官方资料与原始来源</b>',sty['body']))
        for n,title,url in block['items']:
            out.append(Paragraph(f'[{n}] {html.escape(title)}<br/><link href="{html.escape(url,quote=True)}" color="{TEAL}">{html.escape(url)}</link>',sty['source']))
    elif kind=='related':
        out.append(Paragraph('<b>'+block['title']+'</b><br/>'+block['text']+'<br/>'+
          f'<link href="{html.escape(block["href"],quote=True)}" color="{TEAL}">离线：{html.escape(block["href"])}</link>　'+
          f'<link href="{html.escape(block["web"],quote=True)}" color="{TEAL}">GitHub 在线阅读</link>',sty['small']))
    return out

def make_pdf(scene_map):
    pdfmetrics.registerFontFamily(FONT,normal=FONT,bold=BOLD,italic=FONT,boldItalic=BOLD)
    sty=styles(); story=[]
    for index,page in enumerate(PAGES):
        if index:story.append(PageBreak())
        story.extend([Paragraph(page['eyebrow'],sty['eyebrow']),Paragraph(page['title'],sty['title']),Paragraph(page['subtitle'],sty['subtitle'])])
        for block in page['blocks']: story.extend(pdf_blocks(block,sty,scene_map))
    doc=SimpleDocTemplate(str(GUIDE/'QN90B-Guide.pdf'),pagesize=A4,rightMargin=40,leftMargin=40,topMargin=35,bottomMargin=50,title='QN90B 区域助手 - 图文使用指南',author='QN90B 本机参数工具',subject='QA75QN90BAJXXZ 固件1710 图文指南',pageCompression=1)
    doc.build(story,onFirstPage=footer,onLaterPages=footer)

def html_block(b):
    k=b['type']
    if k=='p':return '<p>'+b['text']+'</p>'
    if k=='figure':return f'<figure><img src="assets/{b["name"]}.svg" alt="{html.escape(b["caption"])}" loading="lazy"><figcaption>{b["caption"]}</figcaption></figure>'
    if k=='callout':return f'<aside class="callout {b["tone"]}"><h3>{b["title"]}</h3><p>{b["text"]}</p></aside>'
    if k=='steps':return '<ol class="steps">'+''.join(f'<li><h3>{a}</h3><p>{t}</p></li>' for a,t in b['items'])+'</ol>'
    if k=='table':return '<div class="table-wrap"><table><thead><tr>'+''.join('<th>'+x+'</th>' for x in b['head'])+'</tr></thead><tbody>'+''.join('<tr>'+''.join('<td>'+x+'</td>' for x in row)+'</tr>' for row in b['rows'])+'</tbody></table></div>'
    if k=='code':return '<pre><code>'+html.escape(b['text'])+'</code></pre>'
    if k=='sources':return '<h3 class="sources-title">官方资料与原始来源</h3><ol class="sources">'+''.join(f'<li id="source-{n}"><strong>[{n}] {title}</strong><a href="{url}" target="_blank" rel="noopener noreferrer">{url}</a></li>' for n,title,url in b['items'])+'</ol>'
    if k=='related':return '<aside class="callout blue"><h3>'+b['title']+'</h3><p>'+b['text']+'</p><a href="'+html.escape(b['href'],quote=True)+'">打开完整 Root 教程与命令</a></aside>'
    return ''

CSS='''
:root{--ink:#15283e;--muted:#536679;--teal:#0c7e78;--line:#d5e0e8;--paper:#f5f8fb}*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:#eef3f7;font:16px/1.8 "Microsoft YaHei","Noto Sans CJK SC","PingFang SC",sans-serif}a{color:var(--teal);text-underline-offset:3px}.topbar{background:#15283e;color:white;padding:20px max(24px,calc((100vw - 1180px)/2));display:flex;align-items:center;justify-content:space-between;gap:24px}.brand{font-size:20px;font-weight:750}.topbar small{display:block;color:#c3d2df;font-size:12px;letter-spacing:.4px}.pdf-link{display:inline-block;color:white;text-decoration:none;border:1px solid #66848f;border-radius:10px;padding:8px 16px;white-space:nowrap}.layout{max-width:1220px;margin:32px auto;display:grid;grid-template-columns:215px minmax(0,1fr);gap:24px;padding:0 20px}.sidebar{position:sticky;top:20px;align-self:start}.sidebar strong{display:block;margin:0 12px 12px;color:var(--muted);font-size:13px}.sidebar a{display:block;text-decoration:none;color:var(--ink);padding:10px 12px;margin:4px 0;border-radius:9px;font-size:14px}.sidebar a:hover,.sidebar a.active{background:#dceeea;color:var(--teal)}.sidebar .note{font-size:12px;color:var(--muted);padding:12px}.page{background:white;border:1px solid var(--line);border-radius:18px;padding:34px 42px;margin-bottom:28px;scroll-margin-top:20px;box-shadow:0 10px 25px rgba(21,40,62,.025)}.eyebrow{font-size:12px;font-weight:bold;color:var(--teal);letter-spacing:1.5px;margin-bottom:8px}h1,h2{font-size:29px;line-height:1.35;letter-spacing:-.5px;margin:0 0 10px}h3{font-size:17px;line-height:1.5;margin:0 0 6px}.subtitle{font-size:16px;color:var(--muted);margin:0 0 24px}p{margin:0 0 18px}figure{margin:22px 0}figure img{display:block;width:100%;height:auto;border-radius:12px}figure:has(img[src$="assistant.svg"]){max-width:660px;margin-left:auto;margin-right:auto}figcaption{font-size:12px;line-height:1.6;color:var(--muted);margin-top:9px}.callout{background:#e8f5f2;border-left:4px solid var(--teal);padding:17px 20px;border-radius:0 12px 12px 0;margin:22px 0}.callout p{margin:0}.callout.blue{background:#edf3fb;border-color:#708ba9}.steps{list-style:none;counter-reset:step;padding:0;margin:24px 0}.steps li{counter-increment:step;position:relative;padding-left:47px;margin-bottom:22px}.steps li:before{content:counter(step,decimal-leading-zero);position:absolute;left:0;top:0;font-weight:bold;font-size:15px;color:var(--teal);background:#e8f5f2;width:32px;height:32px;line-height:32px;text-align:center;border-radius:8px}.steps p{margin:0}.table-wrap{overflow-x:auto;margin:22px 0}table{border-collapse:collapse;width:100%;font-size:14px;line-height:1.75;min-width:450px}th{background:var(--ink);color:white;text-align:left;padding:13px 15px;font-weight:600}td{padding:13px 15px;vertical-align:top;border-bottom:1px solid var(--line)}td:first-child{width:29%;font-weight:600}tr:nth-child(odd) td{background:var(--paper)}pre{background:var(--paper);border:1px solid var(--line);padding:16px;border-radius:10px;font:13px/1.8 Consolas,monospace;white-space:pre-wrap;overflow-wrap:anywhere}.sources{list-style:none;padding:0;font-size:12px;line-height:1.65;overflow-wrap:anywhere}.sources li{margin-bottom:13px}.sources strong,.sources a{display:block}.sources-title{margin-top:26px}.footer{text-align:center;padding:12px 20px 36px;font-size:12px;color:var(--muted)}.top-link{display:block;text-align:right;font-size:12px;text-decoration:none;margin-top:22px}@media(max-width:800px){.layout{display:block;margin-top:18px;padding:0 12px}.sidebar{position:static;display:flex;overflow:auto;gap:3px;margin-bottom:16px;padding-bottom:4px}.sidebar strong,.sidebar .note{display:none}.sidebar a{white-space:nowrap;padding:8px 12px;font-size:12px;background:white;border:1px solid var(--line)}.page{padding:25px 22px;border-radius:14px}.topbar{padding:17px 20px}.brand{font-size:18px}.topbar small{font-size:10px}.pdf-link{padding:7px 10px;font-size:12px}h1,h2{font-size:25px}body{font-size:15px}.steps li{padding-left:42px}.table-wrap{margin:18px -5px}table{min-width:390px;font-size:13px}.callout{padding:14px 16px}}@media print{body{background:white}.topbar,.sidebar,.footer,.top-link{display:none}.layout{display:block;margin:0;padding:0}.page{box-shadow:none;border:0;border-radius:0;padding:0;page-break-after:always;break-after:page}.page:last-child{page-break-after:auto}.table-wrap{overflow:visible}figure img{max-height:115mm}a{color:inherit}h1,h2{font-size:24px}}
'''

def make_html():
    nav=''.join(f'<a href="#{p["id"]}">{p["eyebrow"]}</a>' for p in PAGES)
    sections=[]
    for i,page in enumerate(PAGES):
        tag='h1' if i==0 else 'h2'
        sections.append(f'<section class="page" id="{page["id"]}"><div class="eyebrow">{page["eyebrow"]}</div><{tag}>{page["title"]}</{tag}><p class="subtitle">{page["subtitle"]}</p>'+''.join(html_block(b) for b in page['blocks'])+'<a class="top-link" href="#top">回到顶部 ↑</a></section>')
    doc='''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light"><title>QN90B 区域助手 · 图文使用指南</title><style>'''+CSS+'''</style></head><body id="top"><header class="topbar"><div class="brand">QN90B 区域助手<small>QA75QN90BAJXXZ · 75 英寸国行 · 固件 1710</small></div><a class="pdf-link" href="QN90B-Guide.pdf">打开 PDF / 打印</a></header><div class="layout"><nav class="sidebar" aria-label="教程目录"><strong>按步骤查阅</strong>'''+nav+'''<div class="note">本页可离线阅读。外部参考链接需要联网。</div></nav><main>'''+''.join(sections)+'''</main></div><footer class="footer">2026-11-18 · 本机专用指南 · 所有插图均为示意，非实机截图</footer><script>const pages=document.querySelectorAll('.page');const links=document.querySelectorAll('.sidebar a');if('IntersectionObserver' in window){new IntersectionObserver(entries=>{for(const e of entries){if(e.isIntersecting){links.forEach(a=>a.classList.toggle('active',a.hash==='#'+e.target.id));}}},{rootMargin:'-10% 0px -70% 0px'}).observe(pages[0]);const ob=new IntersectionObserver(es=>{es.forEach(e=>{if(e.isIntersecting)links.forEach(a=>a.classList.toggle('active',a.hash==='#'+e.target.id))})},{rootMargin:'-10% 0px -70% 0px'});pages.forEach(p=>ob.observe(p));}</script></body></html>'''
    (GUIDE/'index.html').write_text(doc,encoding='utf-8')

def main():
    make_font('Regular'); make_font('Bold')
    scene_map=scenes()
    for name,s in scene_map.items():write_svg(s,name)
    make_pdf(scene_map); make_html()
    (HERE/'content.json').write_text(json.dumps(PAGES,ensure_ascii=False,indent=2),encoding='utf-8')
    print('Created',GUIDE/'QN90B-Guide.pdf')
    print('Created',GUIDE/'index.html')

if __name__=='__main__':main()
