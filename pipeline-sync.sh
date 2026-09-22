#!/usr/bin/env bash
# pipeline-sync.sh — push ONE pipeline's script to selected TrueWatch workspaces,
# with per-site token validation, a diff, and a y/enter confirm before each write.
#
# Self-contained: needs only `curl` and `jq`. No vendor CLI required — each site is
# reached via its own workspace DF-API-KEY against <region>-openapi.truewatch.com.
#
# It ONLY ever touches the ONE pipeline you name, on the sites you pick. Every other
# pipeline and every unselected site is left untouched.
#
# Usage:
#   ./pipeline-sync.sh --config <config.json> --pipeline <name> --file <new-script.ppl>
#   ./pipeline-sync.sh --config <config.json> --rollback
#   ./pipeline-sync.sh --dry-run ...   # same flow, no backup, no POST
#   --config defaults to ./config.json; --pipeline/--file are prompted if omitted.
#   Sites are chosen after the annotated list — there is no --sites flag.
#   Before every confirmed write, the current script is saved under
#   <config-dir>/backups/<YYYY-MM-DDTHH-MM-SS>/. --rollback lists those folders
#   and restores one after the same per-site diff + y/n/q confirm.
#   --dry-run walks that path and prints diffs, but never writes.
#
# Config: a JSON array, one entry per workspace. See config.example.json.
#   [{ "n":0,"region":"id1","ws_name":"dev-test","host":"id1-openapi.truewatch.com","token":"<DF-API-KEY>" }, ...]
#   - order matters: put dev/test at n=0, then least-impact -> most-impact.
#   - token is YOUR per-workspace DF-API-KEY (Personal API Key -> Key(Secret)); one token = one workspace.

set -euo pipefail

CONFIG="" ; PIPELINE="" ; SCRIPT_FILE="" ; ROLLBACK=0 ; DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --config)   CONFIG="$2"; shift 2;;
    --pipeline) PIPELINE="$2"; shift 2;;
    --file)     SCRIPT_FILE="$2"; shift 2;;
    --rollback) ROLLBACK=1; shift;;
    --dry-run|--dryrun) DRY_RUN=1; shift;;
    --sites)    echo "沒有 --sites。看完清單再填編號。" >&2; exit 2;;
    -h|--help)  sed -n '2,32p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

command -v jq   >/dev/null || { echo "need jq";   exit 1; }
command -v curl >/dev/null || { echo "need curl"; exit 1; }

dedupe_ns() { # stdin: one id per line. First occurrence only.
  local seen=" " n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    case "$seen" in
      *" $n "*) continue ;;
    esac
    seen="${seen}${n} "
    printf '%s\n' "$n"
  done
}

ask() {
  local p="$1" v=""
  if [ -r /dev/tty ] && [ -t 1 ]; then
    read -r -p "$p" v </dev/tty || true
  else
    read -r -p "$p" v || true
  fi
  printf '%s' "$v"
}

# $(...) drops trailing newlines. A script that ends with a newline would otherwise
# be backed up, pushed, and rolled back without that byte, which is indistinguishable
# from a no-op when the only difference is the final newline.
read_exact_into() { # read_exact_into <varname> <file>
  local dest="$1" raw
  raw="$(cat "$2"; printf x)"
  printf -v "$dest" '%s' "${raw%x}"
}

decode_b64_into() { # decode_b64_into <varname> <base64-text>
  local dest="$1" b64="$2" raw
  raw="$( { printf '%s' "$b64" | tr -d '\n' | base64 -d 2>/dev/null || true; printf x; } )"
  printf -v "$dest" '%s' "${raw%x}"
}

if [ -t 1 ]; then GRAY=$'\033[90m'; STRIKE=$'\033[9m'; RESET=$'\033[0m'
else GRAY=""; STRIKE=""; RESET=""; fi
paint() { # paint <disabled:0|1> <text>
  if [ "$1" = "1" ] && [ -n "$GRAY" ]; then printf '%s%s%s%s\n' "$GRAY" "$STRIKE" "$2" "$RESET"
  else printf '%s\n' "$2"; fi
}

[ -n "$CONFIG" ]      || CONFIG="config.json"
[ -f "$CONFIG" ]      || { echo "config not found: $CONFIG" >&2; exit 1; }
jq -e . "$CONFIG" >/dev/null 2>&1 || { echo "config is not valid JSON" >&2; exit 1; }
if [ "$ROLLBACK" = "1" ] && [ -n "$SCRIPT_FILE" ]; then
  echo "rollback 不用 --file。" >&2; exit 1
fi
if [ "$DRY_RUN" = "1" ]; then
  echo "== dry-run：只預覽，不會寫入、不會備份 =="
  echo
fi

api() { # api <host> <token> <method> <path> [json-body]
  local host="$1" tok="$2" method="$3" path="$4" body="${5:-}"
  if [ -n "$body" ]; then
    curl -sS -X "$method" "https://${host}${path}" \
      -H "DF-API-KEY: ${tok}" -H "Content-Type: application/json" --data "$body"
  else
    curl -sS -X "$method" "https://${host}${path}" -H "DF-API-KEY: ${tok}"
  fi
}

pipeline_match_count() {
  local host="$1" tok="$2" name="$3" match cnt
  match="$(api "$host" "$tok" GET "/api/v1/pipeline/list?type=local&search=$(jq -rn --arg s "$name" '$s|@uri')" \
           | jq -c --arg nm "$name" '[.content.data[]? | select(.name==$nm)]' 2>/dev/null || echo '[]')"
  cnt="$(jq 'length' <<<"$match")"
  if [ "$cnt" = "0" ]; then
    match="$(api "$host" "$tok" GET "/api/v1/pipeline/list?type=central&search=$(jq -rn --arg s "$name" '$s|@uri')" \
             | jq -c --arg nm "$name" '[.content.data[]? | select(.name==$nm)]' 2>/dev/null || echo '[]')"
    cnt="$(jq 'length' <<<"$match")"
  fi
  printf '%s' "$cnt"
}

backups_root() {
  local cfg="$1" dir
  dir="$(cd "$(dirname "$cfg")" && pwd)"
  printf '%s/backups' "$dir"
}

is_safe_stamp() {
  local name="$1"
  case "$name" in
    */*|*"\\"*) return 1;;
    .|..) return 1;;
  esac
  [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]
}

is_safe_script_file() {
  local name="$1"
  [ -n "$name" ] || return 1
  case "$name" in
    */*|.*|..) return 1;;
  esac
  case "$name" in
    *..*) return 1;;
    *.ppl) return 0;;
    *) return 1;;
  esac
}

slug() {
  local s
  s="$(printf '%s' "$1" | sed -E 's/[^A-Za-z0-9._-]+/_/g' | cut -c1-80)"
  [ -n "$s" ] || s="x"
  printf '%s' "$s"
}

site_script_name() {
  local entry="$1" n region ws
  n="$(jq -r '.n // "x"' <<<"$entry")"
  region="$(slug "$(jq -r '.region // ""' <<<"$entry")")"
  ws="$(slug "$(jq -r '.ws_name // ""' <<<"$entry")")"
  printf '%s-%s-%s.ppl' "$n" "$region" "$ws"
}

save_site_backup() {
  # save_site_backup <root> <stamp> <entry_json> <pipeline> <uuid> <cur_json> <cur_script>
  local root="$1" stamp="$2" entry="$3" pipeline="$4" uuid="$5" cur="$6" cur_script="$7"
  is_safe_stamp "$stamp" || { echo "unsafe backup stamp" >&2; exit 1; }
  local folder="${root}/${stamp}"
  mkdir -p "$folder"
  local fname rec n_json old_td man_path
  fname="$(site_script_name "$entry")"
  is_safe_script_file "$fname" || { echo "unsafe backup filename" >&2; exit 1; }
  printf '%s' "$cur_script" > "${folder}/${fname}"
  old_td="$(jq -r '.testData // ""' <<<"$cur" | tr -d '\n')"
  [ -n "$old_td" ] || old_td="W10="
  n_json="$(jq -c '.n' <<<"$entry")"
  rec="$(jq -n \
    --argjson n "$n_json" \
    --arg region "$(jq -r '.region' <<<"$entry")" \
    --arg ws_name "$(jq -r '.ws_name' <<<"$entry")" \
    --arg host "$(jq -r '.host' <<<"$entry")" \
    --arg uuid "$uuid" \
    --arg script_file "$fname" \
    --arg name "$(jq -r '.name' <<<"$cur")" \
    --arg type "$(jq -r '.type // "local"' <<<"$cur")" \
    --arg category "$(jq -r '.category // "logging"' <<<"$cur")" \
    --argjson source "$(jq -c '.source // []' <<<"$cur")" \
    --argjson asDefault "$(jq -r '.asDefault // 0' <<<"$cur")" \
    --arg testData "$old_td" \
    '{n:$n,region:$region,ws_name:$ws_name,host:$host,uuid:$uuid,script_file:$script_file,name:$name,type:$type,category:$category,source:$source,asDefault:$asDefault,testData:$testData}')"
  man_path="${folder}/manifest.json"
  if [ -f "$man_path" ]; then
    jq --arg pipeline "$pipeline" --arg stamp "$stamp" --argjson rec "$rec" --argjson n "$n_json" \
      '{stamp:$stamp,pipeline:$pipeline,sites:((.sites // []) | map(select(.n != $n)) + [$rec])}' \
      "$man_path" > "${man_path}.tmp" && mv "${man_path}.tmp" "$man_path"
  else
    jq -n --arg pipeline "$pipeline" --arg stamp "$stamp" --argjson rec "$rec" \
      '{stamp:$stamp,pipeline:$pipeline,sites:[$rec]}' > "$man_path"
  fi
  printf '%s' "$folder"
}

BACKUP_STAMPS=()
BACKUP_PIPELINES=()
BACKUP_SITE_SUMMARIES=()
BACKUP_PATHS=()

list_backup_runs() {
  local root="$1" path name man summary stamps=""
  BACKUP_STAMPS=()
  BACKUP_PIPELINES=()
  BACKUP_SITE_SUMMARIES=()
  BACKUP_PATHS=()
  [ -d "$root" ] || return 0
  for path in "$root"/*/; do
    [ -e "$path" ] || continue
    name="$(basename "${path%/}")"
    is_safe_stamp "$name" || continue
    [ -L "${path%/}" ] && continue
    [ -d "${path%/}" ] || continue
    [ -f "${path}manifest.json" ] || continue
    stamps="${stamps}${name}"$'\n'
  done
  [ -n "$stamps" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    path="${root}/${name}"
    man="$(cat "${path}/manifest.json" 2>/dev/null || echo '{}')"
    jq -e . <<<"$man" >/dev/null 2>&1 || continue
    summary="$(jq -r '[.sites[]? | "\(.n))\(.region)/\(.ws_name)"] | if length==0 then "（沒有站）" else join(", ") end' <<<"$man")"
    BACKUP_STAMPS+=("$name")
    BACKUP_PIPELINES+=("$(jq -r '.pipeline // ""' <<<"$man")")
    BACKUP_SITE_SUMMARIES+=("$summary")
    BACKUP_PATHS+=("$path")
  done < <(printf '%s' "$stamps" | sed '/^$/d' | sort -r)
}

print_backup_list() {
  local i
  echo "== 既有備份 =="
  [ "${#BACKUP_STAMPS[@]}" -gt 0 ] || return 0
  for i in "${!BACKUP_STAMPS[@]}"; do
    echo "  ${i}) ${BACKUP_STAMPS[$i]}  pipeline=${BACKUP_PIPELINES[$i]:-?}  站: ${BACKUP_SITE_SUMMARIES[$i]}"
  done
  echo
}

parse_backup_pick() {
  local raw="$1" i
  raw="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$raw" ] || { echo "沒有選到備份。" >&2; exit 1; }
  case "$raw" in
    */*|*\\*|.) echo "備份編號不合法。" >&2; exit 1;;
    ..) echo "備份編號不合法。" >&2; exit 1;;
  esac
  if [[ "$raw" =~ ^-?[0-9]+$ ]]; then
    if [ "$raw" -lt 0 ] || [ "$raw" -ge "${#BACKUP_STAMPS[@]}" ]; then
      echo "沒有這個備份編號: ${raw}" >&2; exit 1
    fi
    PICKED="$raw"
    return 0
  fi
  is_safe_stamp "$raw" || { echo "備份編號不合法。" >&2; exit 1; }
  for i in "${!BACKUP_STAMPS[@]}"; do
    if [ "${BACKUP_STAMPS[$i]}" = "$raw" ]; then
      PICKED="$i"
      return 0
    fi
  done
  echo "沒有這個備份: ${raw}" >&2; exit 1
}

post_modify() {
  local host="$1" tok="$2" uuid="$3" cur="$4" new_script="$5" new_content_b64 old_td body
  new_content_b64="$(printf '%s' "$new_script" | base64 | tr -d '\n')"
  old_td="$(jq -r '.testData // ""' <<<"$cur" | tr -d '\n')"
  [ -n "$old_td" ] || old_td="W10="
  body="$(jq -n \
    --arg name "$(jq -r '.name' <<<"$cur")" \
    --arg type "$(jq -r '.type // "local"' <<<"$cur")" \
    --arg category "$(jq -r '.category // "logging"' <<<"$cur")" \
    --argjson source "$(jq -c '.source // []' <<<"$cur")" \
    --argjson asDefault "$(jq -r '.asDefault // 0' <<<"$cur")" \
    --arg content "$new_content_b64" \
    --arg testData "$old_td" \
    '{name:$name,type:$type,category:$category,source:$source,asDefault:$asDefault,content:$content,testData:$testData}')"
  api "$host" "$tok" POST "/api/v1/pipeline/${uuid}/modify" "$body"
}

confirm_and_write() {
  # confirm_and_write <entry> <uuid> <cur> <cur_script> <new_script> <action>
  local entry="$1" uuid="$2" cur="$3" cur_script="$4" new_script="$5" action="$6"
  local name host tok folder resp
  name="$(jq -r '.region+"/"+.ws_name' <<<"$entry")"
  echo "  pipeline: ${PIPELINE}  (uuid ${uuid})"
  echo "  --- diff (current → new) ---"
  if diff <(printf '%s' "$cur_script") <(printf '%s' "$new_script") >/dev/null; then
    echo "  （無差異，內容相同）"
  else
    diff -u <(printf '%s' "$cur_script") <(printf '%s' "$new_script") | sed 's/^/  /' || true
  fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "  dry-run：不寫入、不備份 ${name}"
    return 0
  fi
  local ans
  ans="$(ask "  → ${action}這站？ y=${action} / n=跳過 / q=結束: ")"
  case "$ans" in
    q|Q) echo "結束。"; exit 0;;
    y|Y) : ;;
    *)   echo "  跳過 ${name}。"; return 0;;
  esac
  [ -n "${RUN_STAMP}" ] || RUN_STAMP="$(date +%Y-%m-%dT%H-%M-%S)"
  folder="$(save_site_backup "$BACKUPS_DIR" "$RUN_STAMP" "$entry" "$PIPELINE" "$uuid" "$cur" "$cur_script")"
  host="$(jq -r '.host' <<<"$entry")"
  tok="$(jq -r '.token' <<<"$entry")"
  resp="$(post_modify "$host" "$tok" "$uuid" "$cur" "$new_script")"
  if jq -e '.success==true' <<<"$resp" >/dev/null 2>&1; then
    echo "  ✔ 已更新 ${name}"
    echo "  備份: ${folder}"
  else
    echo "  ✘ 更新失敗 ${name}: $(jq -rc '.errorCode // .message // .' <<<"$resp" 2>/dev/null || echo "$resp")"
    echo "  寫入前的腳本仍在: ${folder}"
  fi
}

find_match() {
  local host="$1" tok="$2" name="$3" match cnt
  match="$(api "$host" "$tok" GET "/api/v1/pipeline/list?type=local&search=$(jq -rn --arg s "$name" '$s|@uri')" \
           | jq -c --arg nm "$name" '[.content.data[]? | select(.name==$nm)]' 2>/dev/null || echo '[]')"
  cnt="$(jq 'length' <<<"$match")"
  if [ "$cnt" = "0" ]; then
    match="$(api "$host" "$tok" GET "/api/v1/pipeline/list?type=central&search=$(jq -rn --arg s "$name" '$s|@uri')" \
             | jq -c --arg nm "$name" '[.content.data[]? | select(.name==$nm)]' 2>/dev/null || echo '[]')"
    cnt="$(jq 'length' <<<"$match")"
  fi
  MATCH_JSON="$match"
  MATCH_CNT="$cnt"
}

BACKUPS_DIR="$(backups_root "$CONFIG")"
RUN_STAMP=""

run_rollback() {
  local pick_raw i n host tok label kind note ok disable need_name_hint=0
  list_backup_runs "$BACKUPS_DIR"
  print_backup_list
  [ "${#BACKUP_STAMPS[@]}" -gt 0 ] || { echo "沒有備份可還原。" >&2; exit 1; }
  pick_raw="$(ask '要還原哪一份？（上面的編號，或資料夾名稱）: ')"
  parse_backup_pick "$pick_raw"
  local picked_path="${BACKUP_PATHS[$PICKED]}"
  PIPELINE="${BACKUP_PIPELINES[$PICKED]}"
  [ -n "$PIPELINE" ] || { echo "這份備份沒有 pipeline 名稱。" >&2; exit 1; }
  echo "== 這份備份裡的站（pipeline「${PIPELINE}」）=="
  local man sites_json
  man="$(cat "${picked_path}/manifest.json")"
  sites_json="$(jq -c '.sites // []' <<<"$man")"
  declare -a SCAN_N=() SCAN_KIND=() SCAN_NOTE=() SCAN_OK=() SCAN_ENTRY=() SCAN_BACKUP=()
  while IFS= read -r site; do
    [ -n "$site" ] || continue
    n="$(jq -r '.n' <<<"$site")"
    local region ws fname entry
    region="$(jq -r '.region' <<<"$site")"
    ws="$(jq -r '.ws_name' <<<"$site")"
    fname="$(jq -r '.script_file // ""' <<<"$site")"
    label="${n}) ${region}/${ws}"
    kind=""; note=""; ok=0; disable=0
    entry="$(jq -c --argjson n "$n" '.[] | select(.n==$n)' "$CONFIG" | head -n1)"
    if [ -z "$entry" ] || [ "$entry" = "null" ]; then
      kind="missing_config"; note="config 沒有這個 n，不可選"
    elif [ "$(jq -r '.region' <<<"$entry")" != "$region" ] || [ "$(jq -r '.ws_name' <<<"$entry")" != "$ws" ]; then
      kind="mismatch"; note="config 的 region/ws_name 對不上備份，不可選"
    elif ! is_safe_script_file "$fname"; then
      kind="bad_file"; note="備份檔名不合法，不可選"
    elif [ ! -f "${picked_path}/${fname}" ]; then
      kind="missing_file"; note="備份腳本檔不在，不可選"
    else
      host="$(jq -r '.host' <<<"$entry")"
      tok="$(jq -r '.token' <<<"$entry")"
      if [ -z "$tok" ] || [ "$tok" = "null" ]; then
        kind="no_token"; note="token 未填，不可選"; disable=1
      else
        local code
        code="$(curl -sS -o /dev/null -w '%{http_code}' \
                "https://${host}/api/v1/checker/list?pageIndex=1&pageSize=1" -H "DF-API-KEY: ${tok}" || echo 000)"
        if [ "$code" != "200" ]; then
          kind="bad_token"; note="token 無效或站點不通 (HTTP $code)，不可選"; disable=1
        else
          local cnt
          cnt="$(pipeline_match_count "$host" "$tok" "$PIPELINE")"
          if [ "$cnt" = "1" ]; then
            kind="ok"; note="✔ 有這條"; ok=1
          elif [ "$cnt" = "0" ]; then
            kind="missing"; note="✘ 沒有這條，不可選"; need_name_hint=1
          else
            kind="ambiguous"; note="✘ 同名 ${cnt} 條，不可選"; need_name_hint=1
          fi
        fi
      fi
    fi
    SCAN_N+=("$n"); SCAN_KIND+=("$kind"); SCAN_NOTE+=("$note"); SCAN_OK+=("$ok"); SCAN_ENTRY+=("${entry:-}")
    SCAN_BACKUP+=("$site")
    paint "$disable" "  ${label}  ${note}"
  done < <(jq -c '.[]?' <<<"$sites_json")
  echo
  if [ "$need_name_hint" = "1" ]; then
    echo "請確認 pipeline 名稱是否填對；沒有這條／同名不唯一的站這次選不到。"
    echo
  fi
  local SITES
  SITES="$(ask '要還原的站（看上面的編號；逗號分隔或 all；灰色／刪除線的會被忽略）: ')"
  [ -n "$SITES" ] || { echo "沒有選到任何站。" >&2; exit 1; }
  local SEL_NS
  if [ "$SITES" = "all" ]; then
    SEL_NS="$(printf '%s\n' "${SCAN_N[@]}" | dedupe_ns)"
  else
    SEL_NS="$(printf '%s' "$SITES" | tr ', ' '\n\n' | sed '/^$/d' | dedupe_ns)"
  fi
  declare -a TARGETS=() TARGET_BACKUPS=()
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "站編號不是數字: ${n}" >&2; exit 1; }
    local found=0
    for i in "${!SCAN_N[@]}"; do
      [ "${SCAN_N[$i]}" = "$n" ] || continue
      found=1
      if [ "${SCAN_OK[$i]}" = "1" ]; then
        TARGETS+=("${SCAN_ENTRY[$i]}")
        TARGET_BACKUPS+=("${SCAN_BACKUP[$i]}")
      else
        echo "  忽略 ${n}（${SCAN_NOTE[$i]}）"
      fi
      break
    done
    [ "$found" = "1" ] || echo "  忽略 ${n}（config 沒有）"
  done <<<"$SEL_NS"
  [ "${#TARGETS[@]}" -gt 0 ] || { echo "沒有選到任何可用的站。"; exit 1; }
  local idx
  for idx in "${!TARGETS[@]}"; do
    local entry="${TARGETS[$idx]}" site="${TARGET_BACKUPS[$idx]}"
    local name uuid cur cur_script restore_script fname
    name="$(jq -r '.region+"/"+.ws_name' <<<"$entry")"
    echo ; echo "================ ${name} ================"
    fname="$(jq -r '.script_file' <<<"$site")"
    read_exact_into restore_script "${picked_path}/${fname}"
    host="$(jq -r '.host'  <<<"$entry")"
    tok="$(jq -r '.token'  <<<"$entry")"
    find_match "$host" "$tok" "$PIPELINE"
    if [ "$MATCH_CNT" != "1" ]; then
      echo "  ✘ 這站找到 ${MATCH_CNT} 條叫「${PIPELINE}」的 pipeline（要剛好 1 條才動）。跳過此站。"
      continue
    fi
    uuid="$(jq -r '.[0].uuid' <<<"$MATCH_JSON")"
    cur="$(api "$host" "$tok" GET "/api/v1/pipeline/${uuid}/get" | jq -c '.content')"
    decode_b64_into cur_script "$(jq -r '.content // ""' <<<"$cur")"
    confirm_and_write "$entry" "$uuid" "$cur" "$cur_script" "$restore_script" "還原"
  done
  if [ "$DRY_RUN" = "1" ]; then
    echo ; echo "dry-run 結束。沒有寫入。"
  else
    echo ; echo "完成。"
  fi
}

if [ "$ROLLBACK" = "1" ]; then
  run_rollback
  exit 0
fi

[ -n "$PIPELINE" ]    || PIPELINE="$(ask 'pipeline 名稱: ')"
[ -n "$PIPELINE" ]    || { echo "沒有 pipeline 名稱。" >&2; exit 1; }
[ -n "$SCRIPT_FILE" ] || SCRIPT_FILE="$(ask 'pipeline 腳本檔路徑: ')"
[ -f "$SCRIPT_FILE" ] || { echo "script file not found: $SCRIPT_FILE" >&2; exit 1; }

read_exact_into NEW_SCRIPT "$SCRIPT_FILE"

# ---- pass 1: crawl every listed site (token + name) before anyone picks -----
echo "== 檢查每一站（token 與 pipeline「${PIPELINE}」）=="
declare -a SCAN_N=() SCAN_KIND=() SCAN_NOTE=() SCAN_OK=() SCAN_ENTRY=()
need_name_hint=0
while IFS= read -r entry; do
  n="$(jq -r '.n' <<<"$entry")"
  host="$(jq -r '.host' <<<"$entry")"
  tok="$(jq -r '.token' <<<"$entry")"
  label="$(jq -r '"\(.n)) \(.region)/\(.ws_name)"' <<<"$entry")"
  kind=""; note=""; ok=0; disable=0
  if [ -z "$tok" ] || [ "$tok" = "null" ]; then
    kind="no_token"; note="token 未填，不可選"; disable=1
  else
    code="$(curl -sS -o /dev/null -w '%{http_code}' \
            "https://${host}/api/v1/checker/list?pageIndex=1&pageSize=1" -H "DF-API-KEY: ${tok}" || echo 000)"
    if [ "$code" != "200" ]; then
      kind="bad_token"; note="token 無效或站點不通 (HTTP $code)，不可選"; disable=1
    else
      cnt="$(pipeline_match_count "$host" "$tok" "$PIPELINE")"
      if [ "$cnt" = "1" ]; then
        kind="ok"; note="✔ 有這條"; ok=1
      elif [ "$cnt" = "0" ]; then
        kind="missing"; note="✘ 沒有這條，不可選"; need_name_hint=1
      else
        kind="ambiguous"; note="✘ 同名 ${cnt} 條，不可選"; need_name_hint=1
      fi
    fi
  fi
  SCAN_N+=("$n"); SCAN_KIND+=("$kind"); SCAN_NOTE+=("$note"); SCAN_OK+=("$ok"); SCAN_ENTRY+=("$entry")
  paint "$disable" "  ${label}  ${note}"
done < <(jq -c '.[]' "$CONFIG")
echo
if [ "$need_name_hint" = "1" ]; then
  echo "請確認 pipeline 名稱是否填對；沒有這條／同名不唯一的站這次選不到。"
  echo
fi

SITES="$(ask '要推的站（看上面的編號；逗號分隔或 all；灰色／刪除線的會被忽略）: ')"
[ -n "$SITES" ] || { echo "沒有選到任何站。" >&2; exit 1; }

if [ "$SITES" = "all" ]; then
  SEL_NS="$(printf '%s\n' "${SCAN_N[@]}" | dedupe_ns)"
else
  SEL_NS="$(printf '%s' "$SITES" | tr ', ' '\n\n' | sed '/^$/d' | dedupe_ns)"
fi

declare -a TARGETS=()
for n in $SEL_NS; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "站編號不是數字: $n" >&2; exit 1; }
  found=0
  for i in "${!SCAN_N[@]}"; do
    [ "${SCAN_N[$i]}" = "$n" ] || continue
    found=1
    if [ "${SCAN_OK[$i]}" = "1" ]; then TARGETS+=("${SCAN_ENTRY[$i]}")
    else echo "  忽略 ${n}（${SCAN_NOTE[$i]}）"; fi
    break
  done
  [ "$found" = "1" ] || echo "  忽略 ${n}（config 沒有）"
done
[ "${#TARGETS[@]}" -gt 0 ] || { echo "沒有選到任何可用的站。"; exit 1; }

# ---- pass 2: per site -> resolve uuid, diff, confirm, backup, modify -------
for entry in "${TARGETS[@]}"; do
  host="$(jq -r '.host'  <<<"$entry")"
  tok="$(jq -r '.token'  <<<"$entry")"
  name="$(jq -r '.region+"/"+.ws_name' <<<"$entry")"
  echo ; echo "================ $name ================"

  find_match "$host" "$tok" "$PIPELINE"
  if [ "$MATCH_CNT" != "1" ]; then
    echo "  ✘ 這站找到 $MATCH_CNT 條叫「${PIPELINE}」的 pipeline（要剛好 1 條才動）。跳過此站。"
    continue
  fi
  uuid="$(jq -r '.[0].uuid' <<<"$MATCH_JSON")"

  cur="$(api "$host" "$tok" GET "/api/v1/pipeline/${uuid}/get" | jq -c '.content')"
  decode_b64_into cur_script "$(jq -r '.content // ""' <<<"$cur")"

  confirm_and_write "$entry" "$uuid" "$cur" "$cur_script" "$NEW_SCRIPT" "上"
done
if [ "$DRY_RUN" = "1" ]; then
  echo ; echo "dry-run 結束。沒有寫入。"
else
  echo ; echo "完成。"
fi
