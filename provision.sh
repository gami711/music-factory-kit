#!/bin/bash
# ACE-Step 1.5 + ComfyUI プロビジョニング v3（新Pod作成のたびに1回実行）
set -uo pipefail

# ComfyUI 内のディレクトリ $1 を、Volume 上のディレクトリ $2 へのシンボリックリンクにする。
# clone 直後の ComfyUI は models/* や output/ にプレースホルダのファイルが入っていて rmdir できないため、
# 中身を Volume 側へ移してから置き換える（同名ファイルは上書きせず、残った分は *.local-backup-* に退避）。
# 何度実行しても同じ結果になる。リンクにできなければ失敗を返す。
link_to_volume() {
  local src=$1 dst=$2 l
  mkdir -p "$dst" || return 1
  if [ -L "$src" ]; then
    rm -f "$src"
  elif [ -d "$src" ]; then
    find "$src" -mindepth 1 -maxdepth 1 -type f \( -name 'put_*_here' -o -name '_output_images_will_be_put_here' \) -delete
    # v2 までの不具合で中に作られた「Volume へのリンク」は移さずに消す（Volume 側で自己参照になるため）
    while IFS= read -r -d '' l; do
      [ "$(readlink -f "$l")" = "$(readlink -f "$dst")" ] && rm -f "$l"
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type l -print0)
    while IFS= read -r -d '' l; do
      if [ -e "$dst/${l##*/}" ] || [ -L "$dst/${l##*/}" ]; then continue; fi  # 同名は上書きせず残す
      mv "$l" "$dst"/ || return 1  # Volume が満杯・読み取り専用などで移せなければ、置き換えずに中断
    done < <(find "$src" -mindepth 1 -maxdepth 1 -print0)
    rmdir "$src" 2>/dev/null || mv "$src" "$src.local-backup-$(date +%Y%m%d%H%M%S)" || return 1
  elif [ -e "$src" ]; then
    mv "$src" "$src.local-backup-$(date +%Y%m%d%H%M%S)" || return 1
  fi
  ln -s "$dst" "$src" && [ "$(readlink -f "$src")" = "$(readlink -f "$dst")" ]
}

# モデル $1 を Volume 上の $2/$1 に用意する。既に配布元と同じサイズなら何もしない。
# Volume へ直接ダウンロードすると小さな書き込みの連続で極端に遅い（10GB で約40分）ため、
# Pod ローカルの /root に落としてから Volume へまとめてコピーする（約50秒）。
HF_BASE=https://huggingface.co/Comfy-Org/ace_step_1.5_ComfyUI_files/resolve/main
fetch_model() {
  local name=$1 dir=$2 url=$3 size have
  size=$(curl -sIL "$url" | tr -d '\r' | awk 'tolower($1)=="content-length:"{v=$2} END{print v}')
  have=$(stat -c %s "$dir/$name" 2>/dev/null || echo 0)
  if [ -n "$size" ] && [ "$have" = "$size" ]; then echo "MODEL OK: $name"; return 0; fi
  mkdir -p "$dir" || return 1
  echo "MODEL DOWNLOAD: $name"
  curl -sfL -o "/root/$name.part" "$url" || { rm -f "/root/$name.part"; return 1; }
  cp "/root/$name.part" "$dir/.$name.tmp" && mv "$dir/.$name.tmp" "$dir/$name" && rm -f "/root/$name.part"
}

[ -d /root/ComfyUI ] || git clone --depth 1 -q https://github.com/comfyanonymous/ComfyUI.git /root/ComfyUI
cd /root/ComfyUI || { echo "COMFY FAILED: /root/ComfyUI がありません"; exit 1; }
for d in diffusion_models vae text_encoders loras checkpoints; do
  link_to_volume models/$d /workspace/models/$d || { echo "LINK FAILED: models/$d"; exit 1; }
done
link_to_volume output /workspace/outputs || { echo "LINK FAILED: output（生成物がPodローカルに保存されるため中断）"; exit 1; }
pip install --break-system-packages --no-cache-dir -q -r requirements.txt numpy 2>&1 | tail -1

# モデル（初回のみダウンロード。2回目以降はサイズ確認だけで数秒）
fetch_model ace_step_1.5_turbo_aio.safetensors /workspace/models/checkpoints "$HF_BASE/checkpoints/ace_step_1.5_turbo_aio.safetensors" \
  || { echo "MODEL FAILED: ace_step_1.5_turbo_aio"; exit 1; }
# 高音質版 XL-SFT も使う場合: ACESTEP_XL=1 bash /workspace/provision.sh
if [ "${ACESTEP_XL:-0}" = "1" ]; then
  fetch_model acestep_v1.5_xl_sft_bf16.safetensors /workspace/models/diffusion_models "$HF_BASE/split_files/diffusion_models/acestep_v1.5_xl_sft_bf16.safetensors" \
    && fetch_model qwen_0.6b_ace15.safetensors /workspace/models/text_encoders "$HF_BASE/split_files/text_encoders/qwen_0.6b_ace15.safetensors" \
    && fetch_model qwen_1.7b_ace15.safetensors /workspace/models/text_encoders "$HF_BASE/split_files/text_encoders/qwen_1.7b_ace15.safetensors" \
    && fetch_model ace_1.5_vae.safetensors /workspace/models/vae "$HF_BASE/split_files/vae/ace_1.5_vae.safetensors" \
    || { echo "MODEL FAILED: XL-SFT"; exit 1; }
fi

# FL LoRA training node（comfy起動より前に入れる）
if [ ! -d /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training ]; then
  git clone --depth 1 -q https://github.com/filliptm/ComfyUI-FL-AceStep-Training.git /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training
  pip install --break-system-packages --no-cache-dir -q -r /root/ComfyUI/custom_nodes/ComfyUI-FL-AceStep-Training/requirements.txt 2>&1 | tail -1
fi

# ComfyUI は CORS 無効時、Sec-Fetch-Site: cross-site のリクエストを 403 で拒否する。
# RunPod 管理画面のリンクから https://<pod-id>-8188.proxy.runpod.net を開くと cross-site 扱いになるため、
# --enable-cors-header でこのチェックを外す（他サイトからの POST も通るようになるが、プロキシURLはもともと
# 認証なしで公開されており、URL を知っていれば直接操作できるので守れる範囲は変わらない）。
# 指定したオリジン以外のサイトにはレスポンスを読ませないよう、自分のプロキシURLを指定する（Pod ID が取れなければ *）。
CORS_ORIGIN="*"
[ -n "${RUNPOD_POD_ID:-}" ] && CORS_ORIGIN="https://${RUNPOD_POD_ID}-8188.proxy.runpod.net"

OLD=$(pgrep -f "main.py --listen" | head -1); [ -n "${OLD:-}" ] && kill -9 "$OLD"; sleep 2
cd /root/ComfyUI && setsid nohup python main.py --listen 0.0.0.0 --port 8188 \
  --enable-cors-header "$CORS_ORIGIN" --output-directory /workspace/outputs \
  </dev/null >/root/comfy.log 2>&1 & disown
for i in $(seq 1 60); do
  sleep 5
  curl -s -m 4 http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && { echo "COMFY READY ($((i*5))s)"; exit 0; }
done
echo "COMFY FAILED"; tail -20 /root/comfy.log; exit 1
