#!/usr/bin/env bash
# Bvaigen.sh — local AI chat inventory + Telegram cache + AIC1 sync.
# Bash 3.2 compatible. Requires: find, awk, sed, jq, sqlite3, curl, shasum.
# Encryption is delegated to python3 + cryptography to keep AIC1 compatibility.

set -uo pipefail

MB=$((1024 * 1024))
BASE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
API="${BVAIGEN_API:-https://api.github.com}"
DEFAULT_REPO="${GITHUB_REPO:-Aghanim-sec/Sync}"
PROG=$(basename "$0")

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bvaigen.XXXXXX") || exit 1
if [ "${BV_KEEP:-0}" = "1" ]; then
  trap 'echo "TMP=$TMP" >&2' EXIT INT TERM
else
  trap 'rm -rf "$TMP"' EXIT INT TERM
fi

CRYPTO_PY="$TMP/crypto.py"
cat >"$CRYPTO_PY" <<'PY'
import os, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

MAGIC = b"AIC1"
mode = sys.argv[1]
pw = os.environ.get("AIC_PW", "")
data = sys.stdin.buffer.read()

def key(salt):
    return Scrypt(salt=salt, length=32, n=2 ** 15, r=8, p=1).derive(pw.encode())

if mode == "enc":
    salt, nonce = os.urandom(16), os.urandom(12)
    out = MAGIC + salt + nonce + AESGCM(key(salt)).encrypt(nonce, data, MAGIC)
elif mode == "dec":
    if not data.startswith(MAGIC):
        sys.stderr.write("not an AIC file\n"); sys.exit(1)
    salt, nonce, ct = data[4:20], data[20:32], data[32:]
    try:
        out = AESGCM(key(salt)).decrypt(nonce, ct, MAGIC)
    except Exception:
        sys.stderr.write("wrong password or corrupted file\n"); sys.exit(1)
else:
    sys.stderr.write("bad mode\n"); sys.exit(1)
sys.stdout.buffer.write(out)
PY

say()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

human() {
  awk -v n="${1:-0}" 'BEGIN{
    split("B KB MB GB", u, " "); i = 1
    while (n >= 1024 && i < 4) { n /= 1024; i++ }
    if (i == 1) printf "%d %s\n", n, u[i]; else printf "%.1f %s\n", n, u[i]
  }'
}

need() {
  for t in jq sqlite3 curl python3; do
    have "$t" || { err "missing: $t"; exit 1; }
  done
}

# ---------------------------------------------------------------- sources

source_list() {
  cat <<EOF
OpenCode|app|$HOME/.local/share/opencode/opencode.db;$HOME/.local/share/opencode/storage;$HOME/.config/opencode
Codex CLI|cli|$HOME/.codex
Claude Desktop|desktop|$HOME/Library/Application Support/Claude/IndexedDB;$HOME/Library/Application Support/Claude/Local Storage
ChatGPT Desktop|desktop|$HOME/Library/Application Support/com.openai.chat;$HOME/Library/Containers/com.openai.chat
Cursor|ide|$HOME/Library/Application Support/Cursor/User/globalStorage
VS Code / Copilot|ide|$HOME/Library/Application Support/Code/User/globalStorage
Windsurf|ide|$HOME/Library/Application Support/Windsurf/User/globalStorage
Zed|ide|$HOME/Library/Application Support/Zed
LM Studio|app|$HOME/.lmstudio
Gemini / Antigravity|cli|$HOME/.gemini/history;$HOME/.gemini/antigravity
Claude Code|cli|$HOME/.claude/projects;$HOME/.claude/history.jsonl
EOF
}

# ---------------------------------------------------------------- jq programs

cat >"$TMP/prog_doc.jq" <<'JQ'
def rec($role):
  if type == "object" then
    . as $o
    | (($o.role? // $o.sender? // $role)
       | if type == "string" then ascii_downcase else "" end) as $r
    | (($o.model? | strings) | "M\t" + .),
      (($o.model? | objects | (.id? // .name?)) | strings | "M\t" + .),
      (($o.title? // $o.name?) | strings | select(length > 2) | "I\t" + .),
      ((($o.session_id? // $o.sessionId? // $o.conversation_id? // $o.conversationId? // $o.chat_id? // $o.chatId?) | strings) | "S\t" + .),
      ((["text", "content", "message", "body", "prompt", "completion"][] as $k
        | $o[$k]? | strings) as $t
       | "T\t" + $r + "\t" + ($t | gsub("[\\r\\n\\t]"; " ") | .[0:4000])),
      ((($o | keys_unsorted) as $ks | $ks[] as $k | $o[$k] | rec($r)))
  elif type == "array" then .[] | rec($role)
  else empty end;
rec("")
JQ

cat >"$TMP/prog_line.jq" <<'JQ'
def rec($role):
  if type == "object" then
    . as $o
    | (($o.role? // $o.sender? // $role)
       | if type == "string" then ascii_downcase else "" end) as $r
    | (($o.model? | strings) | "M\t" + .),
      (($o.model? | objects | (.id? // .name?)) | strings | "M\t" + .),
      (($o.title? // $o.name?) | strings | select(length > 2) | "I\t" + .),
      ((($o.session_id? // $o.sessionId? // $o.conversation_id? // $o.conversationId? // $o.chat_id? // $o.chatId?) | strings) | "S\t" + .),
      ((["text", "content", "message", "body", "prompt", "completion"][] as $k
        | $o[$k]? | strings) as $t
       | "T\t" + $r + "\t" + ($t | gsub("[\\r\\n\\t]"; " ") | .[0:4000])),
      ((($o | keys_unsorted) as $ks | $ks[] as $k | $o[$k] | rec($r)))
  elif type == "array" then .[] | rec($role)
  else empty end;
fromjson? | rec("")
JQ

cat >"$TMP/stats.awk" <<'AWK'
BEGIN { FS = "\t"; had = 0; chats = 0; sess = 0 }
$1 == "M" { if (!($2 in m)) { m[$2] = 1; models[++nm] = $2 } next }
$1 == "I" { if (nt < tmax && !($2 in it)) { it[$2] = 1; titles[++nt] = $2 } next }
$1 == "S" { if (!($2 in ss)) { ss[$2] = 1; sess++ } next }
$1 == "F" { if (had) chats++; had = 0; next }
$1 == "T" {
  role = $2; text = $3
  if (length(text) < 4) next
  if (text in seen) next
  seen[text] = 1
  blocks++; chars += length(text)
  if (role == "user") u++
  else if (role == "assistant") a++
  else if (role == "tool") t++
  else if (role == "system") s++
  if (role == "user" && ns < 3 && length(text) > 30) samples[++ns] = text
  if (q != "" && nmq < 200 && index(tolower(text), tolower(q)) > 0) matches[++nmq] = text
  had = 1
  next
}
END {
  if (had) chats++
  chats += sess
  printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\n", chats, u, a, t, s, blocks, chars
  for (i = 1; i <= nm; i++) print models[i] > mf
  for (i = 1; i <= nt; i++) print titles[i] > tf
  for (i = 1; i <= ns; i++) print samples[i] > sf
  for (i = 1; i <= nmq; i++) print matches[i] > qf
}
AWK

# ---------------------------------------------------------------- emitters

emit_strings() {
  local file=$1 limit=$2
  [ "$limit" -le 0 ] && return 0
  strings -a "$file" 2>/dev/null | head -c "$limit" | awk '{ print "T\t\t" $0 }'
}

emit_json() {
  local file=$1 limit=$2
  [ "$limit" -le 0 ] && return 0
  head -c "$limit" "$file" 2>/dev/null | jq -r -f "$TMP/prog_doc.jq" 2>/dev/null ||
    emit_strings "$file" "$limit"
}

emit_jsonl() {
  local file=$1 limit=$2
  [ "$limit" -le 0 ] && return 0
  head -c "$limit" "$file" 2>/dev/null | jq -Rr -f "$TMP/prog_line.jq" 2>/dev/null
}

emit_sqlite() {
  local db=$1 limit=$2 table cols texty json rows sid
  sqlite3 -readonly "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%';" 2>/dev/null |
  while IFS= read -r table; do
    [ -n "$table" ] || continue
    case "$table" in
      *session*|*chat*|*conversation*|*thread*)
        case "$table" in
          *message*|*part*|*inbox*|*event*|*state*|*lock*|*permission*|*blob*) : ;;
          *)
            sqlite3 -readonly "$db" "SELECT id FROM \"$table\" LIMIT 2000;" 2>/dev/null |
              awk 'NF { print "S\t" $0 }'
            ;;
        esac
        ;;
    esac
    cols=$(sqlite3 -readonly "$db" "PRAGMA table_info(\"$table\");" 2>/dev/null)
    [ -n "$cols" ] || continue
    texty=$(printf '%s\n' "$cols" | cut -d'|' -f2 |
            grep -Ei 'data|text|content|message|body|value|prompt|title' | head -12)
    [ -n "$texty" ] || continue
    json=$(sqlite3 -readonly -json "$db" \
      "SELECT * FROM \"$table\" ORDER BY rowid DESC LIMIT 100;" 2>/dev/null)
    [ -n "$json" ] || continue
    printf '%s' "$json" | jq -r -f "$TMP/prog_doc.jq" 2>/dev/null
    case "$table" in
      *message*|*chat*|*conversation*|*thread*) : ;;
    esac
  done
}

emit_file() {
  local file=$1 limit=$2 kind=$3
  case "$kind" in
    sqlite) emit_sqlite "$file" "$limit" ;;
    jsonl)  emit_jsonl "$file" "$limit" ;;
    json)   emit_json "$file" "$limit" ;;
    *)      emit_strings "$file" "$limit" ;;
  esac
}

classify_file() {
  local file=$1 ext head
  ext=$(printf '%s' "${file##*.}" | tr '[:upper:]' '[:lower:]')
  head=$(head -c 16 "$file" 2>/dev/null)
  case "$head" in
    "SQLite format 3") echo sqlite; return ;;
  esac
  case "$ext" in
    sqlite|sqlite3|db|vscdb) echo sqlite ;;
    jsonl|ndjson) echo jsonl ;;
    json) echo json ;;
    *) echo text ;;
  esac
}

# ---------------------------------------------------------------- find

find_candidates() {
  local root=$1 depth=$2
  if [ -f "$root" ]; then
    printf '%s\n' "$root"
    return
  fi
  find "$root" -maxdepth "$depth" \
    \( -name Cache -o -name 'Code Cache' -o -name GPUCache -o -name DawnGraphiteCache \
       -o -name DawnWebGPUCache -o -name GraphiteDawnCache -o -name GrShaderCache \
       -o -name ShaderCache -o -name CachedData -o -name Crashpad -o -name node_modules \
       -o -name .git -o -name .venv -o -name venv -o -name __pycache__ \
       -o -name 'Service Worker' -o -name 'Shared Dictionary' -o -name CacheStorage \
       -o -name blob_storage -o -name logs -o -name log \) -prune -o \
    -type f \( -name '*.jsonl' -o -name '*.ndjson' -o -name '*.json' \
       -o -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' -o -name '*.vscdb' \
       -o -name '*.ldb' -o -name '*.log' -o -name '*.txt' \) \
    ! -name '*.db-wal' ! -name '*.db-shm' ! -name '*.sqlite-wal' ! -name '*.sqlite-shm' \
    ! -name '*.db-journal' ! -name 'Cookies' ! -name 'Cookies-journal' \
    ! -name 'Preferences' ! -name 'Local State' ! -name .DS_Store \
    -print 2>/dev/null
}

dir_size() {
  local root=$1
  find "$root" -type f -exec stat -f '%z' {} + 2>/dev/null | awk '{ s += $1 } END { printf "%d\n", s + 0 }'
}

# ---------------------------------------------------------------- chats

cmd_chats() {
  local max_mb=1024 max_file_mb="" depth=10 titles=5 query="" json_out="" \
        recent=0 no_defaults=0 do_sync=0 wipe_env=1 delay=""
  local roots=() add_roots=() orig_args=("$@")

  while [ $# -gt 0 ]; do
    case "$1" in
      --root) roots+=("$2"); shift 2 ;;
      --add-root) add_roots+=("$2"); shift 2 ;;
      --max-mb) max_mb=$2; shift 2 ;;
      --max-file-mb) max_file_mb=$2; shift 2 ;;
      --depth) depth=$2; shift 2 ;;
      --titles) titles=$2; shift 2 ;;
      --query) query=$2; shift 2 ;;
      --json) json_out=$2; shift 2 ;;
      --recent-first) recent=1; shift ;;
      --no-defaults) no_defaults=1; shift ;;
      --sync) do_sync=1; shift ;;
      --keep-env) wipe_env=0; shift ;;
      --delay) delay=$2; shift 2 ;;
      -h|--help) chats_help; return 0 ;;
      *) err "chats: unknown arg $1"; return 2 ;;
    esac
  done

  [ -n "$max_file_mb" ] || max_file_mb=$max_mb

  if [ -n "$delay" ]; then
    local fwd=() i=0
    while [ "$i" -lt ${#orig_args[@]} ]; do
      case "${orig_args[$i]}" in
        --delay) i=$((i + 2)); continue ;;
        *) fwd+=("${orig_args[$i]}"); i=$((i + 1)) ;;
      esac
    done
    schedule "$delay" chats "${fwd[@]}"
    return $?
  fi

  local budget=$((max_mb * MB))
  local per_file=$((max_file_mb * MB))
  local remaining=$budget
  local srcfile="$TMP/sources.tsv"
  : >"$srcfile"

  if [ ${#roots[@]} -eq 0 ] && [ "$no_defaults" -eq 0 ]; then
    while IFS='|' read -r name kind paths; do
      [ -n "$name" ] || continue
      scan_source "$name" "$kind" "$paths" "$remaining" "$per_file" "$depth" \
                  "$titles" "$query" "$recent" "$srcfile"
      remaining=$((remaining - SCAN_READ))
      [ "$remaining" -lt 0 ] && remaining=0
    done < <(source_list)
  fi
  local p
  for p in ${roots[@]+"${roots[@]}"}; do
    scan_source "$(basename "$p")" custom "$p" "$remaining" "$per_file" "$depth" \
                "$titles" "$query" "$recent" "$srcfile"
    remaining=$((remaining - SCAN_READ))
    [ "$remaining" -lt 0 ] && remaining=0
  done
  for p in ${add_roots[@]+"${add_roots[@]}"}; do
    scan_source "$(basename "$p")" custom "$p" "$remaining" "$per_file" "$depth" \
                "$titles" "$query" "$recent" "$srcfile"
    remaining=$((remaining - SCAN_READ))
    [ "$remaining" -lt 0 ] && remaining=0
  done

  print_chat_report "$srcfile" "$max_mb" "$max_file_mb" "$titles" "$query"

  local out_path=""
  if [ "$do_sync" -eq 1 ] && [ -z "$json_out" ]; then
    out_path="$TMP/report.json"
  else
    out_path="$json_out"
  fi
  if [ -n "$out_path" ]; then
    write_chats_json "$srcfile" "$out_path" "$max_mb" "$query"
    say "JSON report: $out_path"
  fi
  if [ "$do_sync" -eq 1 ]; then
    if [ "$wipe_env" -eq 1 ]; then
      cmd_sync --report "$out_path" --encrypt --wipe-env
    else
      cmd_sync --report "$out_path" --encrypt --keep-env
    fi
  fi
  return 0
}

chats_help() {
  cat <<EOF
usage: $PROG chats [options]

  --root PATH         scan only this path (repeatable)
  --max-mb N          total MB to read (default 1024)
  --max-file-mb N     per-file limit (default = --max-mb)
  --depth N           directory depth (default 10)
  --titles N          chat titles to show (default 5)
  --query TEXT        search inside messages
  --json PATH         save JSON report
  --recent-first      newest files first
  --no-defaults       do not use the built-in app list
  --sync              upload the report after the run
  --keep-env          keep ./sync.env after upload (default: delete it)
  --delay 1h16m       delayed start
EOF
}

scan_source() {
  local name=$1 kind=$2 paths=$3 budget=$4 per_file=$5 depth=$6 \
        titles=$7 query=$8 recent=$9 srcfile=${10}
  local idx root size mtime type used=0 files=0 disk=0 chats=0
  local u=0 a=0 t=0 s=0 blocks=0 chars=0
  local selected
  idx=$(wc -l <"$srcfile" | tr -d ' ')
  local models="$TMP/models.$idx" titlesf="$TMP/titles.$idx" \
        samples="$TMP/samples.$idx" matches="$TMP/matches.$idx"
  selected="$TMP/selected.$idx"
  : >"$selected"

  while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -e "$root" ] || continue
    if [ -d "$root" ]; then
      disk=$((disk + $(dir_size "$root")))
    else
      disk=$((disk + $(stat -f '%z' "$root" 2>/dev/null || echo 0)))
    fi
  done < <(printf '%s\n' "$paths" | tr ';' '\n')

  local listfile="$TMP/list.$idx"
  : >"$listfile"
  printf '%s\n' "$paths" | tr ';' '\n' | while IFS= read -r root; do
    [ -n "$root" ] || continue
    [ -e "$root" ] || continue
    find_candidates "$root" "$depth" | while IFS= read -r f; do
      [ -n "$f" ] || continue
      st=$(stat -f '%z %m %N' "$f" 2>/dev/null) || continue
      sz=${st%% *}; rest=${st#* }; mt=${rest%% *}; fp=${rest#* }
      printf '%s\t%s\t%s\n' "$sz" "$mt" "$fp" >>"$listfile"
    done
  done

  if [ "$recent" -eq 1 ]; then
    sort -t "$(printf '\t')" -k2,2nr "$listfile" >"$listfile.sorted"
  else
    sort -t "$(printf '\t')" -k2,2n "$listfile" >"$listfile.sorted"
  fi

  local total=0
  while IFS="$(printf '\t')" read -r size mtime f; do
    [ -n "$f" ] || continue
    total=$((total + 1))
    [ "$size" -gt 0 ] || continue
    [ "$size" -gt "$per_file" ] && continue
    [ $((used + size)) -gt "$budget" ] && continue
    type=$(classify_file "$f")
    printf '%s\t%s\t%s\n' "$f" "$type" "$size" >>"$selected"
    used=$((used + size))
  done <"$listfile.sorted"

  files=$total

  {
    while IFS="$(printf '\t')" read -r f type size; do
      printf 'F\t%s\n' "$f"
      emit_file "$f" "$size" "$type"
    done <"$selected"
  } | awk -F '\t' -v tmax="$titles" -v q="$query" \
        -v mf="$models" -v tf="$titlesf" -v sf="$samples" -v qf="$matches" \
        -f "$TMP/stats.awk" >"$TMP/stat.$idx"

  read chats u a t s blocks chars <"$TMP/stat.$idx" || true
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$chats" "$u" "$a" "$t" "$s" "$blocks" "$files" "$disk" "$used" >>"$srcfile"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$models" "$titlesf" "$samples" "$matches" \
    "$chars" >"$TMP/source.$idx.meta"
  SCAN_READ=$used
}

print_chat_report() {
  local srcfile=$1 max_mb=$2 max_file_mb=$3 titles=$4 query=$5
  local name chats u a t s blocks files disk used
  local tc=0 tu=0 ta=0 tt=0 tb=0

  say ""
  printf '%86s\n' "AI CHATS INVENTORY" | sed 's/^ *//'
  say "======================================================================================"
  printf '%-24s%6s%6s%6s%8s%8s%11s%11s\n' source chats user asst blocks files "on disk" read
  say "--------------------------------------------------------------------------------------"

  local any=0
  while IFS="$(printf '\t')" read -r name chats u a t s blocks files disk used; do
    [ -n "$name" ] || continue
    if [ "$chats" -eq 0 ] && [ "$blocks" -eq 0 ] && [ "$disk" -eq 0 ]; then
      continue
    fi
    any=1
    printf '%-24.24s%6s%6s%6s%8s%8s%11s%11s\n' \
      "$name" "$chats" "$u" "$a" "$blocks" "$files" "$(human "$disk")" "$(human "$used")"
    tc=$((tc + chats)); tu=$((tu + u)); ta=$((ta + a)); tb=$((tb + blocks))
  done <"$srcfile"

  if [ "$any" -eq 0 ]; then
    say "Nothing found. Check paths with --root."
    return
  fi
  say "--------------------------------------------------------------------------------------"
  printf '%-24s%6s%6s%6s%8s\n' TOTAL "$tc" "$tu" "$ta" "$tb"
  say "======================================================================================"

  while IFS="$(printf '\t')" read -r name chats u a t s blocks files disk used; do
    [ -n "$name" ] || continue
    [ "$chats" -eq 0 ] && [ "$blocks" -eq 0 ] && continue
    say ""
    say "> $name"
    say "   extracted: $blocks text blocks  (tool: $t, system: $s)"

    local idx
    idx=$(awk -F "\t" -v n="$name" '$1 == n { print NR; exit }' "$srcfile")
    local meta="$TMP/source.$((idx - 1)).meta"
    if [ -f "$meta" ]; then
      IFS="$(printf '\t')" read -r _ models tf sf qf chars <"$meta"
      if [ -s "$models" ]; then
        say "   models: $(paste -sd ', ' "$models" | head -c 400)"
      fi
      if [ -s "$tf" ]; then
        say "   chat titles:"
        head -n "$titles" "$tf" | while IFS= read -r line; do
          say "     - $(printf '%s' "$line" | cut -c1-90)"
        done
      fi
      if [ -s "$sf" ]; then
        say "   sample prompts:"
        head -n 3 "$sf" | while IFS= read -r line; do
          say "     - $(printf '%s' "$line" | cut -c1-160)"
        done
      fi
      if [ -n "$query" ] && [ -s "$qf" ]; then
        say "   matches for '$query': $(wc -l <"$qf" | tr -d ' ')"
        head -n 10 "$qf" | while IFS= read -r line; do
          say "     - $(printf '%s' "$line" | cut -c1-160)"
        done
      fi
    fi
  done <"$srcfile"
}

write_chats_json() {
  local srcfile=$1 out=$2 max_mb=$3 query=$4
  local first=1
  {
    printf '{"generated_at": %s, "max_mb": %s, "query": ' "$(date +%s)" "$max_mb"
    if [ -n "$query" ]; then jq -Rn --arg q "$query" '$q'; else printf 'null'; fi
    printf ', "sources": ['
    while IFS="$(printf '\t')" read -r name chats u a t s blocks files disk used; do
      [ -n "$name" ] || continue
      [ "$first" -eq 1 ] || printf ','
      first=0
      printf '{"name": "%s", "chats": %s, "user": %s, "assistant": %s, "tool": %s, "blocks": %s, "files": %s, "disk_bytes": %s, "read_bytes": %s}' \
        "$(printf '%s' "$name" | sed 's/"/\\"/g')" "$chats" "$u" "$a" "$t" "$blocks" "$files" "$disk" "$used"
    done <"$srcfile"
    printf ']}\n'
  } >"$out"
}

# ---------------------------------------------------------------- telegram

tg_roots() {
  local pats=(
    "$HOME/Library/Group Containers/*.ru.keepcoder.Telegram/appstore"
    "$HOME/Library/Group Containers/*.ru.keepcoder.Telegram"
    "$HOME/Library/Application Support/Telegram Desktop/tdata"
    "$HOME/.local/share/TelegramDesktop/tdata"
    "$HOME/.local/share/TelegramDesktop"
  )
  local out=() p g
  for p in "${pats[@]}"; do
    while IFS= read -r g; do
      [ -n "$g" ] && [ -d "$g" ] && out+=("$g")
    done < <(compgen -G "$p" 2>/dev/null)
  done
  # deepest first, drop nested
  printf '%s\n' ${out[@]+"${out[@]}"} | awk 'NF { print length "\t" $0 }' |
    sort -rn | cut -f2- | awk '{
      keep = 1
      for (i = 0; i < n; i++) {
        if ($0 == kept[i] || index($0, kept[i] "/") == 1) { keep = 0; break }
      }
      if (keep) { kept[n++] = $0; print }
    }'
}

tg_kind() {
  local path=$1 name ext
  name=$(basename "$path")
  ext=$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')
  case "$name" in
    *_partial*|*.meta|*.tmp|*.part) echo partial; return ;;
  esac
  case "$ext" in
    jpg|jpeg|png|webp|heic|bmp) echo photo ;;
    mp4|mov|mkv|webm|avi) echo video ;;
    mp3|m4a|ogg|opus|flac|wav|aac) echo audio ;;
    gif) echo gif ;;
    tgs) echo sticker ;;
    pdf|zip|docx|xlsx|txt|epub) echo document ;;
    *)
      case "$name" in
        *photo*) echo photo ;;
        *voice*) echo audio ;;
        *sticker*) echo sticker ;;
        *video*) echo video ;;
        *) echo document ;;
      esac
      ;;
  esac
}

tg_category() {
  local rel=$1 name=$2
  case "/$rel/" in
    */postbox/db/*) echo db ;;
    */postbox/media/*) echo media ;;
    */logs/*) echo logs ;;
    */Wallpapers/*) echo wallpapers ;;
    */cache*|*/cached/*|*/temp/*) echo cache ;;
    *) echo other ;;
  esac
}

cmd_telegram() {
  local roots=() collect="" only="media" max_mb=1024 db_mb=50 newer="" \
        include_partial=0 top=5 json_out="" account="" delay="" orig_args=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) roots+=("$2"); shift 2 ;;
      --account) account=$2; shift 2 ;;
      --max-mb) max_mb=$2; shift 2 ;;
      --collect) collect=$2; shift 2 ;;
      --only) only=$2; shift 2 ;;
      --db-mb) db_mb=$2; shift 2 ;;
      --newer-days) newer=$2; shift 2 ;;
      --include-partial) include_partial=1; shift ;;
      --top) top=$2; shift 2 ;;
      --json) json_out=$2; shift 2 ;;
      --delay) delay=$2; shift 2 ;;
      -h|--help) telegram_help; return 0 ;;
      *) err "telegram: unknown arg $1"; return 2 ;;
    esac
  done

  if [ -n "$delay" ]; then
    local fwd=() i=0
    while [ "$i" -lt ${#orig_args[@]} ]; do
      case "${orig_args[$i]}" in
        --delay) i=$((i + 2)); continue ;;
        *) fwd+=("${orig_args[$i]}"); i=$((i + 1)) ;;
      esac
    done
    schedule "$delay" telegram "${fwd[@]}"
    return $?
  fi

  local r
  if [ ${#roots[@]} -eq 0 ]; then
    while IFS= read -r r; do roots+=("$r"); done < <(tg_roots)
  fi
  if [ ${#roots[@]} -eq 0 ]; then
    say "Telegram not found. Set --root ~/Library/Group\\ Containers/.../appstore"
    return 1
  fi

  local list="$TMP/tg.tsv"
  : >"$list"
  for r in "${roots[@]}"; do
    find "$r" \( -name .DS_Store -o -name '.com.apple*' \) -prune -o \
      \( -type f -o -type l \) -print 2>/dev/null | while IFS= read -r p; do
        local rel=${p#"$r"/} acc cat kind size mtime broken=0
        case "$rel" in
          account-*) acc=${rel%%/*} ;;
          *) acc=tdata ;;
        esac
        [ -n "$account" ] && case "$acc" in *"$account"*) : ;; *) continue ;; esac
        cat=$(tg_category "$rel" "$(basename "$p")")
        if stat -f '%z %m' "$p" >/dev/null 2>&1; then
          read -r size mtime < <(stat -f '%z %m' "$p")
        else
          size=0; mtime=0; broken=1; cat="broken"; kind="broken link"
        fi
        [ "$broken" -eq 1 ] || kind=$(tg_kind "$p")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$acc" "$cat" "$kind" "$size" "$mtime" "$p" >>"$list"
      done
  done

  if [ ! -s "$list" ]; then
    say "Telegram cache is empty."
    return 1
  fi

  print_tg_report "$list" "$top"

  if [ -n "$collect" ]; then
    tg_collect "$list" "$collect" "$only" "$max_mb" "$db_mb" "$newer" "$include_partial"
  fi

  if [ -n "$json_out" ]; then
    write_tg_json "$list" "$json_out"
    say "JSON report: $json_out"
  fi
  return 0
}

telegram_help() {
  cat <<EOF
usage: $PROG telegram [options]

  --root PATH         Telegram root (tdata or appstore), repeatable
  --account ID        only this account
  --collect DIR       copy cache into DIR
  --only MODE         media (default), cache, db, chats, all
  --max-mb N          copy budget (default 1024)
  --db-mb N           max MB from the encrypted database (default 50)
  --newer-days N      only files newer than N days
  --include-partial   copy partial files and .meta
  --top N             how many largest files to show
  --json PATH         save JSON report
  --delay 1h16m       delayed start
EOF
}

print_tg_report() {
  local list=$1 top=$2
  say ""
  say "TELEGRAM CACHE"
  say "=============================================================================="
  awk -F '\t' '
    function h(n,   u,i) {
      split("B KB MB GB", u, " "); i = 1
      while (n >= 1024 && i < 4) { n /= 1024; i++ }
      if (i == 1) return sprintf("%d %s", n, u[i])
      return sprintf("%.1f %s", n, u[i])
    }
    $2 == "media" { mb[$1] += $4; mf[$1]++ }
    $2 == "db"    { db[$1] += $4 }
    { bytes[$1] += $4; files[$1]++; cats[$2] += $4; ncat[$2]++
      if ($2 == "media") { tmb += $4; tmf++ }
      if ($2 == "db") tdb += $4
      tbytes += $4
      if ($2 == "media" || $2 == "cache") { kinds[$3] += $4; nkind[$3]++ } }
    END {
      printf "%-28s%12s%8s%12s%12s\n", "account", "media", "files", "db", "total"
      printf "%-28s%12s%8s%12s%12s\n", "----------------------------", "-----", "-----", "-----", "-----"
      for (a in bytes)
        printf "%-28.28s%12s%8d%12s%12s\n", a, h(mb[a] + 0), mf[a] + 0, h(db[a] + 0), h(bytes[a])
      printf "%-28s%12s%8d%12s%12s\n", "TOTAL", h(tmb), tmf, h(tdb), h(tbytes)
      print ""
      print "categories:"
      for (k in cats) printf "  %s: %s / %d\n", k, h(cats[k]), ncat[k]
      print "media types:"
      for (k in kinds) printf "  %s: %d (%s)\n", k, nkind[k], h(kinds[k])
    }' "$list"
  say "largest files:"
  sort -t "$(printf '\t')" -k4,4nr "$list" | head -n "$top" |
    while IFS="$(printf '\t')" read -r acc cat kind size mtime path; do
      say "   $(human "$size")  $kind  $(basename "$path")"
    done
  say "   (message text in postbox/db is encrypted — needs Telegram keys)"
}

tg_collect() {
  local list=$1 dest=$2 only=$3 max_mb=$4 db_mb=$5 newer=$6 include_partial=$7
  local budget=$((max_mb * MB)) db_cap=$((db_mb * MB))
  local db_copied=0 copied=0 copied_bytes=0 skipped=0
  local cutoff=0 acc cat kind size mtime path take out rel base n
  [ -n "$newer" ] && cutoff=$(( $(date +%s) - newer * 86400 ))

  local sorted="$TMP/tg.sorted"
  sort -t "$(printf '\t')" -k5,5nr "$list" >"$sorted"
  local manifest="$TMP/manifest.tsv"
  : >"$manifest"

  while IFS="$(printf '\t')" read -r acc cat kind size mtime path; do
    [ "$size" -gt 0 ] || continue
    case "$only" in
      media) [ "$cat" = media ] || continue ;;
      cache) [ "$cat" = cache ] || continue ;;
      db)    [ "$cat" = db ] || continue ;;
      chats) [ "$cat" = db ] || continue ;;
      all)   : ;;
    esac
    [ "$include_partial" -eq 1 ] || [ "$kind" != partial ] || continue
    [ "$cutoff" -gt 0 ] && [ "$mtime" -lt "$cutoff" ] && continue

    take=$size
    if [ "$cat" = db ]; then
      take=$((db_cap - db_copied))
      [ "$take" -gt "$size" ] && take=$size
      [ "$take" -le 0 ] && { skipped=$((skipped + 1)); continue; }
    fi
    [ $((copied_bytes + take)) -gt "$budget" ] && { skipped=$((skipped + 1)); continue; }

    case "$cat" in
      media) rel="media" ;;
      db) rel="db" ;;
      cache) rel="cache" ;;
      logs) rel="logs" ;;
      wallpapers) rel="wallpapers" ;;
      *) rel="other" ;;
    esac
    out="$dest/telegram_cache/$acc/$rel/$(basename "$path" | tr '/:' '__')"
    mkdir -p "$(dirname "$out")"
    n=1
    while [ -e "$out" ]; do out="$dest/telegram_cache/$acc/$rel/${n}_$(basename "$path" | tr '/:' '__')"; n=$((n + 1)); done

    if [ "$cat" = db ] && [ "$take" -lt "$size" ]; then
      head -c "$take" "$path" >"$out" 2>/dev/null || { skipped=$((skipped + 1)); continue; }
    else
      cp -p "$path" "$out" 2>/dev/null || { skipped=$((skipped + 1)); continue; }
    fi
    [ "$cat" = db ] && db_copied=$((db_copied + take))
    copied=$((copied + 1)); copied_bytes=$((copied_bytes + take))
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$path" "$out" "$take" "$kind" "$cat" \
      "$([ "$take" -lt "$size" ] && echo true || echo false)" >>"$manifest"
  done <"$sorted"

  mkdir -p "$dest/telegram_cache"
  jq -Rn --arg now "$(date +%s)" --arg roots "" '
    [inputs | select(length > 0) | split("\t") |
      {src: .[0], dst: .[1], size: (.[2] | tonumber), kind: .[3],
       category: .[4], truncated: (.[5] == "true")}] as $items |
    {generated_at: ($now | tonumber), roots: ($roots | split(";")), items: $items}
  ' <"$manifest" >"$dest/telegram_cache/manifest.json"

  say ""
  say "COPIED: $copied files, $(human "$copied_bytes") -> $dest/telegram_cache"
  [ "$only" = chats ] || [ "$only" = db ] && say "encrypted db taken: $(human "$db_copied") (limit $db_mb MB)"
  say "manifest: $dest/telegram_cache/manifest.json"
  [ "$skipped" -gt 0 ] && say "over limit: $skipped files"
}

write_tg_json() {
  local list=$1 out=$2
  jq -Rn --arg now "$(date +%s)" '
    [inputs | select(length > 0) | split("\t") |
      {account: .[0], category: .[1], kind: .[2],
       size: (.[3] | tonumber), mtime: (.[4] | tonumber), path: .[5]}] as $items |
    {generated_at: ($now | tonumber), items: $items}
  ' <"$list" >"$out"
}

# ---------------------------------------------------------------- crypto

crypto_password() {
  local pf=$1
  if [ -n "$pf" ]; then
    [ -f "$pf" ] && { head -n 1 "$pf" | tr -d '\r\n'; return; }
    return
  fi
  if [ -n "${SYNC_PASSWORD:-}" ]; then
    printf '%s' "$SYNC_PASSWORD"
    return
  fi
  if [ -t 0 ]; then
    printf 'password: ' >&2
    stty -echo 2>/dev/null
    IFS= read -r pw
    stty echo 2>/dev/null
    printf '\n' >&2
    printf '%s' "$pw"
  fi
}

cmd_encrypt() {
  local files=() remove=0 pf=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --remove) remove=1; shift ;;
      --password-file) pf=$2; shift 2 ;;
      -h|--help) say "usage: $PROG encrypt FILE... [--remove] [--password-file PATH]"; return 0 ;;
      *) files+=("$1"); shift ;;
    esac
  done
  local pw
  pw=$(crypto_password "$pf")
  if [ -z "$pw" ]; then say "enc 1 fail: no password"; return 1; fi
  local i=0 rc=0
  for f in ${files[@]+"${files[@]}"}; do
    i=$((i + 1))
    if [ ! -f "$f" ]; then say "enc $i fail: not found"; rc=1; continue; fi
    if AIC_PW="$pw" python3 "$CRYPTO_PY" enc <"$f" >"$f.enc" 2>"$TMP/err"; then
      [ "$remove" -eq 1 ] && rm -f "$f"
      say "enc $i done"
    else
      rc=1; say "enc $i fail: $(cat "$TMP/err")"; rm -f "$f.enc"
    fi
  done
  return $rc
}

cmd_decrypt() {
  local files=() outdir="" pf=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out-dir) outdir=$2; shift 2 ;;
      --password-file) pf=$2; shift 2 ;;
      -h|--help) say "usage: $PROG decrypt FILE... [--out-dir DIR] [--password-file PATH]"; return 0 ;;
      *) files+=("$1"); shift ;;
    esac
  done
  local pw
  pw=$(crypto_password "$pf")
  if [ -z "$pw" ]; then say "dec 1 fail: no password"; return 1; fi
  local i=0 rc=0 name out
  for f in ${files[@]+"${files[@]}"}; do
    i=$((i + 1))
    if [ ! -f "$f" ]; then say "dec $i fail: not found"; rc=1; continue; fi
    name=$(basename "$f"); name=${name%.enc}
    if [ -n "$outdir" ]; then out="$outdir/$name"; else out="$(dirname "$f")/$name"; fi
    mkdir -p "$(dirname "$out")"
    if AIC_PW="$pw" python3 "$CRYPTO_PY" dec <"$f" >"$out" 2>"$TMP/err"; then
      say "dec $i done"
    else
      rc=1; say "dec $i fail: $(cat "$TMP/err")"; rm -f "$out"
    fi
  done
  return $rc
}

# ---------------------------------------------------------------- github sync

load_sync_env() {
  local envf="$BASE_DIR/sync.env" line k v
  [ -f "$envf" ] || return 0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) : ;; *) continue ;; esac
    k=${line%%=*}; v=${line#*=}
    v=$(printf '%s' "$v" | sed "s/^[\"']//; s/[\"']$//")
    case "$k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    eval "cur=\${$k:-}"
    [ -z "$cur" ] && export "$k=$v"
  done <"$envf"
}

gh_token() {
  if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; return; fi
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"; return; fi
  have gh && gh auth token 2>/dev/null | tr -d '\r\n'
}

gh_request() {
  local method=$1 url=$2 token=$3 data_file=${4:-}
  if [ -n "$data_file" ]; then
    curl -s -X "$method" -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "User-Agent: bvaigen-sh" --data-binary @"$data_file" "$url"
  else
    curl -s -X "$method" -H "Authorization: Bearer $token" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "User-Agent: bvaigen-sh" "$url"
  fi
}

upload_file() {
  local repo=$1 branch=$2 path=$3 file=$4 token=$5 sha payload response
  local url="$API/repos/$repo/contents/$path"
  sha=$(gh_request GET "$url?ref=$branch" "$token" | jq -r '.sha? // empty')
  payload="$TMP/payload.$$"
  jq -n --arg m "sync $path" --arg b "$branch" \
        --arg c "$(base64 <"$file" | tr -d '\n')" \
        '{message: $m, branch: $b, content: $c}' >"$payload"
  [ -n "$sha" ] && jq --arg s "$sha" '. + {sha: $s}' "$payload" >"$payload.sha" \
    && mv "$payload.sha" "$payload"
  response=$(gh_request PUT "$url" "$token" "$payload")
  rm -f "$payload" "$payload.sha"
  printf '%s' "$response" | jq -e '.content.path? // .commit.sha?' >/dev/null 2>&1
}

# ---------------------------------------------------------------- sync.env transport

env_secret_password() {
  local pf=$1
  if [ -n "$pf" ]; then
    [ -f "$pf" ] && { head -n 1 "$pf" | tr -d '\r\n'; return; }
    return
  fi
  if [ -n "${SYNC_ENV_PASSWORD:-}" ]; then
    printf '%s' "$SYNC_ENV_PASSWORD"
    return
  fi
  if [ -t 0 ]; then
    printf 'sync.env passphrase: ' >&2
    stty -echo 2>/dev/null
    IFS= read -r pw
    stty echo 2>/dev/null
    printf '\n' >&2
    printf '%s' "$pw"
  fi
}

cmd_secrets() {
  local action=${1:-}; [ $# -gt 0 ] && shift
  local repo="$DEFAULT_REPO" branch="${GITHUB_BRANCH:-main}" folder="ai" pf="" token=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --branch) branch=$2; shift 2 ;;
      --folder) folder=$2; shift 2 ;;
      --password-file) pf=$2; shift 2 ;;
      -h|--help)
        say "usage: $PROG secrets push|pull [--repo owner/name] [--folder ai] [--password-file PATH]"
        return 0 ;;
      *) err "secrets: unknown arg $1"; return 2 ;;
    esac
  done

  case "$action" in
    push|upload)
      local src="$BASE_DIR/sync.env"
      [ -f "$src" ] || { say "secrets push fail: no sync.env"; return 1; }
      token=$(gh_token)
      [ -n "$token" ] || { say "secrets push fail: no token"; return 1; }
      local pw
      pw=$(env_secret_password "$pf")
      [ -n "$pw" ] || { say "secrets push fail: no passphrase (SYNC_ENV_PASSWORD)"; return 1; }
      local tmp="$TMP/sync.env.enc"
      if ! AIC_PW="$pw" python3 "$CRYPTO_PY" enc <"$src" >"$tmp" 2>/dev/null; then
        say "secrets push fail: encrypt"; return 1
      fi
      if upload_file "$repo" "$branch" "$folder/sync.env.enc" "$tmp" "$token"; then
        say "secrets push done"
      else
        say "secrets push fail: upload"; return 1
      fi
      ;;
    pull|bootstrap)
      token=$(gh_token)
      if [ -z "$token" ]; then
        printf 'GitHub token: ' >&2
        stty -echo 2>/dev/null
        IFS= read -r token
        stty echo 2>/dev/null
        printf '\n' >&2
      fi
      [ -n "$token" ] || { say "secrets pull fail: no token"; return 1; }
      local pw
      pw=$(env_secret_password "$pf")
      [ -n "$pw" ] || { say "secrets pull fail: no passphrase (SYNC_ENV_PASSWORD)"; return 1; }
      local url="$API/repos/$repo/contents/$folder/sync.env.enc?ref=$branch"
      local b64="$TMP/sync.env.b64" enc="$TMP/sync.env.enc" plain="$TMP/sync.env"
      gh_request GET "$url" "$token" | jq -r '.content? // empty' | tr -d '\n' >"$b64"
      [ -s "$b64" ] || { say "secrets pull fail: not found"; return 1; }
      base64 -D <"$b64" >"$enc" 2>/dev/null || base64 -d <"$b64" >"$enc" 2>/dev/null
      if ! AIC_PW="$pw" python3 "$CRYPTO_PY" dec <"$enc" >"$plain" 2>/dev/null; then
        say "secrets pull fail: wrong password or corrupted file"; return 1
      fi
      umask 077
      cp "$plain" "$BASE_DIR/sync.env"
      chmod 600 "$BASE_DIR/sync.env"
      rm -f "$b64" "$enc" "$plain"
      say "secrets pull done"
      ;;
    *)
      say "usage: $PROG secrets push|pull"; return 2 ;;
  esac
}

cmd_sync() {
  local repo="$DEFAULT_REPO" branch="${GITHUB_BRANCH:-main}" folder="ai" \
        report="$BASE_DIR/ai/report.json" telegram="$BASE_DIR/tg_chats/telegram_cache/manifest.json" \
        encrypt=0 keep=0 pf="" failed=0 wipe_env=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --branch) branch=$2; shift 2 ;;
      --folder) folder=$2; shift 2 ;;
      --report) report=$2; shift 2 ;;
      --telegram) telegram=$2; shift 2 ;;
      --encrypt) encrypt=1; shift ;;
      --keep) keep=1; shift ;;
      --wipe-env) wipe_env=1; shift ;;
      --keep-env) wipe_env=0; shift ;;
      --password-file) pf=$2; shift 2 ;;
      -h|--help)
        say "usage: $PROG sync [--encrypt] [--wipe-env] [--repo owner/name] [--folder ai]"
        say "  --keep-env  keep ./sync.env after the run (default: delete it)"
        return 0 ;;
      *) err "sync: unknown arg $1"; return 2 ;;
    esac
  done

  local token pw=""
  token=$(gh_token)
  [ "$encrypt" -eq 1 ] && pw=$(crypto_password "$pf")

  local n=1 local_file remote_name tmpf abs
  for spec in "report:$report" "data:$telegram"; do
    remote_name=${spec%%:*}; local_file=${spec#*:}
    if [ -z "$token" ]; then say "sync $n fail: no token"; failed=1; n=$((n + 1)); continue; fi
    if [ "$encrypt" -eq 1 ] && [ -z "$pw" ]; then say "sync $n fail: no password"; failed=1; n=$((n + 1)); continue; fi
    if [ ! -f "$local_file" ]; then say "sync $n fail: no $(basename "$local_file")"; failed=1; n=$((n + 1)); continue; fi

    tmpf="$TMP/upload.$n"
    if [ "$encrypt" -eq 1 ]; then
      AIC_PW="$pw" python3 "$CRYPTO_PY" enc <"$local_file" >"$tmpf" 2>/dev/null || {
        say "sync $n fail: encrypt"; failed=1; n=$((n + 1)); continue; }
      remote_name="$remote_name.enc"
    else
      cp "$local_file" "$tmpf"
    fi
    if upload_file "$repo" "$branch" "$folder/$remote_name" "$tmpf" "$token"; then
      rm -f "$tmpf"
      if [ "$keep" -eq 0 ]; then
        abs="$(cd "$(dirname "$local_file")" 2>/dev/null && pwd)/$(basename "$local_file")"
        case "$abs" in "$BASE_DIR"/ai/*) rm -f "$local_file" ;; esac
      fi
      say "sync $n done"
    else
      say "sync $n fail: upload"; failed=1
    fi
    n=$((n + 1))
  done
  if [ "$wipe_env" -eq 1 ]; then
    rm -f "$BASE_DIR/sync.env"
    say "sync.env wiped"
  fi
  return $failed
}


# ---------------------------------------------------------------- publish code

code_password() {
  local pf=$1
  if [ -n "$pf" ]; then
    [ -f "$pf" ] && { head -n 1 "$pf" | tr -d '\r\n'; return; }
    return
  fi
  if [ -n "${PUBLISH_PASSWORD:-}" ]; then printf '%s' "$PUBLISH_PASSWORD"; return; fi
  if [ -n "${SYNC_PASSWORD:-}" ]; then printf '%s' "$SYNC_PASSWORD"; return; fi
  if [ -t 0 ]; then
    printf 'publish passphrase: ' >&2
    stty -echo 2>/dev/null
    IFS= read -r pw
    stty echo 2>/dev/null
    printf '\n' >&2
    printf '%s' "$pw"
  fi
}

cmd_publish() {
  local repo="$DEFAULT_REPO" branch="${GITHUB_BRANCH:-main}" folder="ai" pf="" plain=0
  local src="$BASE_DIR/$(basename "$0")" name
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) repo=$2; shift 2 ;;
      --branch) branch=$2; shift 2 ;;
      --folder) folder=$2; shift 2 ;;
      --file) src=$2; shift 2 ;;
      --password-file) pf=$2; shift 2 ;;
      --plain) plain=1; shift ;;
      -h|--help)
        say "usage: $PROG publish [--repo owner/name] [--folder ai] [--plain] [--password-file PATH]"
        say "  uploads this script (encrypted by default) as ai/<name>.enc"
        return 0 ;;
      *) err "publish: unknown arg $1"; return 2 ;;
    esac
  done

  need curl jq base64
  [ -f "$src" ] || { say "publish fail: no $src"; return 1; }
  local token
  token=$(gh_token)
  [ -n "$token" ] || { say "publish fail: no token"; return 1; }

  name=$(basename "$src")
  local tmp="$TMP/publish.bin" remote
  if [ "$plain" -eq 1 ]; then
    cp "$src" "$tmp" || { say "publish fail: copy"; return 1; }
    remote="$name"
  else
    local pw
    pw=$(code_password "$pf")
    [ -n "$pw" ] || { say "publish fail: no passphrase"; return 1; }
    AIC_PW="$pw" python3 "$CRYPTO_PY" enc <"$src" >"$tmp" 2>/dev/null || {
      say "publish fail: encrypt"; return 1; }
    remote="$name.enc"
  fi

  if upload_file "$repo" "$branch" "$folder/$remote" "$tmp" "$token"; then
    rm -f "$tmp"
    say "publish done: $repo:$folder/$remote"
    say "sha256: $(shasum -a 256 "$src" | awk '{print $1}')"
  else
    rm -f "$tmp"
    say "publish fail: upload"
    return 1
  fi
}

# ---------------------------------------------------------------- misc

parse_delay() {
  local t secs
  t=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  secs=$(awk -v s="$t" 'BEGIN{
    if (index(s, ":") > 0) {
      n = split(s, p, ":"); h = 0; m = p[n-1]; sec = p[n]
      if (n >= 3) { h = p[n-2] } else { h = 0; m = p[n-1]; sec = p[n] }
      if (n == 2) { h = p[1]; m = p[2]; sec = 0 }
      print h*3600 + m*60 + sec; exit
    }
    total = 0; num = ""
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (c >= "0" && c <= "9") { num = num c; continue }
      if (num != "") {
        if (c == "h") total += num * 3600
        else if (c == "m") total += num * 60
        else if (c == "s") total += num
        else exit 1
        num = ""
      } else if (c != "h" && c != "m" && c != "s") exit 1
    }
    if (num != "") total += num * 60
    print total
  }')
  [ -n "$secs" ] && [ "$secs" -gt 0 ] || return 1
  printf '%s' "$secs"
}

schedule() {
  local delay=$1; shift
  local secs cmd log
  secs=$(parse_delay "$delay") || { err "bad delay: $delay"; return 2; }
  log="$BASE_DIR/runs/$(date +%Y%m%d-%H%M%S).log"
  mkdir -p "$BASE_DIR/runs"
  cmd=$(printf '%q ' "$(command -v bash)" "$BASE_DIR/$(basename "$0")" "$@")
  sh -c "sleep $secs; exec $cmd" </dev/null >"$log" 2>&1 &
  say "Scheduled: start $(date -v +${secs}S '+%d.%m at %H:%M:%S' 2>/dev/null || date -r $(( $(date +%s) + secs )) '+%d.%m at %H:%M:%S')"
  say "Log: $log"
  say "Cancel: kill $!"
}

usage() {
  cat <<EOF
$PROG — local AI chat inventory + Telegram cache + AIC1 sync (bash).

commands:
  chats       inventory of local AI chats (default)
  telegram    Telegram cache inventory and copy
  sync        upload report/data to GitHub (AIC1 encryption optional)
  secrets     push/pull encrypted sync.env (push, pull)
  publish     upload this script (encrypted) to GitHub
  encrypt     encrypt files with a password
  decrypt     decrypt .enc files

secrets pull  — download ai/sync.env.enc, decrypt with SYNC_ENV_PASSWORD into ./sync.env (600)
secrets push  — encrypt ./sync.env with SYNC_ENV_PASSWORD and upload it as ai/sync.env.enc
publish      — encrypt this script with PUBLISH_PASSWORD (or SYNC_PASSWORD) and upload as ai/Bvaigen.sh.enc

run '$PROG <command> --help' for options.
EOF
}

main() {
  need
  load_sync_env
  case "${1:-}" in
    chats) shift; cmd_chats "$@" ;;
    telegram|tg) shift; cmd_telegram "$@" ;;
    sync|push) shift; cmd_sync "$@" ;;
    secrets|bootstrap) shift; action=${1:-pull}; [ $# -gt 0 ] && shift; cmd_secrets "$action" "$@" ;;
    publish|code) shift; cmd_publish "$@" ;;
    encrypt) shift; cmd_encrypt "$@" ;;
    decrypt) shift; cmd_decrypt "$@" ;;
    -h|--help|help) usage ;;
    "") cmd_chats ;;
    *) cmd_chats "$@" ;;
  esac
}

main "$@"
