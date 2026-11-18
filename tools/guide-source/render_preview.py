#!/usr/bin/env python3
"""Render the exact vector UI illustration to PNG; no TV or network calls."""
from pathlib import Path
import importlib.util
import json
from html.parser import HTMLParser
import fitz
from reportlab.graphics import renderPDF

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
GUIDE = ROOT / "guide"
QA = ROOT.parent / (ROOT.name + "-guide-review")
QA.mkdir(exist_ok=True)
spec = importlib.util.spec_from_file_location("guide_source", HERE / "create_guide.py")
guide = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guide)
guide.make_font("Regular")
guide.make_font("Bold")
scene = guide.scenes()["assistant"]
artboard = QA / "assistant-vector.pdf"
renderPDF.drawToFile(scene.d, str(artboard))
with fitz.open(artboard) as pdf:
    pdf[0].get_pixmap(matrix=fitz.Matrix(1.5,1.5), alpha=False).save(GUIDE / "assets/assistant.png")

class GuideParser(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids=[]; self.local=[]; self.images=[]
    def handle_starttag(self, tag, attrs):
        attrs=dict(attrs)
        if "id" in attrs:self.ids.append(attrs["id"])
        if tag=="img":self.images.append(attrs.get("src",""))
        if tag=="a" and not attrs.get("href","").startswith("http"):
            self.local.append(attrs.get("href",""))

parser=GuideParser()
parser.feed((GUIDE / "index.html").read_text(encoding="utf-8"))
missing_assets=[p for p in parser.images if not (GUIDE/p).is_file()]
bad_links=[p for p in parser.local if (p.startswith("#") and p[1:] not in parser.ids) or (not p.startswith("#") and not (GUIDE/p).is_file())]
result={"png":"guide/assets/assistant.png","rendering":"original vector illustration rendered through PDF; no screenshot editing","sections":len(guide.PAGES),"missingAssets":missing_assets,"brokenLocalLinks":bad_links,"duplicateIds":len(parser.ids)!=len(set(parser.ids)),"browserRender":"not run; local Chromium unavailable in sandbox"}
(QA / "guide-validation.json").write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
assert not missing_assets and not bad_links and len(parser.ids)==len(set(parser.ids))
print(json.dumps(result,ensure_ascii=False))
