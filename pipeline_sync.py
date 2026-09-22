#!/usr/bin/env python3
"""pipeline_sync.py — push ONE pipeline's script to selected TrueWatch workspaces,
with per-site token validation, a diff, and a y/Enter confirm before each write.

Self-contained: standard library only (no pip installs, no vendor CLI). Each site is
reached through its own workspace DF-API-KEY against <region>-openapi.truewatch.com.

It ONLY ever touches the ONE pipeline you name, on the sites you pick. Every other
pipeline and every unselected site is left untouched.

Usage:
  python3 pipeline_sync.py [--config config.json] --pipeline <name> --file <new-script.ppl>
  python3 pipeline_sync.py [--config config.json] --rollback
  python3 pipeline_sync.py --dry-run ...   # same flow, no backup, no POST
  --config defaults to ./config.json; --pipeline/--file are prompted if omitted.
  Sites are chosen after the annotated list — there is no --sites flag.
  Before every confirmed write, the current script is saved under
  <config-dir>/backups/<YYYY-MM-DDTHH-MM-SS>/. --rollback lists those folders
  and restores one after the same per-site diff + y/n/q confirm.
  --dry-run walks that path and prints diffs, but never writes.

Config: a JSON array, one entry per workspace. See config.example.json.
  [{ "n":0,"region":"id1","ws_name":"dev-test","host":"id1-openapi.truewatch.com","token":"<DF-API-KEY>" }, ...]
  - order matters: put dev/test at n=0, then least-impact -> most-impact.
  - token is YOUR per-workspace DF-API-KEY (Personal API Key -> Key(Secret)); one token = one workspace.
"""

import argparse
import base64
import difflib
import json
import os
import re
import sys
import urllib.parse
import urllib.request
import urllib.error
from datetime import datetime


def ask(prompt):
    """Read one line from the user. Falls back cleanly under a pipe."""
    try:
        return input(prompt).strip()
    except EOFError:
        return ""


def api(host, token, method, path, body=None):
    """Return (status_code, parsed_json_or_None). Never raises on HTTP error."""
    url = "https://%s%s" % (host, path)
    data = None
    headers = {"DF-API-KEY": token}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", "replace")
            code = resp.status
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        code = e.code
    except urllib.error.URLError:
        return 0, None
    try:
        return code, json.loads(raw)
    except ValueError:
        return code, None


def find_by_name(host, token, name):
    """Resolve pipeline name -> list of matching entries (exact name), local then central."""
    q = urllib.parse.quote(name, safe="")
    for ptype in ("local", "central"):
        code, js = api(host, token, "GET", "/api/v1/pipeline/list?type=%s&search=%s" % (ptype, q))
        rows = (((js or {}).get("content") or {}).get("data")) or []
        matches = [r for r in rows if r.get("name") == name]
        if matches:
            return matches
    return []


GRAY, STRIKE, RESET = "\033[90m", "\033[9m", "\033[0m"


def paint(text, disabled):
    """Grey + strikethrough when the site cannot be chosen; plain text if not a tty."""
    if not disabled or not sys.stdout.isatty():
        return text
    return "%s%s%s%s" % (GRAY, STRIKE, text, RESET)


def classify_site(e, pipeline):
    """Probe token then exact pipeline name. Returns (kind, note, selectable)."""
    token = e.get("token") or ""
    if not token:
        return "no_token", "token 未填，不可選", False
    code, _ = api(e["host"], token, "GET", "/api/v1/checker/list?pageIndex=1&pageSize=1")
    if code != 200:
        return "bad_token", "token 無效或站點不通 (HTTP %s)，不可選" % code, False
    matches = find_by_name(e["host"], token, pipeline)
    n = len(matches)
    if n == 1:
        return "ok", "✔ 有這條", True
    if n == 0:
        return "missing", "✘ 沒有這條，不可選", False
    return "ambiguous", "✘ 同名 %d 條，不可選" % n, False


def unique_in_order(nums):
    """First occurrence wins. A repeated site id must not be applied twice."""
    seen = set()
    out = []
    for n in nums:
        if n in seen:
            continue
        seen.add(n)
        out.append(n)
    return out


def parse_site_picks(raw, scanned):
    """Map typed n / all onto selectable rows. Unusable ids are ignored, not fatal."""
    by_n = {row["n"]: row for row in scanned}
    if raw.strip() == "all":
        wanted = unique_in_order(row["n"] for row in scanned)
    else:
        wanted = []
        for tok in raw.replace(",", " ").split():
            try:
                wanted.append(int(tok))
            except ValueError:
                sys.exit("站編號不是數字: %s" % tok)
        wanted = unique_in_order(wanted)
    chosen, ignored = [], []
    for n in wanted:
        row = by_n.get(n)
        if row is None:
            ignored.append("%s（config 沒有）" % n)
        elif not row["selectable"]:
            ignored.append("%s（%s）" % (n, row["note"]))
        else:
            chosen.append(row["entry"])
    return chosen, ignored


STAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$")


def backups_root(config_path):
    """Timestamp folders live in <config-dir>/backups/ — next to the operator's config."""
    cfg = os.path.abspath(config_path)
    return os.path.join(os.path.dirname(cfg), "backups")


def new_stamp():
    return datetime.now().strftime("%Y-%m-%dT%H-%M-%S")


def is_safe_stamp(name):
    if not isinstance(name, str) or not name:
        return False
    if "/" in name or "\\" in name or name in (".", ".."):
        return False
    return bool(STAMP_RE.match(name))


def is_safe_script_file(name):
    if not isinstance(name, str) or not name:
        return False
    if "/" in name or "\\" in name or ".." in name or name in (".", ".."):
        return False
    return name.endswith(".ppl")


def site_script_name(entry):
    def slug(s):
        cleaned = re.sub(r"[^A-Za-z0-9._-]+", "_", str(s or ""))
        return cleaned[:80] or "x"
    n = entry.get("n")
    n_part = str(n) if n is not None and n != "" else "x"
    return "%s-%s-%s.ppl" % (n_part, slug(entry.get("region")), slug(entry.get("ws_name")))


def site_record(entry, uuid, script_file, cur):
    """Metadata needed to restore a write. Never includes the token."""
    return {
        "n": entry.get("n"),
        "region": entry.get("region"),
        "ws_name": entry.get("ws_name"),
        "host": entry.get("host"),
        "uuid": uuid,
        "script_file": script_file,
        "name": cur.get("name"),
        "type": cur.get("type") or "local",
        "category": cur.get("category") or "logging",
        "source": cur.get("source") or [],
        "asDefault": int(cur.get("asDefault") or 0),
        "testData": (cur.get("testData") or "").replace("\n", "") or "W10=",
    }


def save_site_backup(root, stamp, entry, pipeline, uuid, cur, cur_script):
    """Write one site's current script into backups/<stamp>/. Returns the folder path."""
    if not is_safe_stamp(stamp):
        raise ValueError("unsafe backup stamp: %r" % stamp)
    folder = os.path.join(root, stamp)
    os.makedirs(folder, exist_ok=True)
    fname = site_script_name(entry)
    if not is_safe_script_file(fname):
        raise ValueError("unsafe backup filename: %r" % fname)
    with open(os.path.join(folder, fname), "w", encoding="utf-8") as f:
        f.write(cur_script)
    man_path = os.path.join(folder, "manifest.json")
    if os.path.isfile(man_path):
        with open(man_path, "r", encoding="utf-8") as f:
            man = json.load(f)
        if not isinstance(man, dict):
            man = {}
    else:
        man = {}
    sites = [s for s in (man.get("sites") or []) if isinstance(s, dict) and s.get("n") != entry.get("n")]
    sites.append(site_record(entry, uuid, fname, cur))
    man = {
        "stamp": stamp,
        "pipeline": pipeline,
        "sites": sites,
    }
    with open(man_path, "w", encoding="utf-8") as f:
        json.dump(man, f, indent=2, ensure_ascii=False)
        f.write("\n")
    return folder


def list_backup_runs(root):
    """Newest-first list of {stamp, pipeline, sites, path}. Skips junk / unsafe names."""
    if not os.path.isdir(root):
        return []
    runs = []
    for name in os.listdir(root):
        if not is_safe_stamp(name):
            continue
        path = os.path.join(root, name)
        if os.path.islink(path) or not os.path.isdir(path):
            continue
        man_path = os.path.join(path, "manifest.json")
        if not os.path.isfile(man_path):
            continue
        try:
            with open(man_path, "r", encoding="utf-8") as f:
                man = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(man, dict):
            continue
        sites = man.get("sites") if isinstance(man.get("sites"), list) else []
        runs.append({
            "stamp": name,
            "pipeline": man.get("pipeline") or "",
            "sites": [s for s in sites if isinstance(s, dict)],
            "path": path,
        })
    runs.sort(key=lambda r: r["stamp"], reverse=True)
    return runs


def parse_backup_pick(raw, runs):
    """Map a typed list index or stamp onto one run. Unsafe paths are rejected."""
    text = (raw or "").strip()
    if not text:
        sys.exit("沒有選到備份。")
    if "/" in text or "\\" in text or text in (".", ".."):
        sys.exit("備份編號不合法。")
    if re.match(r"^-?\d+$", text):
        idx = int(text)
        if idx < 0 or idx >= len(runs):
            sys.exit("沒有這個備份編號: %s" % text)
        return runs[idx]
    if not is_safe_stamp(text):
        sys.exit("備份編號不合法。")
    for run in runs:
        if run["stamp"] == text:
            return run
    sys.exit("沒有這個備份: %s" % text)


def print_backup_list(runs):
    print("== 既有備份 ==")
    if not runs:
        return
    for i, run in enumerate(runs):
        parts = []
        for s in run["sites"]:
            parts.append("%s)%s/%s" % (s.get("n"), s.get("region"), s.get("ws_name")))
        sites = ", ".join(parts) if parts else "（沒有站）"
        print("  %s) %s  pipeline=%s  站: %s" % (i, run["stamp"], run["pipeline"] or "?", sites))
    print()


def format_diff(cur_script, new_script):
    if cur_script == new_script:
        print("  （無差異，內容相同）")
        return
    diff = difflib.unified_diff(
        cur_script.splitlines(), new_script.splitlines(),
        fromfile="current", tofile="new", lineterm="")
    for line in diff:
        print("  " + line)


def post_modify(host, token, uuid, cur, new_script):
    new_b64 = base64.b64encode(new_script.encode("utf-8")).decode("ascii")
    old_td = (cur.get("testData") or "").replace("\n", "") or "W10="
    body = {
        "name": cur.get("name"),
        "type": cur.get("type") or "local",
        "category": cur.get("category") or "logging",
        "source": cur.get("source") or [],
        "asDefault": int(cur.get("asDefault") or 0),
        "content": new_b64,
        "testData": old_td,
    }
    return api(host, token, "POST", "/api/v1/pipeline/%s/modify" % uuid, body)


def decode_script(cur):
    cur_b64 = cur.get("content") or ""
    try:
        return base64.b64decode(cur_b64.replace("\n", "")).decode("utf-8", "replace")
    except Exception:
        return ""


def load_config(config_path):
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            entries = json.load(f)
    except FileNotFoundError:
        sys.exit("config not found: %s （把 config.example.json 複製成 config.json 並填入 token）" % config_path)
    except ValueError:
        sys.exit("config is not valid JSON: %s" % config_path)
    if not isinstance(entries, list) or not entries:
        sys.exit("config must be a non-empty JSON array")
    return entries


def confirm_and_write(e, pipeline, uuid, cur, cur_script, new_script, backups_dir, run_stamp, action, dry_run=False):
    """Show diff, ask y/n/q, snapshot, POST. Returns ('ok'|'skip'|'quit'|'fail'|'dry', stamp)."""
    name = "%s/%s" % (e.get("region"), e.get("ws_name"))
    print("  pipeline: %s  (uuid %s)" % (pipeline, uuid))
    print("  --- diff (current → new) ---")
    format_diff(cur_script, new_script)
    if dry_run:
        print("  dry-run：不寫入、不備份 %s" % name)
        return "dry", run_stamp
    ans = ask("  → %s這站？ y=%s / n=跳過 / q=結束: " % (action, action))
    if ans in ("q", "Q"):
        return "quit", run_stamp
    if ans not in ("y", "Y"):
        print("  跳過 %s。" % name)
        return "skip", run_stamp
    stamp = run_stamp or new_stamp()
    folder = save_site_backup(backups_dir, stamp, e, pipeline, uuid, cur, cur_script)
    host, token = e["host"], e["token"]
    code, resp = post_modify(host, token, uuid, cur, new_script)
    if resp and resp.get("success") is True:
        print("  ✔ 已更新 %s" % name)
        print("  備份: %s" % folder)
        return "ok", stamp
    detail = (resp or {}).get("errorCode") or (resp or {}).get("message") or ("HTTP %s" % code)
    print("  ✘ 更新失敗 %s: %s" % (name, detail))
    print("  寫入前的腳本仍在: %s" % folder)
    return "fail", stamp


def run_rollback(config_path, entries, dry_run=False):
    backups_dir = backups_root(config_path)
    runs = list_backup_runs(backups_dir)
    print_backup_list(runs)
    if not runs:
        sys.exit("沒有備份可還原。")
    picked = parse_backup_pick(ask("要還原哪一份？（上面的編號，或資料夾名稱）: "), runs)
    pipeline = picked["pipeline"]
    if not pipeline:
        sys.exit("這份備份沒有 pipeline 名稱。")
    print("== 這份備份裡的站（pipeline「%s」）==" % pipeline)
    by_n = {e.get("n"): e for e in entries}
    scanned = []
    for site in picked["sites"]:
        n = site.get("n")
        e = by_n.get(n)
        fname = site.get("script_file") or ""
        if e is None:
            kind, note, selectable = "missing_config", "config 沒有這個 n，不可選", False
        elif e.get("region") != site.get("region") or e.get("ws_name") != site.get("ws_name"):
            kind, note, selectable = "mismatch", "config 的 region/ws_name 對不上備份，不可選", False
        elif not is_safe_script_file(fname):
            kind, note, selectable = "bad_file", "備份檔名不合法，不可選", False
        elif not os.path.isfile(os.path.join(picked["path"], fname)):
            kind, note, selectable = "missing_file", "備份腳本檔不在，不可選", False
        else:
            kind, note, selectable = classify_site(e, pipeline)
        scanned.append({
            "n": n, "entry": e, "backup": site, "kind": kind,
            "note": note, "selectable": selectable,
        })
        label = "%s) %s/%s" % (n, site.get("region"), site.get("ws_name"))
        line = "  %s  %s" % (label, note)
        print(paint(line, not selectable and kind in ("no_token", "bad_token")))
    print()
    sites = ask("要還原的站（看上面的編號；逗號分隔或 all；灰色／刪除線的會被忽略）: ")
    if not sites:
        sys.exit("沒有選到任何站。")
    targets, ignored = parse_site_picks(sites, scanned)
    for msg in ignored:
        print("  忽略 %s" % msg)
    if not targets:
        sys.exit("沒有選到任何可用的站。")
    backup_by_n = {row["n"]: row["backup"] for row in scanned}
    run_stamp = None
    for e in targets:
        name = "%s/%s" % (e.get("region"), e.get("ws_name"))
        print("\n================ %s ================" % name)
        site = backup_by_n.get(e.get("n")) or {}
        with open(os.path.join(picked["path"], site["script_file"]), "r", encoding="utf-8") as f:
            restore_script = f.read()
        matches = find_by_name(e["host"], e["token"], pipeline)
        if len(matches) != 1:
            print("  ✘ 這站找到 %d 條叫「%s」的 pipeline（要剛好 1 條才動）。跳過此站。" % (len(matches), pipeline))
            continue
        uuid = matches[0].get("uuid")
        code, js = api(e["host"], e["token"], "GET", "/api/v1/pipeline/%s/get" % uuid)
        cur = (js or {}).get("content") or {}
        cur_script = decode_script(cur)
        status, run_stamp = confirm_and_write(
            e, pipeline, uuid, cur, cur_script, restore_script,
            backups_dir, run_stamp, "還原", dry_run=dry_run)
        if status == "quit":
            print("結束。")
            return
    if dry_run:
        print("\ndry-run 結束。沒有寫入。")
    else:
        print("\n完成。")


def main():
    ap = argparse.ArgumentParser(add_help=True, description="Sync one pipeline's script to selected TrueWatch workspaces.")
    ap.add_argument("--config", default="config.json",
                    help="path to config JSON (array of site entries); default: config.json")
    ap.add_argument("--pipeline", help="pipeline name to update")
    ap.add_argument("--file", dest="script_file", help="path to the new pipeline script (raw PPL text)")
    ap.add_argument("--rollback", action="store_true",
                    help="list timestamped backups next to the config and restore one")
    ap.add_argument("--dry-run", "--dryrun", dest="dry_run", action="store_true",
                    help="show diffs only; do not backup or POST")
    args, unknown = ap.parse_known_args()
    if any(a == "--sites" or a.startswith("--sites=") for a in unknown):
        sys.exit("沒有 --sites。看完清單再填編號。")
    if unknown:
        sys.exit("unknown arg: %s" % unknown[0])
    if args.rollback and args.script_file:
        sys.exit("rollback 不用 --file。")

    config_path = args.config
    entries = load_config(config_path)
    if args.dry_run:
        print("== dry-run：只預覽，不會寫入、不會備份 ==")
        print()
    if args.rollback:
        run_rollback(config_path, entries, dry_run=args.dry_run)
        return

    pipeline = args.pipeline or ask("pipeline 名稱: ")
    if not pipeline:
        sys.exit("沒有 pipeline 名稱。")
    script_file = args.script_file or ask("pipeline 腳本檔路徑: ")
    try:
        with open(script_file, "r", encoding="utf-8") as f:
            new_script = f.read()
    except FileNotFoundError:
        sys.exit("script file not found: %s" % script_file)

    # ---- pass 1: crawl every listed site (token + name) before anyone picks --
    print("== 檢查每一站（token 與 pipeline「%s」）==" % pipeline)
    scanned = []
    for e in entries:
        kind, note, selectable = classify_site(e, pipeline)
        scanned.append({
            "n": e.get("n"), "entry": e, "kind": kind,
            "note": note, "selectable": selectable,
        })
        label = "%s) %s/%s" % (e.get("n"), e.get("region"), e.get("ws_name"))
        line = "  %s  %s" % (label, note)
        print(paint(line, not selectable and kind in ("no_token", "bad_token")))
    print()
    if any(row["kind"] in ("missing", "ambiguous") for row in scanned):
        print("請確認 pipeline 名稱是否填對；沒有這條／同名不唯一的站這次選不到。")
        print()

    sites = ask("要推的站（看上面的編號；逗號分隔或 all；灰色／刪除線的會被忽略）: ")
    if not sites:
        sys.exit("沒有選到任何站。")
    targets, ignored = parse_site_picks(sites, scanned)
    for msg in ignored:
        print("  忽略 %s" % msg)
    if not targets:
        sys.exit("沒有選到任何可用的站。")

    # ---- pass 2: per site -> resolve uuid, diff, confirm, backup, modify ----
    backups_dir = backups_root(config_path)
    run_stamp = None
    for e in targets:
        name = "%s/%s" % (e.get("region"), e.get("ws_name"))
        print("\n================ %s ================" % name)

        matches = find_by_name(e["host"], e["token"], pipeline)
        if len(matches) != 1:
            print("  ✘ 這站找到 %d 條叫「%s」的 pipeline（要剛好 1 條才動）。跳過此站。" % (len(matches), pipeline))
            continue
        uuid = matches[0].get("uuid")

        code, js = api(e["host"], e["token"], "GET", "/api/v1/pipeline/%s/get" % uuid)
        cur = (js or {}).get("content") or {}
        cur_script = decode_script(cur)
        status, run_stamp = confirm_and_write(
            e, pipeline, uuid, cur, cur_script, new_script,
            backups_dir, run_stamp, "上", dry_run=args.dry_run)
        if status == "quit":
            print("結束。")
            return

    if args.dry_run:
        print("\ndry-run 結束。沒有寫入。")
    else:
        print("\n完成。")


if __name__ == "__main__":
    main()
