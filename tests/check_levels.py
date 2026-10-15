"""Generate thousands of problems from every level (regular and boss) and check them.

    python3 tests/check_levels.py          # needs node on PATH

Checks: the answer is right, nothing is negative (answers, wrong choices, left-to-right
intermediate steps), wrong ≠ right, every problem has a time budget, "no carry" levels never
carry and "carry" levels always do, digit/remainder rules per level, and the parachute's
replacement wrong answer and the magnifier hint are valid.
"""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PER_KIND = 4000

CHECKS = r"""
const ev = e => Function('return ' + e.replace(/×/g, '*').replace(/÷/g, '/').replace(/−/g, '-'))();
const val = side => side.includes('…') ? side
  : (/^\d+ ÷ \d+$/.test(side) && ev(side) % 1 !== 0) ? (() => { const [x, y] = side.split(' ÷ ').map(Number); return fmtQR(Math.floor(x / y), x % y); })()
  : String(ev(side));
const holds = (l, r, ans) => val(l.replace('?', ans)) === val(r.replace('?', ans));
const chainOk = t => { if (/[×÷(]/.test(t)) return true; const tk = t.split(' '); let v = +tk[0];
  for (let i = 1; i < tk.length; i += 2) { v = tk[i] === '+' ? v + +tk[i + 1] : v - +tk[i + 1]; if (v < 0) return false; } return true; };
const pair = t => { const m = t.match(/^(\d+) ([+−×]) (\d+) = \?$/); return m && [+m[1], m[2], +m[3]]; };
let bad = 0;
for (const L of LEVELS) for (const kind of ['gen', 'boss']) {
  for (let i = 0; i < PER_KIND; i++) {
    const q = L[kind](), [l, r] = q.text.split(' = '), errs = [];
    if (!holds(l, r, q.ans)) errs.push('wrong answer');
    if (/-/.test(q.ans + q.wrong) || /NaN|undefined/.test(q.ans + q.wrong)) errs.push('negative/invalid');
    if (q.wrong === q.ans) errs.push('wrong choice equals answer');
    if (!(q.t > 0)) errs.push('no time budget');
    if (!chainOk(l.replace('?', q.ans))) errs.push('negative intermediate');
    const alt = altWrong(q, q.wrong);
    if (!alt || alt === q.ans || alt === q.wrong || /-|NaN|undefined/.test(alt)) errs.push('bad parachute choice');
    if (!estimate(q.ans)) errs.push('no hint');
    const p = kind === 'gen' && pair(q.text);
    if (p && [3, 5].includes(L.n)) { const [x, op, y] = p; if (op === '+' ? !noCarry(x, y) : !noBorrow(x, y)) errs.push('has carry/borrow'); }
    if (p && L.n === 6) { const [x, op, y] = p; if (op === '+' ? !onesCarry(x, y) : !onesBorrow(x, y)) errs.push('missing carry/borrow'); }
    if (p && L.n === 4 && !q.text.includes('10')) { const [x, op, y] = p; if (op === '+' ? x + y < 10 : x < 10) errs.push('missing carry'); }
    if ([1, 3].includes(L.n) && kind === 'gen' && +q.ans > 9) errs.push('over 9');
    if (p && [8, 9, 10].includes(L.n) && p[0] === 1) errs.push('looks like 1단');
    if (p && L.n === 8 && Math.min(p[0], p[2]) > 5) errs.push('outside 2~5단');
    if (p && L.n === 9 && Math.max(p[0], p[2]) < 6) errs.push('outside 6~9단');
    if (L.n === 17 && kind === 'gen' && (!q.ans.includes('…') || parseInt(q.ans) > 9)) errs.push('needs a one-digit quotient with a remainder');
    if (L.n === 18 && kind === 'gen' && parseInt(q.ans) < 10) errs.push('needs a two-digit quotient');
    if (errs.length) { bad++; if (bad <= 20) console.log('BAD', 'Lv.' + L.n, kind, JSON.stringify(q), errs.join(', ')); }
  }
}
console.log(`${LEVELS.length} levels, ${LEVELS.length * 2 * PER_KIND} problems checked, ${bad} bad`);
process.exit(bad ? 1 : 0);
"""


def main() -> int:
    src = (ROOT / "src/game.html").read_text(encoding="utf-8")
    start = src.index("const R = (a, b)")
    end = src.index("// ---------- flow ----------")
    is_num = src[src.index("const isNum"):].split("\n", 1)[0]
    script = "\n".join([
        "let S = { score: 0 }, level = '1', easy = false;",
        f"const PER_KIND = {PER_KIND};",
        src[start:end],
        is_num,
        CHECKS,
    ])
    return subprocess.run(["node", "-e", script]).returncode


if __name__ == "__main__":
    sys.exit(main())
