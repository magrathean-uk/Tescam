#!/usr/bin/env zsh
emulate -L zsh
set -u
setopt PIPE_FAIL NONOMATCH
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

progress_event(){
  print -u2 "TESCAM_PROGRESS|$*"
}

usage(){
  cat <<'USAGE' >&2
Usage:
  PRESET={HEVC_CPU_MAX|HEVC_MAX|X265_LOSSLESS|DNXHR_HQ|PRORES_HQ} WORKDIR=<dir> \
    ./tescam_6up_all_max.sh INPUT_DIR [OUTPUT_FILE]

Arguments:
  INPUT_DIR     Directory containing Tescam minute files (.mp4/.mov).
  OUTPUT_FILE   Optional output name (default: cctv_6up_all.mp4). The final
                extension is chosen by PRESET.

Options:
  -h, --help    Show this help and exit.

Environment:
  PRESET        Output codec preset (default: HEVC_CPU_MAX)
  X265_PRESET   HEVC_CPU_MAX x265 preset (default: fast)
  X265_CRF      HEVC_CPU_MAX CRF quality (default: 6)
  VT_Q          HEVC_MAX quality (lower is higher quality, default: 16)
  GOP           HEVC_MAX GOP length (default: 36)
  NO_UPSCALE    Keep per-camera pixels 1:1 and pad to tile (default: 1)
  FFLOGLEVEL    ffmpeg log level (default: info)
  LIMIT_SETS    Process only the first N 6-cam sets (default: 0 = all)
  WORKDIR       Directory to reuse intermediate parts (default: temporary)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -* )
      print -u2 "Unknown option: $1"
      usage
      exit 64
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -ge 1 ]] || { print -u2 "ERROR: INPUT_DIR is required."; usage; exit 64; }
[[ $# -le 2 ]] || { print -u2 "ERROR: Too many arguments."; usage; exit 64; }

INDIR="${1:-}"
OUT="${2:-cctv_6up_all.mp4}"
PRESET="${PRESET:-HEVC_CPU_MAX}"
WORKDIR="${WORKDIR:-}"
NO_UPSCALE="${NO_UPSCALE:-1}"
FFLOGLEVEL="${FFLOGLEVEL:-info}"
LIMIT_SETS="${LIMIT_SETS:-0}"
OVERLAY_DIR="${OVERLAY_DIR:-}"

validate_input_dir(){
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    print -u2 "ERROR: INPUT_DIR must be an existing directory: $dir"
    exit 1
  fi
  if ! find "$dir" -type f \( -iname '*.mp4' -o -iname '*.mov' \) -print -quit | grep -q .; then
    print -u2 "ERROR: INPUT_DIR contains no .mp4 or .mov files: $dir"
    exit 2
  fi
}

validate_output_path(){
  local path="$1" dir
  dir="${path:h}"
  if [[ ! -d "$dir" ]]; then
    if ! /bin/mkdir -p "$dir"; then
      print -u2 "ERROR: Failed to create output directory: $dir"
      exit 3
    fi
  fi
  if [[ ! -w "$dir" ]]; then
    print -u2 "ERROR: Output directory is not writable: $dir"
    exit 3
  fi
}

validate_input_dir "$INDIR"

FFMPEG_BIN="${FFMPEG:-ffmpeg}"
FFPROBE_BIN="${FFPROBE:-ffprobe}"

req_bin() {
  local name="$1" bin="$2"
  if [[ -n "$bin" && "$bin" != "$name" ]]; then
    [[ -x "$bin" ]] || { print -u2 "$name not executable: $bin"; exit 1; }
  else
    command -v "$name" >/dev/null || { print -u2 "$name required"; exit 1; }
  fi
}

req() { command -v "$1" >/dev/null || { print -u2 "$1 required"; exit 1; }; }
req_bin ffmpeg "$FFMPEG_BIN"
req_bin ffprobe "$FFPROBE_BIN"
req awk; req sed; req sort
[[ "$FFMPEG_BIN" == "ffmpeg" ]] && FFMPEG_BIN="$(command -v ffmpeg)"
[[ "$FFPROBE_BIN" == "ffprobe" ]] && FFPROBE_BIN="$(command -v ffprobe)"

ffmpeg() { "$FFMPEG_BIN" "$@"; }
ffprobe() { "$FFPROBE_BIN" "$@"; }

print -u2 "Scanning: $INDIR"
IDX="$(mktemp -t tesla_idx)"
JOBS="$(mktemp -t tesla_jobs)"
cleanup_tmp(){ rm -f "$IDX" "$JOBS"; }
trap cleanup_tmp EXIT

: > "$IDX"
LC_ALL=C find "$INDIR" -type f \( -iname '*.mp4' -o -iname '*.mov' \) -print \
| LC_ALL=C sort \
| while IFS= read -r f; do
  bn="${f##*/}"; core="${bn%.*}"
  if [[ "$core" =~ '^([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})-(front|back|rear|left[_-]repeater|right[_-]repeater|left[_-]pillar|right[_-]pillar)$' ]]; then
    ts="${match[1]}"; cam="${match[2]}"
    cam="${cam//-/_}"
    [[ "$cam" == "rear" ]] && cam="back"
    case "$cam" in
      front|back|left_repeater|right_repeater|left_pillar|right_pillar) printf '%s|%s|%s\n' "$ts" "$cam" "$f" >> "$IDX" ;;
    esac
  fi
done

awk -F'|' '{M[$1]=1; P[$1 "," $2]=$3}
  END{for(ts in M) print ts "|" P[ts ",front"] "|" P[ts ",back"] "|" P[ts ",left_repeater"] "|" P[ts ",right_repeater"] "|" P[ts ",left_pillar"] "|" P[ts ",right_pillar"]}' \
  "$IDX" | LC_ALL=C sort > "$JOBS"

TOTAL=$(wc -l < "$JOBS" | tr -d ' ')
(( TOTAL > 0 )) || { print -u2 "No timestamps."; exit 2; }
(( LIMIT_SETS > 0 )) && { head -n "$LIMIT_SETS" "$JOBS" > "$JOBS.tmp" && mv "$JOBS.tmp" "$JOBS"; TOTAL=$(wc -l < "$JOBS" | tr -d ' '); }
print -u2 "6-cam sets: $TOTAL"
progress_event "TOTAL|$TOTAL"
MISSING_RIGHT=$(awk -F'|' '$5==""{c++} END{print c+0}' "$JOBS")
(( MISSING_RIGHT > 0 )) && print -u2 "WARN: right_repeater missing for $MISSING_RIGHT timestamps; black placeholder will be used."

first_real="$(awk -F'|' '{for(i=2;i<=7;i++) if($i!=""){print $i; exit}}' "$JOBS")"

typeset -a CAM_ORDER
typeset -A CAM_LABEL CAM_FILTER CAM_COLOR
CAM_ORDER=(front back left_repeater right_repeater left_pillar right_pillar)
CAM_LABEL=([front]=v1 [back]=v2 [left_repeater]=v3 [right_repeater]=v4 [left_pillar]=v5 [right_pillar]=v6)

get_dims(){
  local clip="$1" dims w h
  [[ -z "$clip" || ! -f "$clip" ]] && return
  dims="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$clip" 2>/dev/null || true)"
  [[ "$dims" == *,* ]] || return
  w="${dims%%,*}"; h="${dims#*,}"
  printf '%s %s' "$w" "$h"
}

detect_tile(){
  local line ts f b l r lp rp w h maxw=0 maxh=0
  line="$(head -n 1 "$JOBS")"
  IFS='|' read -r ts f b l r lp rp <<< "$line"
  for c in "$f" "$b" "$l" "$r" "$lp" "$rp"; do
    read -r w h <<<"$(get_dims "$c")"
    [[ -n "${w:-}" && -n "${h:-}" ]] || continue
    (( w > maxw )) && maxw="$w"
    (( h > maxh )) && maxh="$h"
  done
  if (( maxw == 0 || maxh == 0 )); then
    read -r w h <<<"$(get_dims "$first_real")"
    maxw="${w:-1280}"
    maxh="${h:-960}"
  fi
  TILE_W="$maxw"
  TILE_H="$maxh"
}

typeset TILE_W TILE_H FILTER_COMPLEX
detect_tile
for C in "${CAM_ORDER[@]}"; do
  if [[ "$NO_UPSCALE" == "1" ]]; then
    CAM_FILTER[$C]="setsar=1,scale=${TILE_W}:${TILE_H}:flags=lanczos:force_original_aspect_ratio=decrease,pad=${TILE_W}:${TILE_H}:(ow-iw)/2:(oh-ih)/2:black"
  else
    CAM_FILTER[$C]="setsar=1,scale=${TILE_W}:${TILE_H}:flags=lanczos"
  fi
  CAM_COLOR[$C]="${TILE_W}x${TILE_H}"
done
print -u2 "Tile size: ${TILE_W}x${TILE_H}"

typeset -a FILTER_STEPS
integer idx in_idx
for idx in {1..6}; do
  CAM="${CAM_ORDER[idx]}"
  LABEL="${CAM_LABEL[$CAM]}"
  FILTER="${CAM_FILTER[$CAM]}"
  (( in_idx = idx - 1 ))
  FILTER_STEPS+=("[${in_idx}:v]${FILTER}[${LABEL}]")
done
FILTER_COMPLEX="${(j:;:)FILTER_STEPS};[${CAM_LABEL[front]}][${CAM_LABEL[back]}][${CAM_LABEL[left_repeater]}][${CAM_LABEL[right_repeater]}][${CAM_LABEL[left_pillar]}][${CAM_LABEL[right_pillar]}]xstack=inputs=6:layout=0_0|w0_0|2*w0_0|0_h0|w0_h0|2*w0_h0,setsar=1[v]"

overlay_filter_complex(){
  local ts="$1"
  local overlay="$OVERLAY_DIR/${ts}.ass"
  if [[ -n "$OVERLAY_DIR" && -f "$overlay" ]]; then
    print -- "${FILTER_COMPLEX};[v]subtitles='${overlay}':force_style='FontName=Menlo,Fontsize=40,Alignment=8,MarginV=48,Outline=3,Shadow=0'[vout]"
  else
    print -- "$FILTER_COMPLEX"
  fi
}

FPS_R="$(ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate -of csv=p=0 "$first_real" || true)"
FPS="$(awk -v r="$FPS_R" 'BEGIN{n=split(r,a,"/"); if(n==2&&a[2]>0){printf("%.3f",a[1]/a[2]);} else if(r+0>0){printf("%.3f",r);} else{printf("36.027");}}')"
print -u2 "Using FPS=$FPS"

typeset -a VENC MOV
typeset EXT
case "$PRESET" in
  HEVC_CPU_MAX)
    X265_PRESET="${X265_PRESET:-fast}"
    X265_CRF="${X265_CRF:-6}"
    VENC=(-c:v libx265 -preset "$X265_PRESET" -crf "$X265_CRF" -tag:v hvc1 -pix_fmt yuv420p -threads 0)
    MOV=(-movflags +faststart); EXT="mp4" ;;
  HEVC_MAX)
    VT_Q="${VT_Q:-16}"; GOP="${GOP:-36}"
    VENC=(-c:v hevc_videotoolbox -tag:v hvc1 -pix_fmt yuv420p -q:v "$VT_Q" -allow_sw 1 -g "$GOP" -bf 0)
    MOV=(-movflags +faststart); EXT="mp4" ;;
  X265_LOSSLESS)
    VENC=(-c:v libx265 -x265-params lossless=1 -tag:v hvc1 -pix_fmt yuv420p -threads 0)
    MOV=(-movflags +faststart); EXT="mp4" ;;
  DNXHR_HQ)
    VENC=(-c:v dnxhd -profile:v dnxhr_hq -pix_fmt yuv422p)
    MOV=(-movflags +faststart); EXT="mov" ;;
  PRORES_HQ)
    VENC=(-c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le)
    MOV=(-movflags +faststart); EXT="mov" ;;
  *)
    print -u2 "Unknown PRESET: $PRESET"; exit 3 ;;
esac
OUTDIR="$(dirname "$OUT")"; OUTBASE="$(basename "$OUT")"; OUT="${OUTDIR%/}/${OUTBASE%.*}.${EXT}"
validate_output_path "$OUT"

if [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(mktemp -d -t tescam_6up)"
  WORKDIR_EPHEMERAL=1
else
  /bin/mkdir -p "$WORKDIR"
  WORKDIR_EPHEMERAL=0
fi
PARTS="$WORKDIR/parts"
INPUT="$WORKDIR/input"
FINAL="$WORKDIR/final"
/bin/mkdir -p "$PARTS" "$INPUT" "$FINAL"
print -u2 "WORKDIR: $WORKDIR"
progress_event "WORKDIR|$WORKDIR"

append_concat="$WORKDIR/concat.txt"
: > "$append_concat"
progress_event "OUTPUT|$OUT"

build_one(){
  local ts="$1" front="$2" back="$3" left="$4" right="$5" lp="$6" rp="$7"
  local i=0 inputs=()
  if [[ -n "$front" ]]; then ln -f "$front" "$INPUT/${ts}-front.${front##*.}" 2>/dev/null || cp "$front" "$INPUT/${ts}-front.${front##*.}"; inputs+=("-i" "$INPUT/${ts}-front.${front##*.}"); ((i++)); else inputs+=("-f" "lavfi" "-i" "color=c=black:s=${CAM_COLOR[front]}:r=$FPS"); fi
  if [[ -n "$back" ]]; then ln -f "$back" "$INPUT/${ts}-back.${back##*.}" 2>/dev/null || cp "$back" "$INPUT/${ts}-back.${back##*.}"; inputs+=("-i" "$INPUT/${ts}-back.${back##*.}"); ((i++)); else inputs+=("-f" "lavfi" "-i" "color=c=black:s=${CAM_COLOR[back]}:r=$FPS"); fi
  if [[ -n "$left" ]]; then ln -f "$left" "$INPUT/${ts}-left.${left##*.}" 2>/dev/null || cp "$left" "$INPUT/${ts}-left.${left##*.}"; inputs+=("-i" "$INPUT/${ts}-left.${left##*.}"); ((i++)); else inputs+=("-f" "lavfi" "-i" "color=c=black:s=${CAM_COLOR[left_repeater]}:r=$FPS"); fi
  if [[ -n "$right" ]]; then ln -f "$right" "$INPUT/${ts}-right.${right##*.}" 2>/dev/null || cp "$right" "$INPUT/${ts}-right.${right##*.}"; inputs+=("-i" "$INPUT/${ts}-right.${right##*.}"); ((i++)); else inputs+=("-f" "lavfi" "-i" "color=c=black:s=${CAM_COLOR[right_repeater]}:r=$FPS"); fi
  if [[ -n "$lp" ]]; then ln -f "$lp" "$INPUT/${ts}-lp.${lp##*.}" 2>/dev/null || cp "$lp" "$INPUT/${ts}-lp.${lp##*.}"; inputs+=("-i" "$INPUT/${ts}-lp.${lp##*.}"); ((i++)); else inputs+=("-f" "lavfi" "-i" "color=c=black:s=${CAM_COLOR[left_pillar]}:r=$FPS"); fi
  if [[ -n "$rp" ]]; then ln -f "$rp" "$INPUT/${ts}-rp.${rp##*.}" 2>/dev/null || cp "$rp" "$INPUT/${ts}-rp.${rp##*.}"; inputs+=("-i" "$INPUT/${ts}-rp.${rp##*.}"); ((i++)); else inputs+=("-f" "lavfi" "-i" "color=c=black:s=${CAM_COLOR[right_pillar]}:r=$FPS"); fi

  local out="$PARTS/${ts}.${EXT}"
  local part_filter
  local map_label="[v]"
  part_filter="$(overlay_filter_complex "$ts")"
  [[ "$part_filter" == *"[vout]" ]] && map_label="[vout]"
  ffmpeg -y -loglevel "$FFLOGLEVEL" "${inputs[@]}" \
    -filter_complex "$part_filter" -map "$map_label" "${VENC[@]}" "${MOV[@]}" "$out" \
    || { print -u2 "Failed part: $ts"; return 1; }
  printf "file '%s'\n" "$out" >> "$append_concat"
}

print -u2 "Processing parts..."
integer idx=0
while IFS='|' read -r ts f b l r lp rp; do
  (( idx++ ))
  print -u2 "[$idx/$TOTAL] $ts"
  progress_event "RENDER_START|$idx|$TOTAL|$ts|${ts}.${EXT}"
  build_one "$ts" "$f" "$b" "$l" "$r" "$lp" "$rp" || { progress_event "RENDER_FAIL|$idx|$TOTAL|$ts|${ts}.${EXT}"; exit 4; }
  progress_event "RENDER_OK|$idx|$TOTAL|$ts|${ts}.${EXT}"
done < "$JOBS"

print -u2 "Concatenating..."
progress_event "CONCAT_START|$OUT"
ffmpeg -y -loglevel "$FFLOGLEVEL" -f concat -safe 0 -i "$append_concat" -c copy "$FINAL/out.${EXT}" \
  || { progress_event "CONCAT_FAIL|$OUT"; print -u2 "Concat failed"; exit 5; }

/bin/mv -f "$FINAL/out.${EXT}" "$OUT"
progress_event "CONCAT_OK|$OUT"
progress_event "DONE|$OUT"
print -u2 "Done: $OUT"

if (( WORKDIR_EPHEMERAL == 1 )); then
  /bin/rm -rf "$WORKDIR"
fi
