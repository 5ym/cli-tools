# cli-tools

手元で使う CLI を **コンテナで動かす** ための道具。Windows から WSL コンテナ (wslc) で、[t.ps1](t.ps1) を通して使う。
手元には wslc だけを入れればよく、CLI の版は [Dockerfile](Dockerfile) で固定し、Renovate が上げる。

```powershell
git clone https://github.com/5ym/cli-tools
cd cli-tools
./t.ps1 aws login --profile work          # --remote は t.ps1 が付ける (下の「ログイン」)
./t.ps1 aws --profile work sts get-caller-identity
$env:AWS_PROFILE = 'work'; ./t.ps1 aws s3 ls
'{"a":1}' | ./t.ps1 jq .a
./t.ps1                                   # 引数なしならシェルに入る
```

初回はイメージを作るので少し待つ。2 回目からはキャッシュで一瞬。

| 入っているもの | 用途 |
| --- | --- |
| aws | AWS CLI v2 (公式のイメージ `public.ecr.aws/aws-cli/aws-cli` を版で固定) |
| jq | 出力の加工 |

## 要るもの

- Windows の [WSL](https://learn.microsoft.com/windows/wsl/) と、それに付いてくる `wslc` (WSL コンテナの CLI)
- PowerShell (7 系でも Windows PowerShell 5.1 でも動く)

## ログイン

`aws login` (コンソールのログインをそのまま CLI に使う方式) を使う。アクセスキーは置かない。

- wslc は host ネットワークに対応していないので、ブラウザから手元の `localhost` に返ってくる方式は届かない。
  **`t.ps1` が `aws login` に `--remote` を付ける** ── 表示された URL をブラウザで開き、ログイン後に出るコードを
  ターミナルに貼り付ける。対話なので、自分の端末から動かす
- プロファイル名は自由。どのアカウントに入るかはブラウザでログインするときに選ぶので、入ったら
  `sts get-caller-identity` で確かめる
- 切れたら `./t.ps1 aws login --profile <名前>` をやり直す

## 仕組み

- `wslc run` でイメージを動かす。このリポジトリはコンテナの `/repo` に置く
- **ログインはリポジトリの `.home/` に置く** (コンテナの中の `HOME`。`.gitignore` 済み)。手元のホームは汚さない。
  `.home/` は本人だけが読める ACL にする。**`git clean -fdx` で消える** (ログインし直せば戻る)
- `.dockerignore` で Dockerfile 以外をビルドの文脈から外している (`.home/` をイメージの組み立てに載せない)
- Dockerfile を変えると、次の `./t.ps1` でイメージを作り直す
- `AWS_PAGER` は空にしてある (ページャで止まらない)。`AWS_PROFILE` は手元で設定しているときだけ渡す
- PowerShell でパイプしたもの (`'{"a":1}' | ./t.ps1 jq .`) は、`t.ps1` がコンテナの標準入力に流し直す。
  行を LF でつないだ UTF-8 にして渡す (PowerShell のまま流すと CRLF になり、5.1 では日本語が `?` に化けるため、
  base64 で包んでコンテナの中で戻す)。PowerShell のパイプは行 (文字列) 単位なので、バイナリは通らない
- `t.ps1` は **BOM 付きの UTF-8** にしてある。BOM が無いと Windows PowerShell 5.1 が Shift_JIS として読み、
  日本語のコメントで構文が壊れる

## wslc の制限

- **wslc は host ネットワークに対応していない** (上のログイン)
- uid は指定しない (Windows のファイルに持ち主の uid は無い)
- **`wslc-compose` は使わない。** 標準入力がコンソールでもパイプでもないところ (AI のエージェントのツールなど) で
  `-i` を付けると、1 秒ほど以上かかるコマンドの出力が落ちて `ERROR_INVALID_HANDLE` になる。`wslc-compose run` は
  必ず標準入力をつなぐので避けられない。`t.ps1` は `wslc run` を直接使い、手元の端末かパイプのときだけ `-i` を付ける

## 入れるものの確かめ方

**全部、公式が出しているもので確かめてから入れる。** 一致しなければ組み立てごと止まる。

- aws: AWS CLI v2 はチェックサムのファイルを出していない (PGP の署名だけ) ので、自前では入れず、AWS 公式の
  イメージを版で固定して土台にする
- jq: リリースのチェックサムのファイル

## CLI を足す

[Dockerfile](Dockerfile) の jq と同じ形で足す。`# renovate: datasource=… depName=…` の次の行に `ARG 名前=版` を書き、
公式のチェックサムで確かめてから入れる。[CI](.github/workflows/tools.yml) の確認のコマンドにも足す。

## 版

`FROM` は Renovate の Dockerfile の既定で、`# renovate:` の次の `ARG` は [renovate.json](renovate.json) の
customManagers で上げる。PR では [CI](.github/workflows/tools.yml) がイメージを作り、全部のコマンドが動くことを見る。
