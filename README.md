# Music Factory Kit — RunPod × ACE-Step 1.5

RunPod の GPU で、音楽生成AI「ACE-Step 1.5」を動かすための道具一式です。

| ファイル | 用途 |
|---|---|
| `provision.sh` | Pod を作るたびに1回実行。ComfyUI の準備・**モデルの自動ダウンロード**・起動までを行う |
| `master.sh` | マスタリング（EQ + コンプ + -14 LUFS 正規化） |
| `check_fingerprint.py` | 配信前の音響指紋チェック（似すぎていないかの自己検品） |
| `workflows/acestep_turbo_instrumental.json` | ComfyUI の API で使う、インスト曲生成のワークフロー例 |

## 使い方

### provision.sh
RunPod の Pod（`runpod/pytorch` の CUDA 12.8 以上のイメージ + Network Volume を `/workspace` にマウント）で:

```bash
curl -sL https://raw.githubusercontent.com/gami711/music-factory-kit/main/provision.sh -o /workspace/provision.sh
bash /workspace/provision.sh
```

- 初回はモデル `ace_step_1.5_turbo_aio.safetensors`（約10GB）を自動でダウンロードします（約1〜2分）
- 2回目以降はモデルが Volume に残っているので、サイズの確認だけで約1分で起動します
- 完了すると `COMFY READY` と表示され、Pod の 8188 番ポートで ComfyUI が開きます
- 高音質版の XL-SFT も使う場合は `ACESTEP_XL=1 bash /workspace/provision.sh`（追加で約14GB）

生成物は `/workspace/outputs`（Volume）に保存されます。`/root/ComfyUI/output` はそこへのリンクです。

### master.sh
```bash
bash master.sh input.mp3 output.mp3
```
ffmpeg が必要です（macOS: `brew install ffmpeg`）。

### check_fingerprint.py
```bash
# 要: fpcalc（macOS: brew install chromaprint / Ubuntu: apt install libchromaprint-tools）
python3 check_fingerprint.py 生成物フォルダ/ 比較したい音源フォルダ/
```
一致率 0.65 超の曲は配信しない。0.85 超は Content ID 一致水準（絶対NG）。

## 前提となる考え方

- **モデルは Volume、プログラムは Pod ローカル**：Volume は小さなファイルの書き込みが極端に遅いため
- **モデルは Pod ローカルに落としてから Volume へコピー**：Volume へ直接ダウンロードすると約40分、この方法なら約50秒
- **曲の長さは3分半〜3分45秒くらい**：長くしすぎると、途中で音が途切れることがある
- **Pod は使い捨て**：作業が終わったら「停止」ではなく「削除」する

## クレジットとライセンス

MIT。[Shudesu/music-factory-kit](https://github.com/Shudesu/music-factory-kit)（MIT）をもとに、モデルの自動ダウンロードとワークフロー例を追加したものです。
ACE-Step 1.5 本体も MIT（商用利用可）。
モデル配布元: https://huggingface.co/Comfy-Org/ace_step_1.5_ComfyUI_files
