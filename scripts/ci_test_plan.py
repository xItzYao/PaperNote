#!/usr/bin/env python3
"""CI 要跑哪些測試、分成幾台一起跑。

什麼都沒指定：全部，單元測試、UI 測試各分兩台。第二台跑 SECOND 列出來的，第一台跑其他全部，
所以新加的測試不用登記也一定會跑到。
指定了 ONLY（手動執行的 only 欄位，逗號分開）：只跑那幾個，例如
    PaperNoteTests/SelectInkTests,PaperNoteUITests/SharePDFUITests

用法：ONLY=... python3 scripts/ci_test_plan.py（在 repo 根目錄）
"""
import glob
import json
import os
import re
import sys

# 最花時間的幾個類別：讓兩台差不多久（用 11/22 CI 上每個類別的秒數分的）
SECOND = {
    "PaperNoteTests": ["HoldToLineFlowTests", "CircuitEditingTests", "EditorRequestsNov15Tests",
                       "TableEditorUXTests", "CircuitGroupTests", "PenFontSymbolTests"],
    "PaperNoteUITests": ["HighlighterUndoUITests", "ScrollAfterMenuUITests", "SharePDFUITests"],
}
SHORT = {"PaperNoteTests": "unit", "PaperNoteUITests": "ui"}
# 會放進命令列：只收這個格式
NAME = re.compile(r"(PaperNoteTests|PaperNoteUITests)(?:/([A-Za-z0-9_]+)(?:/([A-Za-z0-9_]+))?)?")


def check_exists(bundle, cls=None, method=None):
    if cls is None:
        return
    text = "\n".join(open(f, encoding="utf-8").read() for f in glob.glob(f"Tests/{bundle}/*.swift"))
    if not re.search(rf"\bclass {cls}\b", text):
        sys.exit(f"找不到測試類別 {bundle}/{cls}（改名了就要改 scripts/ci_test_plan.py）")
    if method and not re.search(rf"\bfunc {method}\(", text):
        sys.exit(f"找不到測試 {bundle}/{cls}/{method}")


def everything():
    jobs = []
    for bundle, second in SECOND.items():
        for cls in second:
            check_exists(bundle, cls)
        names = [f"{bundle}/{cls}" for cls in second]
        jobs.append({"name": f"{SHORT[bundle]}-1", "scheme": bundle,
                     "args": " ".join([f"-only-testing:{bundle}"] + [f"-skip-testing:{n}" for n in names])})
        jobs.append({"name": f"{SHORT[bundle]}-2", "scheme": bundle,
                     "args": " ".join(f"-only-testing:{n}" for n in names)})
    return jobs


def chosen(only):
    wanted = {}
    for item in filter(None, (x.strip() for x in only.split(","))):
        m = NAME.fullmatch(item)
        if not m:
            sys.exit(f"看不懂要跑哪個測試：{item}")
        check_exists(*m.groups())
        wanted.setdefault(m.group(1), []).append(f"-only-testing:{item}")
    if not wanted:
        sys.exit("only 裡沒有測試")
    return [{"name": f"{SHORT[b]}-only", "scheme": b, "args": " ".join(a)} for b, a in wanted.items()]


def main():
    only = os.environ.get("ONLY", "").strip()
    line = "matrix=" + json.dumps({"include": chosen(only) if only else everything()})
    print(line)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(line + "\n")


if __name__ == "__main__":
    main()
