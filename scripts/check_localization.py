#!/usr/bin/env python3
"""檢查介面字串都有英文翻譯。

- PaperNote/ 裡含中文字的字串常值都要包在 L("…") 裡（除錯紀錄、多行字串等例外）。
- 每個 L("…") 的 key 都要在 PaperNote/Resources/LocalizedEnglish.json 裡，插入值的數量要一樣。
- 表裡不能有程式已經沒在用的 key。

用法：python3 scripts/check_localization.py（在 repo 根目錄）
"""
import glob
import json
import re
import sys

TABLE = "PaperNote/Resources/LocalizedEnglish.json"
IDEO = re.compile(r"[㐀-鿿]")
PH = re.compile(r"%(?:\d+\$)?@")
# 這些行的字串不給使用者看
SKIP_LINE = re.compile(r"DebugLog\.|uiTestTrace|\bprint\(|fatalError\(|assert\(|assertionFailure\(|precondition\(|NSLog\(")
SKIP_FILES = {"PaperNote/Util/DebugLog.swift"}
# 刻意不翻譯：字體範例、語言名稱本身
SKIP_TEXT = {"永字八法 Aa 123", "語言 Language", "繁體中文"}


class Lit:
    def __init__(self, start, end, parts, children):
        self.start, self.end, self.parts, self.children = start, end, parts, children


def scan_code(src, i, stop_paren):
    lits, depth, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            i = n if j < 0 else j + 3
        elif src.startswith('#"', i):
            j = src.find('"#', i + 2)
            i = n if j < 0 else j + 2
        elif c == '"':
            lit, i = scan_string(src, i)
            lits.append(lit)
        else:
            if stop_paren:
                if c == "(":
                    depth += 1
                elif c == ")":
                    if depth == 0:
                        return i + 1, lits
                    depth -= 1
            i += 1
    return i, lits


def scan_string(src, i):
    start, parts, children, buf = i, [], [], ""
    i += 1
    while True:
        c = src[i]
        if c == "\\":
            if src[i + 1] == "(":
                parts += [buf, None]
                buf = ""
                i, inner = scan_code(src, i + 2, True)
                children += inner
                continue
            buf += src[i:i + 2]
            i += 2
            continue
        if c == '"':
            parts.append(buf)
            return Lit(start, i + 1, parts, children), i + 1
        if c == "\n":
            raise ValueError(f"unterminated string at offset {start}")
        buf += c
        i += 1


ESC = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\":
            if s[i + 1] == "u":
                j = s.index("}", i)
                out.append(chr(int(s[i + 3:j], 16)))
                i = j + 1
                continue
            out.append(ESC[s[i + 1]])
            i += 2
            continue
        out.append(s[i])
        i += 1
    return "".join(out)


def main():
    table = json.load(open(TABLE, encoding="utf-8"))
    errors, used = [], set()
    for path in sorted(glob.glob("PaperNote/**/*.swift", recursive=True)):
        path = path.replace("\\", "/")
        if path in SKIP_FILES:
            continue
        src = open(path, encoding="utf-8").read()
        _, lits = scan_code(src, 0, False)

        def visit(lit):
            for ch in lit.children:
                visit(ch)
            text = "".join(p for p in lit.parts if p is not None)
            if not IDEO.search(text):
                return
            key = unescape("".join("%@" if p is None else p for p in lit.parts))
            if key in SKIP_TEXT:
                return
            line_no = src.count("\n", 0, lit.start) + 1
            ls = src.rfind("\n", 0, lit.start) + 1
            le = src.find("\n", lit.start)
            if SKIP_LINE.search(src[ls:le]):
                return
            where = f"{path}:{line_no}"
            if src[max(0, lit.start - 2):lit.start] != "L(":
                errors.append(f"{where}: 中文字串沒有包在 L(…) 裡：{key!r}")
                return
            used.add(key)
            if key not in table:
                errors.append(f"{where}: 沒有英文翻譯：{key!r}")
            elif len(PH.findall(key)) != len(PH.findall(table[key])):
                errors.append(f"{where}: 插入值數量和譯文不同：{key!r} → {table[key]!r}")

        for lit in lits:
            visit(lit)
    for k in sorted(set(table) - used):
        errors.append(f"{TABLE}: 程式沒有用到的 key：{k!r}")
    for e in errors:
        print(e)
    print(f"{len(used)} keys, {len(errors)} problems")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
