from pathlib import Path
import json, sys
from pypdf import PdfReader

for arg in sys.argv[1:]:
    p = Path(arg)
    r = PdfReader(str(p))
    m = r.metadata or {}
    print(json.dumps({
        "file": p.name,
        "pages": len(r.pages),
        "title": m.get("/Title"),
        "author": m.get("/Author"),
        "subject": m.get("/Subject"),
        "creator": m.get("/Creator"),
        "producer": m.get("/Producer"),
    }, ensure_ascii=False))
