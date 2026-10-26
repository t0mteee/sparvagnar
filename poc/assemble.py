import sys
from pathlib import Path
mall, ut_dir, mal = sys.argv[1:4]
s = Path(mall).read_text()
svg = Path(ut_dir, "karta.svg").read_text()
data = Path(ut_dir, "data.json").read_text()
assert "</script" not in data
s = s.replace("__SVG__", svg, 1).replace("__DATA__", data, 1)
Path(mal).write_text(s)
print(Path(mal).stat().st_size // 1000, "kB")
