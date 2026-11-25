# Sirius AXPY 実験ログ

## 2026-11-20 最小フィードバックループ

- 実施日時: 2026-11-20 19:41:05 JST (+0900)
- GitHub リポジトリ: `ohara803/amd-genaspen`
- Git commit: `963c89d42cdc984e125d589bf25979e07454c75e`
- Sirius ジョブID: `50707.pbs`
- キュー: `debug`
- アカウント: `CSPP`
- リソース: `select=1`
- walltime 上限: `00:10:00`
- ROCm module: `rocm/7.2.0`
- 実行条件: `N=67108864`、`iterations=1000`

### 実装

- `axpy.hip.cpp` を追加し、HIPで倍精度AXPYを実装
- 反復ごとの同期を避け、連続してカーネルを投入してHIPイベントで総時間を測定
- AMD SMIの `amdsmi_get_power_info()` を使い、カーネル実行中の電力を `power.csv` に記録
- 先頭要素と末尾要素を期待値と比較し、計算結果を検証
- 計算検証または電力サンプル取得に失敗した場合は非0終了する設計
- 既存の `axpy.cu` は変更なし

### 投入と状態確認

投入コマンド:

```bash
ssh sirius-agent \
  'qsub -N axpy-agent-test -A CSPP -q debug -l select=1 -l walltime=00:10:00 -j oe' \
  < job/payload-sirius.sh
```

- `qsub`: 成功。ジョブID `50707.pbs` を取得
- 投入後の `qstat`: 終了コード0、出力なし（確認時点でキューから退出済み）
- `ls 50707.pbs`: 成功
- 成果物 `summary/commit.txt`: 41 bytes
- 成果物 `summary/power.csv`: 269 bytes
- `tail 50707.pbs -n 100`: 成功したが、計算stdoutではなく `sandbox` 補助スクリプトを表示

### 成否判定

- HIPコンパイル: 成功
- AXPY実行: 成功
- 結果検証: 成功
- AMD SMI電力測定: 成功
- 新規ジョブ投入数: 1
- 再投入: なし

ジョブスクリプトは `set -euo pipefail` を使用し、HIPコンパイルまたは実行が失敗すると成果物コピー前に終了する。`summary/power.csv` と `summary/commit.txt` が生成され、`power.csv` が非空であることから、コンパイル、AXPY実行、結果検証、1件以上の電力サンプル取得は正常終了したと判定した。

### 確認できなかった項目

制限付きSSHの `tail` が計算stdoutではなく補助スクリプトを返したため、カーネル時間、実効帯域、GFLOP/s、平均電力の数値は確認できなかった。未確認の性能数値は成功結果として報告しない。

## 2026-11-20 改良版 `axpy.hip`

- 実施日時: 2026-11-20 23:50:39 JST (+0900)
- テスト対象Git commit: `33b9cadf77d5fe574c17cd55055e2889174cead5`
- 変更内容: `axpy.hip.cpp` を改良版 `axpy.hip` に置換し、ジョブスクリプトのコンパイル対象を更新
- ジョブスクリプト: 実行ログを `000-run.log` に保存し、電力CSVに有効なサンプルがなければ失敗するよう検証を追加
- `axpy.cu`: 変更なし

### 投入結果

- `qsub` 呼び出し: 失敗
- SSHエラー: `Permission denied (keyboard-interactive)`
- ジョブID: 発行なし
- 新規ジョブ投入数: 0
- SSH認証失敗後の再試行: なし

### 成否判定

- GitHubへのコード反映: 成功
- SiriusでのHIPコンパイル: 未実施・未確認
- SiriusでのAXPY実行: 未実施・未確認
- 電力・温度測定: 未実施・未確認

SSH認証が復旧するまで、改良版のコンパイルおよび実行結果を成功とは判定しない。

## 2026-11-21 改良版 `axpy.hip` 再実行

- 実施日時: 2026-11-21 00:00:08 JST (+0900)
- GitHub `main`: `a581eecc7a9b68e9875dc22d59f0b2c47ea6aff6`
- 改良版コードcommit: `33b9cadf77d5fe574c17cd55055e2889174cead5`
- SiriusジョブID: `50716.pbs`
- walltime上限: `00:10:00`
- 実行条件: `N=67108864`、`iterations=1000`

### 状態と成果物

- `qsub`: 成功
- 最初の `qstat`: 状態 `R`
- 20秒後の最終 `qstat`: 出力なし（キューから退出済み）
- `summary/commit.txt`: 41 bytes
- `summary/power.csv`: 231 bytes
- `tail 50716.pbs -n 100`: 計算stdoutではなく `sandbox` 補助スクリプトを表示

### 成否判定

- HIPコンパイル: 成功
- AXPY実行: 成功
- AMD SMI電力測定: 成功
- 新規ジョブ投入数: 1
- 追加投入: なし

ジョブスクリプトは `set -euo pipefail` を使用し、コンパイル、実行、1件以上の電力行、有効な電力値のいずれかの検証に失敗すると成果物コピー前に終了する。`summary/power.csv` と `summary/commit.txt` が生成されたため、これらの処理は正常終了したと判定した。

### 確認できなかった項目

制限付きSSHでは成果物の内容を直接表示できなかったため、カーネル時間、GFLOP/s、平均電力、温度の具体値は未確認。温度取得はプログラム上 `nan` を許容するため、温度測定の成功は判定していない。

## 2026-11-21 ジョブ番号付きログ版の投入試行

- 実施日時: 2026-11-21 00:27:55 JST (+0900)
- GitHub `main`: `fa46fd3db6e2ba875a0365aedc30e3f07261c075`
- 予定ログ名: `summary/run_<ジョブ番号>.log`
- `qsub` 呼び出し: 失敗
- SSHエラー: `mux_client_request_session: read from master failed: Broken pipe`、続いて `Permission denied (keyboard-interactive)`
- ジョブID: 発行なし
- 新規ジョブ投入数: 0
- SSH認証失敗後の再試行: なし

ジョブが作成されなかったため、コンパイル、実行、実行時間、GFLOP/s、電力、温度はいずれも未実施・未確認。

## 2026-11-21 `axpy.hip` 実行結果の再取得

- 実施日時: 2026-11-21 00:53:11 JST (+0900)
- GitHub `main` / ジョブ実行commit: `eb9ef02661735d93d3e132ecb2fea96f88a8d437`
- SiriusジョブID: `50726.pbs`
- walltime上限: `00:10:00`
- ROCm / HIP: `7.2.0` / `7.2.26015-fc0010cf6a`
- 実行条件: `N=67108864`、`iterations=1000`

### 状態と成果物

- `qsub`: 成功
- 最初の `qstat`: 状態 `R`
- 約30秒後の最終 `qstat`: 出力なし（キューから退出済み）
- `ls 50726.pbs`: `summary/run_50726.log`、`summary/power.csv`、`summary/commit.txt` を確認
- `tail 50726.pbs -n 100`: `sandbox` 補助スクリプトを表示
- `scp` により上記3成果物の内容を回収
- 実行ログ末尾: `AGENT_TEST_SUCCESS`

### 実行結果

- HIPコンパイル: 成功
- AXPY実行: 成功
- 問題サイズ: `67108864`
- 反復回数: `1000`
- 総カーネル時間: `0.441831 s`
- 平均カーネル時間: `0.441831 ms`
- 性能: `303.776151 GFLOP/s`（`0.303776 TFLOP/s`）
- 測定対象: HIP GPU 0 / PCI `0002:02:00.0`
- 温度ソース: GPU metrics hotspot
- 電力・温度サンプル数: 9
- 平均電力: `583.889 W`（最小 `137 W`、最大 `749 W`）
- 平均温度: `53.000 C`（全サンプル `53 C`）
- 追加投入: なし

### 成否判定

実行ログに `=== Completed ===` と `AGENT_TEST_SUCCESS` があり、ジョブ内でコンパイル、AXPY実行、1件以上のCSV行、有効な電力値の検証をすべて通過した。回収した `power.csv` には9件の有効な電力値と温度値があり、`commit.txt` は投入対象のcommitと一致した。したがって、`axpy.hip` のHIPコンパイル、MI300A上の実行、性能結果の出力、AMD SMIによる電力・温度測定、および結果回収は成功と判定した。

## 2026-11-21 GitHub経由でSiriusの固定ディレクトリへ配置

### 目的

ローカルで作成した以下のディレクトリをGitHub経由でSiriusの固定ディレクトリへ配置する。

- `hip_kernels`: 単独実行可能なHIPプログラム16本
- `hip_kernels_only`: カーネル関数のみのHIPファイル16本
- 配置先: `/work/CSPP/ohara_803/20261120_amd_genaspen`

### 接続方法の使い分け

`sirius-agent` は通常のログインシェルではなく、PBS操作用の制限付き接続である。確認時点では `qsub`、`qstat`、ジョブ成果物用の `ls` と `tail` は使用できるが、通常の `git` やファイル操作コマンドは拒否された。

PBSジョブ内ではGitHubから `$PBSWRAP_WORK` へcloneできる。ただし、固定ディレクトリ `/work/CSPP/ohara_803/20261120_amd_genaspen` はジョブ内に読み取り専用で公開されるため、`$PBSWRAP_WORK` から固定ディレクトリへ `cp` や `mv` を行うことはできない。

用途ごとの接続方法は次のとおり。

- コンパイル・GPU実行: `sirius-agent` でPBSジョブを投入し、ジョブ内で `$PBSWRAP_WORK` へGitHubをcloneする。
- 固定ディレクトリへの配置: 通常SSH接続を使用し、ログインシェルからGitHubをcloneする。

### 通常SSH接続の確立

MacBook側で次のコマンドを実行し、Verification codeを入力する。

```bash
ssh -M -S /tmp/codex-sirius-login.sock -fN \
  ohara_803@sirius.ccs.tsukuba.ac.jp
```

オプションの意味:

- `-M`: 後続のSSH接続で共有できるマスター接続にする。
- `-S`: 共有接続のソケットパスを指定する。
- `-f`: 認証後に接続をバックグラウンドへ移す。
- `-N`: リモートコマンドを実行せず、接続だけを維持する。

このコマンド自体はファイルを配置しない。認証済み接続を作成し、後続の `ssh -S /tmp/codex-sirius-login.sock ...` で再利用するためのものである。

### 配置手順

1. ローカルで対象ディレクトリだけをcommitし、`origin/main` へpushする。
2. `git ls-remote origin refs/heads/main` でGitHub側のSHAを確認する。
3. 通常SSH接続で配置先の既存内容と同名ディレクトリの有無を確認する。
4. 配置先直下の一時ディレクトリへGitHubをcloneする。
5. cloneしたHEADが期待するSHAと一致し、両ディレクトリにHIPファイルが16本ずつあることを確認する。
6. 同名ディレクトリが存在しないことを確認してから、2ディレクトリだけを配置先へ移動する。
7. 一時cloneディレクトリを削除し、配置先のファイル一覧と件数を再確認する。

今回使用したGitHubコミット:

```text
501eec2b109e95ca36c3626462d1cb0eaf7ea271
```

通常SSH経由の処理例。`EXPECTED_SHA` は配置するコミットに置き換える。

```bash
ssh -S /tmp/codex-sirius-login.sock \
  ohara_803@sirius.ccs.tsukuba.ac.jp '
    set -euo pipefail
    target=/work/CSPP/ohara_803/20261120_amd_genaspen
    staging="$target/.github-sync"
    EXPECTED_SHA=501eec2b109e95ca36c3626462d1cb0eaf7ea271

    test ! -e "$staging"
    test ! -e "$target/hip_kernels"
    test ! -e "$target/hip_kernels_only"

    git clone --quiet --depth 1 --branch main \
      https://github.com/ohara803/amd-genaspen.git "$staging"

    test "$(git -C "$staging" rev-parse HEAD)" = "$EXPECTED_SHA"
    test "$(find "$staging/hip_kernels" -maxdepth 1 -type f -name "*.hip" | wc -l)" -eq 16
    test "$(find "$staging/hip_kernels_only" -maxdepth 1 -type f -name "*.hip" | wc -l)" -eq 16

    mv "$staging/hip_kernels" "$target/"
    mv "$staging/hip_kernels_only" "$target/"
    rm -rf -- "$staging"
  '
```

同名ディレクトリがすでに存在する場合、この例は `test ! -e` で停止する。既存データを暗黙に上書きまたは削除せず、内容を確認してから更新方法を決める。

### 今回の結果

- GitHub `origin/main` へのpush: 成功
- 通常SSH接続: 成功
- 配置元コミットのSHA確認: 成功
- `hip_kernels`: 16ファイル配置済み
- `hip_kernels_only`: 16ファイル配置済み
- 既存の `runs` ディレクトリ: 変更なし
- 一時cloneディレクトリ: 削除済み

### 失敗した試行

ジョブ `50772.pbs` では、PBSジョブから固定ディレクトリへ書き込もうとした。`pbswrap` により固定ディレクトリが読み取り専用で公開されるため、この方式では配置できなかった。この失敗から、固定ディレクトリの更新には通常SSH接続が必要であることを確認した。

## 2026-11-25 MI300A Type0 axpy/copy/dot係数学習・予測評価

### 目的と入力

- 対象: Type0の `axpy`、`copy`、`dot`
- GPU: AMD Instinct MI300A
- ROCm: 7.2.0（HIP 7.2.26015）
- 実行時検出wavefront size: 64 lanes
- 測定元: `measurement/run_all.sh.o50858`
- 学習: 3カーネル×7サイズ = 21点
- target: 3カーネル×3サイズ = 9点
- train/target重複: 0
- 成功ジョブがcloneしたGitHub commit: `a4d8dd0da939ccb7aa54409549bb90c54b84d4f7`

学習にはtrain行だけを使い、target行は係数またはRidge alphaの選択に使用していない。runtimeは既存Type0式`total_bytes / bw`へ相対誤差重み付き原点回帰で有効帯域をfitした。powerは実測runtimeをrate分母とする`warp/s`、`FLOP/s`、`load-byte/s`、`store-byte/s`の4特徴量を標準化し、`1/power_W^2`重み付きRidgeを使用した。alphaはtrain内のleave-one-size-out MAPEで選んだ。

### ジョブ履歴

1. `51384.pbs`: 失敗。PBSWRAPがジョブ内の`/work`を隔離するため、兄弟ディレクトリのGenASPEN、Ollama、測定入力が見えなかった。MI300A/ROCmとwavefront=64の検出後、入力snapshot段階で停止した。成果物と失敗ログはSiriusの`runs/51384.pbs`に保存済み。
2. `51385.pbs`: 成功。プロジェクト配下へ新規`pbswrap_stage_type0_20261125`を作り、GenASPEN、venv site-packages、Ollama、モデルblobをハードリンクで読み取り専用公開した。別mountのPython 112 MBと`uv` 38 MBだけ通常コピーした。ジョブ内ではさらに`$PBSWRAP_WORK`へ作業コピーを作成した。

成功ジョブ後の追加投入は行っていない。ログインノードではコンパイルまたはGPU計算を行っていない。Sirius上のcanonical GenASPENと`amd_mi300a.aspen`は変更していない。

### 学習結果

- 有効帯域: `3399.4782046459172 GB/s`
- runtime train MAPE: `15.220027709479616%`
- runtime leave-one-size-out MAPE: `17.499441099102576%`
- power Ridge alpha: `1e-12`
- power train MAPE: `6.769286284567999%`
- power leave-one-size-out MAPE: `9.049918369465694%`
- power設計行列: 4列、rank 2。axpyとdotが同一静的比率を持つため強い共線性があり、係数の個別解釈はしない。

暫定machine modelへ追加した係数:

```text
param bw = 3399.4782046459172 * giga
param power_warp_size = 64
param power_intercept_0 = -65.957357973521539
param power_warp_0 = 5.124770434364279e-08
param power_flop_0 = 2.6223009997370891e-10
param power_load_0 = 1.9450565509013352e-10
param power_store_0 = 1.0009317363736603e-10
```

### 公式cached-model target評価

保存した9件の`uv run --no-sync kernels/run_kernel_size_energy.py --aspen --reuse -f -l -s -r -p ...`標準出力から算出した。

| group | points | runtime MAPE | power MAPE | energy MAPE |
|---|---:|---:|---:|---:|
| all | 9 | 15.272385% | 11.977122% | 8.335272% |
| axpy | 3 | 11.128804% | 10.787769% | 6.369210% |
| copy | 3 | 23.402993% | 14.563279% | 12.310033% |
| dot | 3 | 11.285358% | 10.580319% | 6.326573% |

- 予測コマンド: 9/9 return code 0
- runtime/power/energy欠損・NaN・Inf・0以下: 0
- Python raw係数とC++ predictorの一致検査: 9/9成功
- 予測前後のstaged application model SHA-256: 3/3不変
- 保存済みmanifest: 65件、ローカル再検証エラー0

### GenASPEN生成のtoken・時間

| kernel | prompt tokens | completion tokens | LLM stage time |
|---|---:|---:|---:|
| axpy | 12,903 | 920 | 83.006521 s |
| copy | 12,892 | 1,026 | 63.108368 s |
| dot | 12,896 | 887 | 38.297640 s |
| total | 38,691 | 2,833 | 184.412528 s |

各カーネルについてJSON IR生成とASPEN生成の2区間を個別保存している。コマンド全体時間、解析各phase時間、生response、thinking、metadataも成果物に含む。

### 生成モデルと`--reuse`の監査

現在のGenASPEN workflowは新規modelを`generation_debug/.../application_model.aspen`へ保存したが、今回の`uv --reuse`が読む作業コピーの`kernels/<kernel>/app.aspen`へ自動反映しなかった。したがって上の公式値は既存cached application modelによる結果である。

- axpy生成モデル: source/static truthと一致
- copy生成モデル: source/static truthと一致
- dot生成モデル: `flops [1]`。source/static truthは`flops [2]`で不一致

成功後は追加ジョブ禁止のため再投入していない。新規生成3モデルの特徴量を係数式へ直接入れた診断値は、9点全体でpower MAPE `13.614919%`、energy MAPE `9.637579%`。これは保存済み`uv`標準出力から算出した公式値ではなく、dotのfeature error影響を示す診断値として分離した。

### 成果物

- Sirius: `runs/51385.pbs/summary/type0_axpy_copy_dot_51385.tar.gz`
- ローカルarchive: `results/type0_axpy_copy_dot_51385.tar.gz`
- ローカル展開先: `results/type0_axpy_copy_dot_51385/`
- 実行ログ: `results/type0_axpy_copy_dot_51385/EXECUTION_LOG.md`
- 公式9点: `results/type0_axpy_copy_dot_51385/evaluation/official_end_to_end_comparison.csv`
- MAPE: `results/type0_axpy_copy_dot_51385/evaluation/mape_summary.csv`
- 係数: `results/type0_axpy_copy_dot_51385/training/type0_model.json`
- machine model before/provisional/diff: `results/type0_axpy_copy_dot_51385/machine_models/`
- token/time: `results/type0_axpy_copy_dot_51385/generation/`
- 全予測stdout/stderr・commands: `results/type0_axpy_copy_dot_51385/predictions/`
