from pathlib import Path
import sys
from pypdf import PdfReader

pdf = Path(sys.argv[1])
out = Path(sys.argv[2])

reader = PdfReader(str(pdf))
parts = []
for i, page in enumerate(reader.pages, start=1):
    try:
        text = page.extract_text() or ""
    except Exception as e:
        text = f"[EXTRACTION ERROR ON PAGE {i}: {e}]"
    parts.append(f"===== PAGE {i} =====\n{text}\n")

out.write_text("\n".join(parts), encoding="utf-8")
print(out)
