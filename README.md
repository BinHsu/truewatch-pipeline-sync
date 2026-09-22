# truewatch-pipeline-sync

Push **one** pipeline's script to a set of TrueWatch workspaces you pick, one at a time,
with a token + name check on the site list, then a diff + `y` confirm before every write.

Two interchangeable versions — a Python 3 script (standard library only) and a Bash script
(`curl` + `jq`) — with identical behaviour. No vendor CLI, no owl-cli: each workspace is
reached directly through its own DF-API-KEY against `<region>-openapi.truewatch.com`. Use
whichever your machine already satisfies; the Python one needs nothing to install on a stock
macOS.

## What it does, and what it will never do

- It only ever touches the **one** pipeline you name, on the **sites you select**. Every
  other pipeline, and every site you did not pick, is left untouched.
- **Pass 1 crawls every site in the list** (token, then whether the named pipeline exists)
  **before you pick numbers.** A dead token is greyed out with a strikethrough and cannot
  be selected. A missing or non-unique name is marked on that row and cannot be selected
  either — fix the pipeline name and run again. Typing an unusable `n` is ignored, not a
  reason to abort the rest.
- There is **no `--sites` flag.** Numbers only make sense after you have seen that list.
- **Pass 2, per site:** resolve the pipeline name to its uuid (searches `local` then
  `central`); if the name matches 0 or more than 1 pipeline on that site, it **skips that
  site** rather than guess. Then it prints a diff of current vs new and waits for you:
  `y` = apply, `n`/Enter = skip this site, `q` = quit. A `y` first writes that site's
  current script into `<config-dir>/backups/<YYYY-MM-DDTHH-MM-SS>/` (same run shares one
  timestamp folder), then POSTs the change.
- The write changes **only the script**. It carries the current `name`, `type`, `category`,
  `source`, `asDefault` through unchanged, and **preserves the existing `testData`**.
- The diff is **per site**: each selected site is compared against the same new file, so if
  sites have drifted you see each one's own difference before deciding.

## Setup

1. Copy the config and fill in your tokens:

   ```bash
   cp config.example.json config.json
   ```

   Each entry is one workspace:

   ```json
   { "n": 0, "region": "id1", "ws_name": "dev-test", "host": "id1-openapi.truewatch.com", "token": "<DF-API-KEY>" }
   ```

   - `n` is the number you type after the annotated list. Order matters: dev/test at `n=0`,
     then least-impact → most-impact.
   - `token` is **your** per-workspace DF-API-KEY. Get it in the console:
     1. **Switch into the target workspace first** — the key binds to whichever workspace is
        active when you create it.
     2. Account menu (top-right) → **Personal API Key** → create/open one and copy the
        **Key (Secret)** (not the Key ID). Management → API Key Management gives the same thing.
     3. Do **not** use Management → Client Tokens — those are RUM-only and will be rejected.

     One key is tied to one (region, workspace) pair, so repeat this per entry.

2. Install the prerequisites for whichever version you run. Neither version needs owl-cli or
   any vendor CLI — both talk straight to the Open API.

   | Version | Needs | How to get it |
   |---|---|---|
   | **Python** (`pipeline_sync.py`) | `python3` only (standard library) | macOS/most Linux ship it. Check `python3 --version`; else `brew install python` / `apt install python3`. |
   | **Bash** (`pipeline-sync.sh`) | `curl` + `jq` | `curl` ships on macOS/Linux. `jq`: `brew install jq` / `apt install jq`. |

   The two versions are behaviourally identical — same config, same annotated list,
   same pick-after-list, same diff and per-site confirm. Pick whichever your machine
   already satisfies; the Python one needs nothing to install on a stock macOS.

## Usage

Both take the same flags. `--config` defaults to `./config.json`; `--pipeline` and `--file`
are prompted for if omitted. After the annotated list you type the `n` numbers (or `all`).

**Python:**

```bash
python3 pipeline_sync.py --pipeline "wg_universal_v5_compress" --file ./new-script.ppl
```

**Bash:**

```bash
./pipeline-sync.sh --pipeline "wg_universal_v5_compress" --file ./new-script.ppl
```

Either way you see every site with token / name status, then pick numbers, then per
selected site a diff and a confirm prompt.

`--dry-run` (also `--dryrun`) walks the same path — list, pick, per-site diff — but does
not backup and does not POST. It works on a forward sync and on `--rollback`. Without it,
nothing is written until you type `y` at a site; `--dry-run` is so you can see every diff
without that prompt. There is still no `--yes`.

**Dry-run:**

```bash
python3 pipeline_sync.py --dry-run --pipeline "wg_universal_v5_compress" --file ./new-script.ppl
./pipeline-sync.sh --dry-run --rollback
```

## Backup and rollback

Every confirmed write saves the site's **current** script next to the config, in a
timestamp-named folder:

```text
<config-dir>/backups/2026-09-21T20-54-01/manifest.json
<config-dir>/backups/2026-09-21T20-54-01/0-id1-dev-test.ppl
```

The folder name is local time `YYYY-MM-DDTHH-MM-SS`. Sites confirmed in the same run share
one folder. Tokens are never written there. `backups/` is git-ignored.

To restore, list those folders and type an id (the `0)` / `1)` number, or the folder name):

```bash
python3 pipeline_sync.py --rollback
./pipeline-sync.sh --rollback
```

You then pick which sites from that backup to restore. Each site still shows a diff
(current → backup) and waits for `y` / `n` / `q`. Rollback is another write, so it takes a
fresh backup first — there is no `--yes`.

## Files

| File | What it is |
|---|---|
| `pipeline_sync.py` | the tool (Python 3, stdlib only) |
| `pipeline-sync.sh` | the tool (Bash + curl + jq) — same behaviour |
| `config.example.json` | generic template (committed) |
| `config.json` | your working config with tokens (not committed) |
| `backups/` | pre-write snapshots (`<timestamp>/`); created at runtime, not committed |

`config.json` and `config.json.*` are git-ignored — a config with a token in it must never
be committed.
