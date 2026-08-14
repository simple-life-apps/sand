import os
from pathlib import Path

url = os.environ["URL"]
sha = os.environ["SHA"]
path = Path(os.environ["FORMULA_PATH"])
lines = path.read_text().splitlines()
filtered = [
    line
    for line in lines
    if not line.lstrip().startswith(("url ", "sha256 "))
]
out = []
inserted = False
for line in filtered:
    out.append(line)
    if line.lstrip().startswith("homepage ") and not inserted:
        out.append(f'  url "{url}"')
        out.append(f'  sha256 "{sha}"')
        inserted = True
if not inserted:
    raise SystemExit("homepage not found")
path.write_text("\n".join(out) + "\n")
