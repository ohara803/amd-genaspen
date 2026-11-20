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
