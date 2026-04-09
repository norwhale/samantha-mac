---
title: "NVIDIAが作った「細胞の言語モデル」maxToki を徹底解剖してみた"
description: "ChatGPTのような言語モデルで、細胞の未来を予測する？NVIDIAの最新AIツール maxToki のコードを読み解き、その仕組みを図解します。"
date: "2026-04-05"
tags: ["AI", "Biology", "NVIDIA", "LLM", "SingleCell", "DeepLearning"]
image: "/images/hero-maxtoki.svg"
---

**「もし、ChatGPTのように"次の単語"を予測する技術で、"次の細胞の状態"を予測できたら？」**

NVIDIAのデジタルバイオロジーチームが2026年4月に公開した **maxToki** は、まさにそのアイデアを実現した AI です。

今回はこのリポジトリ（約22,000行のPythonコード）をクローンして徹底的に読み解いてみました。

> GitHub: [NVIDIA-Digital-Bio/maxToki](https://github.com/NVIDIA-Digital-Bio/maxToki)

---

## What is maxToki?（maxTokiとは何か）

maxToki は **単一細胞RNA-seq（scRNA-seq）データ** を入力とし、**細胞の未来の遺伝子発現プロファイル** を自己回帰的に予測するトランスフォーマーモデルです。

ひとことで言えば：

> **「細胞版ChatGPT」** — 遺伝子の発現パターンを"言語"として学習し、細胞の運命を予測する

---

## The Core Idea（核心のアイデア）

ChatGPTが「単語の並び」から次の単語を予測するように、maxTokiは「遺伝子の発現ランキング」から次の細胞状態を予測します。

| | ChatGPT (LLM) | maxToki (Cell LM) |
|---|---|---|
| **入力** | テキスト（単語列） | 遺伝子発現プロファイル |
| **トークン** | 単語 / サブワード | 遺伝子（Ensembl ID） |
| **並び順** | 文法・意味的順序 | 発現量の降順ランク |
| **予測タスク** | 次の単語 | 次の細胞状態 |
| **追加タスク** | - | 細胞間の経過時間 |
| **アーキテクチャ** | Transformer (decoder) | LLaMA 3.2 ベース |
| **語彙サイズ** | ~100K tokens | ~20,000遺伝子 + 特殊トークン |

---

## Rank-Value Encoding: 遺伝子を「言葉」に変える魔法

maxTokiの最も独創的な部分は **Rank-Value Encoding（RVE）** というトークナイゼーション手法です。

### 通常のscRNA-seq解析

```
遺伝子A: 1,523 counts
遺伝子B: 892 counts
遺伝子C: 45 counts
遺伝子D: 0 counts
...（約20,000遺伝子）
```

### maxTokiのRVE

```
<bos> 遺伝子A 遺伝子B 遺伝子C ... <eos>
  ↑        ↑発現量1位  ↑2位  ↑3位     ↑
  開始      降順にランク付け           終了
```

**なぜランク順にするのか？**

- **シーケンシング深度に依存しない** — 絶対値ではなく順位なので、実験条件が違っても比較可能
- **ゼロ発現を無視できる** — 発現していない遺伝子はトークン列に含めないので、スパース性を自然に処理
- **Transformer との相性が良い** — 離散トークン列として扱えるので、言語モデルの枠組みがそのまま使える

---

## The Architecture（モデルアーキテクチャ）

maxTokiは **LLaMA 3.2** をベースにした decoder-only Transformer です。

### Model Specifications

| パラメータ | 値 |
|---|---|
| **総パラメータ数** | 217M (2.17億) |
| **Transformer層数** | 11 |
| **アテンションヘッド数** | 8 |
| **隠れ層次元** | 1,232 |
| **FFN隠れ層次元** | 3,088 |
| **ヘッド次元** | 154 |
| **位置エンコーディング** | RoPE (Rotary) |
| **事前学習コンテキスト長** | 4,096 tokens |
| **時系列学習コンテキスト長** | 16,384 tokens |
| **RoPEスケーリング係数** | 4.0x |

### GPT-2 / LLaMA 7B との比較

| | maxToki | GPT-2 | LLaMA 7B |
|---|---|---|---|
| **パラメータ数** | 217M | 124M | 7B |
| **層数** | 11 | 12 | 32 |
| **隠れ層** | 1,232 | 768 | 4,096 |
| **ヘッド数** | 8 | 12 | 32 |
| **語彙** | ~20K遺伝子 | 50,257 | 32,000 |
| **ドメイン** | 単一細胞生物学 | 汎用テキスト | 汎用テキスト |

maxTokiはGPT-2より少し大きく、LLaMA 7Bよりはるかに小さい。しかし、ドメイン特化した語彙とタスク設計により、細胞状態予測において強力な性能を発揮します。

---

## Two Tasks, One Model（2つのタスク、1つのモデル）

maxTokiは1つのTransformerで **2つのタスク** を同時に学習します。

### Task 1: NextCell（次の細胞状態予測）

```
入力:  <bos> GeneA GeneB GeneC <eos> <boq> <eoq>
予測:                                        <bos> GeneX GeneY GeneZ <eos>
                                              ↑ 未来の細胞の遺伝子発現を生成
```

- **損失関数**: Cross-Entropy（言語モデルと同じ）
- **生成方式**: 自己回帰（1トークンずつ生成）
- **サンプリング**: Top-k, Nucleus (Top-p), Temperature

### Task 2: TimeBetweenCells（経過時間予測）

```
入力:  <bos> GeneA GeneB <eos> <boq> <eoq>
予測:                                       42  （= 42時間後）
                                            ↑ 次の観測までの時間を回帰予測
```

- **損失関数**: MSE（平均二乗誤差）
- **出力**: 数値トークンの確率分布から期待値を計算
- **スケーリング**: ラベルを200で正規化

### 統合損失関数

```
Total Loss = 0.5 * CE_loss(NextCell) + 0.5 * MSE_loss(TimeBetweenCells)
           + penalty * P(non-numeric tokens in time prediction)
```

タスクごとにマスクを適用し、遺伝子予測部分にはCE損失のみ、時間予測部分にはMSE損失のみが適用されます。

---

## Data Pipeline（データパイプライン）

生の単一細胞データから予測までの流れを整理します。

### Stage 1: Tokenization（トークン化）

```
h5ad ファイル (cells x genes 行列)
        │
        ▼
  ゼロでない遺伝子を抽出
        │
        ▼
  発現量の降順でソート
        │
        ▼
  遺伝子名 → トークンID に変換
        │
        ▼
  <bos> token1 token2 ... tokenN <eos>
```

### Stage 2: Paragraph Assembly（パラグラフ構築）

```
同一軌跡の細胞をグループ化
        │
        ▼
  時間順にソート
        │
        ▼
  細胞間に時間トークンを挿入
        │
        ▼
  NextCell / TimeBetweenCells にランダム分割 (50:50)
```

### Stage 3: Training（学習）

| 設定 | 事前学習 | 時系列学習 |
|---|---|---|
| **学習率** | 1e-4 | 5e-5 |
| **系列長** | 4,096 | 16,384 |
| **タスク** | 次トークン予測 | NextCell + TimeBetweenCells |
| **損失** | CE のみ | CE + MSE (混合) |
| **RoPEスケーリング** | 1.0x | 4.0x |
| **ウォームアップ** | 1% | 1% |
| **スケジューラ** | Cosine decay | Cosine decay |

---

## The Special Tokens（特殊トークン辞書）

maxTokiは6つの特殊トークンを使います。これが「細胞の文法」を形成します。

| トークン | 役割 | LLMでの類似概念 |
|---|---|---|
| `<bos>` | 1つの細胞の発現プロファイル開始 | 文の開始 |
| `<eos>` | 1つの細胞の発現プロファイル終了 | 文の終了 |
| `<boq>` | クエリ領域の開始（「ここから予測して」） | プロンプトの区切り |
| `<eoq>` | クエリ領域の終了 | プロンプト終了マーカー |
| `<pad>` | バッチ内のパディング | パディング |
| `<mask>` | マスキング（将来の拡張用） | [MASK] (BERT的) |

---

## Code Architecture（コードの構造）

約22,000行のPythonコードが4つのサブパッケージに整理されています。

| サブパッケージ | 役割 | ファイル数 | コード行数 |
|---|---|---|---|
| **bionemo-maxtoki** | maxTokiモデル本体 | 29 | 10,977 |
| **bionemo-llm** | 共有LLMプリミティブ | 38 | 4,694 |
| **bionemo-core** | ユーティリティ | 22 | 2,096 |
| **bionemo-testing** | テストヘルパー | 19 | 2,122 |
| **合計** | | **108** | **19,889** |

主要モジュール（bionemo-maxtoki内）:

| ファイル | サイズ | 内容 |
|---|---|---|
| `model.py` | 56KB | モデル定義、損失関数、回帰ヘッド |
| `tokenizer.py` | 49KB | RVEトークナイザー、位置ID生成 |
| `train.py` | 37KB | Megatron/NeMo統合の学習スクリプト |
| `generate_utils.py` | 25KB | KVキャッシュ付き自己回帰生成 |
| `export_hf.py` | 15KB | HuggingFace形式への変換 |

---

## Why It Matters（なぜこれが重要なのか）

### 医学的意義

- **細胞分化の予測**: 幹細胞がどの細胞タイプに分化するかを予測
- **疾患進行のモデリング**: がん細胞の状態変化を時系列で追跡
- **創薬への応用**: 薬物投与後の細胞応答を予測

### 技術的新規性

1. **Rank-Value Encoding** — 連続値の遺伝子発現を離散トークンに変換する独自手法
2. **マルチタスク時系列学習** — 状態予測と時間予測を同時に学習
3. **RoPEスケーリング** — 事前学習(4K) → 時系列学習(16K)でのコンテキスト拡張
4. **Megatron分散学習** — マルチGPUでのスケーラブルな学習基盤

---

## Requirements（必要環境）

実行にはかなりの計算リソースが必要です。

| 要件 | 最低 | 推奨 |
|---|---|---|
| **GPU** | NVIDIA A100 (40GB) | NVIDIA H100 (80GB) |
| **CUDA** | 12.x | 12.4+ |
| **環境** | Docker必須 | Docker + NVIDIA Container Toolkit |
| **フレームワーク** | BioNeMo + NeMo 2.7.2 | 同左 |
| **CPU実行** | 非対応 | 非対応 |

> Note: TransformerEngineの依存関係により、CPUでの実行はサポートされていません。

---

## My Takeaway（所感）

医学生としてこのプロジェクトを見て、一番驚いたのは **「言語モデルの枠組みが生物学にこれほど自然に適用できる」** という事実です。

遺伝子の発現パターンを「文章」として捉え、細胞の時間変化を「物語の続き」として予測する — このアナロジーは単なるメタファーではなく、実際に機能するアーキテクチャとして実装されています。

特に興味深いのは **Rank-Value Encoding** です。絶対的な発現量ではなく「どの遺伝子が最も発現しているか」という相対的な順位を使うことで、実験条件の違いを吸収しつつ、Transformerが得意とする離散トークン列の問題に帰着させています。

217Mパラメータという比較的小さなモデルサイズで成果を出している点も注目です。これは、ドメイン特化した語彙設計とタスク設計がいかに重要かを示しています。

---

## References

- Gomez Ortega et al., "Temporal AI model predicts drivers of cell state trajectories," bioRxiv, April 2026.
- [NVIDIA-Digital-Bio/maxToki](https://github.com/NVIDIA-Digital-Bio/maxToki) (GitHub)
- [NVIDIA BioNeMo Framework](https://www.nvidia.com/en-us/clara/bionemo/)
