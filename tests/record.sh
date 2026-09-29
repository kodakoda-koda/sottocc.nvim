#!/bin/sh
# Record tests/fixtures/<name>.ndjson from the real CLI.
#
#   tests/record.sh tools|agent|edit|permission
#
# Each run starts from the same files in /tmp/sotrec, so the paths in the
# recording are stable. The model's wording still varies from run to run:
# after recording, run `make update` and read the diff.
set -eu

name=${1:?usage: tests/record.sh tools|agent|edit|permission}
root=$(cd "$(dirname "$0")/.." && pwd)
work=/tmp/sotrec
out="$root/tests/fixtures/$name.ndjson"

rm -rf "$work"
mkdir -p "$work"
printf 'alpha\nbravo\ncharlie\n' >"$work/notes.txt"
printf 'print("hi")\n' >"$work/main.lua"
cd "$work"

edit_prompt='notes.txt を Read で読み、Edit ツールで alpha を ALPHA に書き換えて。ほかのツールは使わないで。'
case $name in
tools)
  prompt='notes.txt と missing.txt を Read ツールで読み、Bash で `ls` を実行して。最後に、読んだ行を「行番号 | 内容」の Markdown 表にし、main.lua の中身を lua のコードブロックで示して。'
  set -- --allowedTools "Read Bash(ls)"
  ;;
agent)
  prompt='Agent ツールでサブエージェントを1つ起動し、Bash で `ls` を実行させて結果を報告させて。あなた自身はツールを使わないで。'
  set -- --allowedTools "Agent Bash(ls)"
  ;;
edit)
  prompt=$edit_prompt
  set -- --permission-mode acceptEdits
  ;;
permission)
  prompt=$edit_prompt
  set -- --permission-prompt-tool stdio
  ;;
*)
  echo "unknown fixture: $name" >&2
  exit 1
  ;;
esac

json=$(jq -cn --arg t "$prompt" '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}')
raw="$work/raw.ndjson"
cli() {
  claude -p --input-format stream-json --output-format stream-json --verbose \
    --include-partial-messages --replay-user-messages --model haiku "$@"
}

if [ "$name" = permission ]; then
  # The CLI stops to wait for the answer, so keep stdin open and stop it once
  # the request is out.
  (
    printf '%s\n' "$json"
    sleep 45
  ) | cli "$@" >"$raw" 2>/dev/null &
  pid=$!
  i=0
  while [ $i -lt 40 ] && ! grep -q '"control_request"' "$raw" 2>/dev/null; do
    sleep 1
    i=$((i + 1))
  done
  sleep 1
  pkill -P $pid 2>/dev/null || true
  kill $pid 2>/dev/null || true
else
  printf '%s\n' "$json" | cli "$@" >"$raw" 2>/dev/null
fi

# Drop the partial events nothing draws, and what describes this machine
# rather than the conversation.
jq -c '
  select((.type=="stream_event" and .event.type!="content_block_start") or (.type=="system" and .subtype=="thinking_tokens") | not)
  | if .type=="system" and .subtype=="init" then {type,subtype,cwd,session_id,model,permissionMode,claude_code_version,output_style,uuid,slash_commands:["compact","context","review"],mcp_servers:[],tools:[]} else . end
  | if .message.content then .message.content |= map(if .type=="thinking" then .thinking="" | .signature="" else . end) else . end
' "$raw" | sed -e "s/$(whoami)/user/g" >"$out"
echo "wrote $out ($(wc -l <"$out" | tr -d ' ') lines)"
