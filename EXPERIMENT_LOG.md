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

## 2026-11-26 MI300A Type0 runtime高密度グリッド再測定

### 目的と実験点

- 対象: Type0の `axpy`、`copy`、`dot`
- GPU / ROCm: AMD Instinct MI300A / 7.2.0
- SiriusジョブID: `51388.pbs`
- キュー / walltime上限: `mcrp` / `00:30:00`
- ジョブがcloneしたGitHub commit: `6d4d66a36365177d263ff3e8d78e0eab85c91fe2`
- 新規ジョブ投入数: 1
- 再投入: なし

学習サイズは`16,777,216`から`2,147,483,648`まで2倍刻みの8点とした。
検証サイズは隣接する学習点の間の幾何中点を整数へ丸めた次の7点とし、
学習点との重複を避けた。

```text
23,726,566
47,453,133
94,906,266
189,812,531
379,625,062
759,250,125
1,518,500,250
```

3カーネルについて学習24点、検証21点、合計45点を新しく実測した。
最大サイズで2本のhost配列と2本のdevice配列が使用する領域は合計64 GiBで、
従来の4.1B点よりメモリ圧迫を抑えた。HIPソースとイベント計測順序は変更していない。

### 実行結果

- 保存ステータス: `SUCCESS`
- HIPコンパイル: 3/3成功
- 実測: 45/45点成功
- 公式GenASPEN cached-model予測: 21/21点成功
- 学習済み単一帯域: `3784.2604938964796 GB/s`
- 学習runtime MAPE: `5.45400601242516%`
- LLM prompt/completion tokens: `0 / 0`（前回のcached application modelを再利用）
- canonical GenASPENと標準MI300A machine modelの変更: なし

| group | validation points | runtime MAPE |
|---|---:|---:|
| all | 21 | 4.605848% |
| axpy | 7 | 3.740782% |
| copy | 7 | 6.407758% |
| dot | 7 | 3.669005% |

検証点をサイズ別に3カーネル平均すると、MAPEは次のとおりだった。

| n | runtime MAPE |
|---:|---:|
| 23,726,566 | 9.5822% |
| 47,453,133 | 4.8853% |
| 94,906,266 | 3.3934% |
| 189,812,531 | 2.5851% |
| 379,625,062 | 3.6996% |
| 759,250,125 | 4.1321% |
| 1,518,500,250 | 3.9633% |

`axpy`と`dot`の実効帯域は16.8M付近では約3.1--3.2 TB/sで、問題サイズと
ともに増加し、2.147Bでは約3.87 TB/sへ達した。`copy`も2.147Bで約4.14 TB/sを
維持した。したがって今回の上限2.147Bまで4.1B点のような帯域低下は観測されず、
上限として妥当だった。一方、最小側23.7Mでは`axpy`/`dot`の誤差が約12.5%あり、
16.8Mを含む範囲全体を単一帯域だけで表すと立ち上がり領域の誤差が残る。
また、定常域では`copy`の実効帯域が`axpy`/`dot`より高いため、単一帯域の妥協値では
`copy`の大サイズ側に約7.7--9.1%のruntime過大予測が残った。

### 時間と成果物監査

- HIPコンパイル: 5 s
- 45点測定: 417 s
- cached GenASPEN作業コピー作成: 2 s
- 21点公式予測: 3.429735 s
- 係数学習: 0.004509 s
- MAPE評価: 0.003105 s

CSV行数は測定45、予測21、比較21で期待値と一致した。保存manifestを再検証した
ところ、`timings/job_stages.jsonl`以外はすべて一致した。同ファイルだけは解析側が
manifestを作成した後、payload側が最終stage時間を1行追記したため不一致となった。
性能値・測定値の破損ではない。成功後の追加投入を避けるため再実行はせず、将来の
実行ではmanifest後の追記が起きないようpayloadを修正した。

### 保存先

- Sirius: `runs/51388.pbs/summary/type0_runtime_grid_51388.tar.gz`
- ローカルarchive: `results/type0_runtime_grid_51388.tar.gz`
- ローカル展開先: `results/type0_runtime_grid_51388/`
- 実行ログ: `results/type0_runtime_grid_51388/EXECUTION_LOG.md`
- 45点測定: `results/type0_runtime_grid_51388/input_snapshot/measurement_summary.csv`
- 21点比較: `results/type0_runtime_grid_51388/evaluation/runtime_comparison.csv`
- MAPE: `results/type0_runtime_grid_51388/evaluation/mape_summary.csv`
- runtime係数: `results/type0_runtime_grid_51388/training/runtime_model.json`
- 区間別token/time: `results/type0_runtime_grid_51388/timings/`

## 2026-11-26 MI300A Type0 power・energy事後評価

成功済み`51388.pbs`の実測45点と公式runtime/static-feature予測21点を再利用した。
新しいSiriusジョブは投入せず、canonical GenASPENおよび標準MI300A machine modelは
変更していない。power係数は学習24点だけから、前回と同じ4特徴量
`warp/s`、`FLOP/s`、`load-byte/s`、`store-byte/s`を標準化した重み付きRidgeで
学習した。Ridge alphaはtrain内leave-one-size-out MAPEにより選択した。

### 学習結果

- Ridge alpha: `1e-5`
- power train MAPE: `2.706007171961945%`
- power leave-one-size-out MAPE: `4.71951737950407%`
- 実測power CVの最大値: `1.96%`
- wavefront size: 64
- 学習行 / 検証行: 24 / 21
- 解析時間: `0.174224 s`
- LLM prompt/completion tokens: `0 / 0`

暫定machine model用power係数:

```text
param power_warp_size = 64
param power_intercept_0 = 191.97399270641279
param power_warp_0 = 2.7511003018011889e-08
param power_flop_0 = 4.1563097551290708e-11
param power_load_0 = 1.6303114531409915e-10
param power_store_0 = 5.3732427769554478e-11
```

3カーネルでは特徴量間に強い共線性があり、標準化後の設計行列rankは2である。
したがって各係数を独立した物理量として解釈せず、4項を合わせた予測モデルとして扱う。

### 検証結果

| group | points | runtime MAPE | power MAPE | energy MAPE |
|---|---:|---:|---:|---:|
| all | 21 | 4.605848% | 2.909455% | 2.433751% |
| axpy | 7 | 3.740782% | 1.226551% | 3.206171% |
| copy | 7 | 6.407758% | 5.686418% | 1.583769% |
| dot | 7 | 3.669005% | 1.815396% | 2.511312% |

実測runtimeと正確な静的特徴量を電力モデルへ与えた場合のpower MAPEは`1.840875%`、
公式の予測runtime/static featuresを与えたend-to-end power MAPEは`2.909455%`だった。
差分は主にruntime予測誤差がrate特徴量へ伝播した分である。

copyではruntimeを平均的に過大予測する一方でpowerを過小予測するため、積であるenergyの
誤差が相殺され、power MAPE `5.686418%`に対してenergy MAPEが`1.583769%`となった。
したがってenergy MAPEの低さだけをruntime/power各モデルの精度と解釈しない。

### 保存先

- 解析実行ログ: `results/type0_runtime_grid_51388/power_energy/EXECUTION_LOG.md`
- 21点比較: `results/type0_runtime_grid_51388/power_energy/evaluation/power_energy_comparison.csv`
- MAPE: `results/type0_runtime_grid_51388/power_energy/evaluation/mape_summary.csv`
- power誤差分解: `results/type0_runtime_grid_51388/power_energy/evaluation/power_error_decomposition.csv`
- power係数: `results/type0_runtime_grid_51388/power_energy/training/power_model.json`
- 暫定machine model: `results/type0_runtime_grid_51388/power_energy/machine_model/`

## 2026-11-26 MI300A Type0 6カーネル再学習・予測評価

### 実験構成

- SiriusジョブID: `51389.pbs`
- キュー / walltime上限: `mcrp` / `00:30:00`
- ジョブがcloneしたGitHub commit: `b4f139729edd1323f7ad3d910ad803aa7d6ce9d1`
- GPU / ROCm: AMD Instinct MI300A / 7.2.0
- 既存実測: `51388.pbs`のaxpy/copy/dot 45点
- 新規実測: softmax/gelu/relu 45点
- 合計: 6カーネル、学習48点、保持した検証42点
- 新規ジョブ投入数: 1
- 再投入: なし

新規3カーネルも、学習には16,777,216から2,147,483,648まで2倍刻みの8点、
検証には隣接学習点の幾何中点7点を使用した。静的特徴量はcached ASPEN modelの
定義に統一し、softmax=`3 FLOP/16B load/8B store`、
gelu=`9 FLOP/8B load/8B store`、relu=`0 FLOP/8B load/8B store`とした。

### 学習結果

- runtime単一帯域: `4028.8748926229428 GB/s`
- runtime train MAPE: `17.69695194293325%`
- power Ridge alpha: `0.0001`
- power train MAPE: `3.563628435658902%`
- power leave-one-size-out MAPE: `4.0850476598223375%`
- power設計行列: 4列、rank 3

暫定power係数:

```text
param power_warp_size = 64
param power_intercept_0 = 696.84688697035699
param power_warp_0 = 4.2273139764141306e-09
param power_flop_0 = 1.8916771292358184e-11
param power_load_0 = 3.9786731475372178e-12
param power_store_0 = 8.2564726101838488e-12
```

rank deficientであるため、power係数は個別の物理量として解釈せず、組み合わせた
予測器として扱う。

### 42点の公式end-to-end評価

| group | points | runtime MAPE | power MAPE | energy MAPE |
|---|---:|---:|---:|---:|
| all | 42 | 17.194398% | 2.737702% | 16.771001% |
| axpy | 7 | 8.303741% | 2.709129% | 10.343465% |
| copy | 7 | 3.040873% | 2.478775% | 1.873813% |
| dot | 7 | 8.209812% | 3.285538% | 9.645877% |
| softmax | 7 | 32.910710% | 2.374336% | 29.754953% |
| gelu | 7 | 47.717409% | 2.960639% | 46.169533% |
| relu | 7 | 2.983843% | 2.617794% | 2.838367% |

native C++ runtime/power/energy predictorとPython直接式の一致検査は42/42点成功した。
power MAPEは全体2.74%だが、energyはruntime誤差の影響を受けて16.77%となった。

### runtime誤差の考察

- reluの実効帯域は大サイズ側で約4.12 TB/sとなりcopyとほぼ一致する。単一bwの
  Type0モデルでruntime MAPE約2.98%に収まった。
- softmaxのASPEN modelは`a[i]`と全thread共通の`a[0]`をともに毎要素loadとして
  16B計上する。しかし`a[0]`はcacheで再利用されるため、論理byte数から計算した
  実効帯域は約5.46 TB/sとなる。このtraffic過大計上によりruntimeを約33%過大予測した。
- geluは`tanh`を含む計算コストが支配的で、16B/要素から換算した実効帯域は
  約2.12 TB/sに留まる。単一memory bw式はruntimeを約48%過小予測した。
- このため、同じ1次元elementwise/Type0分類でも、softmaxにはcache reuseを反映した
  trafficモデル、geluにはtranscendental/SFUまたはcompute項が必要である。

6カーネルを一つの単一bwへまとめると、元のaxpy/dotも新しい高めのbwに引かれて
runtime MAPEが約8.3%へ悪化した。copy/reluは約3%であるため、次の改善では
Type0を少なくともpure-memory群とspecial-function群へ分けるか、runtime式へ
memory時間とcompute/SFU時間を併設する必要がある。

### 実行・監査

- 新規3カーネルHIPコンパイル: 5 s
- 新規45点実測: 407 s
- cached model staging: 3 s
- 42点公式予測: 6.921993 s
- LLM prompt/completion tokens: `0 / 0`
- 実測power CV最大値: `1.96%`
- CSV行数: 測定90、予測42、比較42
- 保存manifest: 全件一致
- canonical GenASPEN / MI300A machine modelの変更: なし

### 保存先

- Sirius: `runs/51389.pbs/summary/type0_six_kernel_grid_51389.tar.gz`
- ローカルarchive: `results/type0_six_kernel_grid_51389.tar.gz`
- ローカル展開先: `results/type0_six_kernel_grid_51389/`
- 実行ログ: `results/type0_six_kernel_grid_51389/EXECUTION_LOG.md`
- 90点測定: `results/type0_six_kernel_grid_51389/input_snapshot/measurement_summary.csv`
- 42点比較: `results/type0_six_kernel_grid_51389/evaluation/end_to_end_comparison.csv`
- MAPE: `results/type0_six_kernel_grid_51389/evaluation/mape_summary.csv`
- runtime/power係数: `results/type0_six_kernel_grid_51389/training/`
- machine model: `results/type0_six_kernel_grid_51389/machine_model/`
- token/time: `results/type0_six_kernel_grid_51389/timings/`

## 2026-11-26 softmax source照合と修正

`51389.pbs`で測定したsoftmaxを指定された参照カーネルと照合したところ、完全実行版は
`max_val`更新を省略して`exp`を使用し、kernel-only版も`a[i]`の読み方と`exp`が参照と
異なっていた。次の2ファイルを同じ参照カーネルへ統一した。

- `hip_kernels/softmax.hip`
- `hip_kernels_only/softmax_kernel.hip`

修正後は`max_val = a[0]`、`ai = a[i]`、条件付きmax更新、`expf`、`sum /= sum`、
`b[i] = sum`の順序で一致する。cached ASPEN modelの論理特徴量は3 operations、
16B load、8B storeであり、総数は変更していない。

このソース修正は成功済みジョブ`51389.pbs`の後に行ったため、同ジョブのsoftmax実測は
修正前コードの結果である。修正後softmaxの実測値として再利用せず、次回のGPU測定で
再取得してから6カーネル係数を再学習する必要がある。成功後の追加ジョブは投入していない。

問題サイズと実効bwの全表、runtime calibrationの式と学習分離、安定性の統計は
`TYPE0_SIX_KERNEL_SIZE_BW_AUDIT.md`へ保存した。
