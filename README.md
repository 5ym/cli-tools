# cli-tools

手元で使う CLI を **コンテナで動かす** ための道具。Windows から WSL コンテナ (wslc) で、[t.ps1](t.ps1) を通して使う。
手元には wslc だけを入れればよく、CLI の版は [Dockerfile](Dockerfile) で固定し、Renovate が上げる。

```powershell
git clone https://github.com/5ym/cli-tools
cd cli-tools
./t.ps1 aws login --profile work          # 表示された URL をブラウザで開く (下の「ログイン」)
./t.ps1 aws --profile work sts get-caller-identity
$env:AWS_PROFILE = 'work'; ./t.ps1 aws s3 ls
./t.ps1 aws --profile work ec2 describe-regions --output json | jq -r '.Regions[].RegionName'
./t.ps1                                   # 引数なしならシェルに入る
```

初回はイメージを作るので少し待つ。2 回目からはキャッシュで一瞬。

| 入っているもの | 用途 |
| --- | --- |
| aws | AWS CLI v2 (公式のイメージ `public.ecr.aws/aws-cli/aws-cli` を版で固定) |

## 要るもの

- Windows の [WSL](https://learn.microsoft.com/windows/wsl/) と、それに付いてくる `wslc` (WSL コンテナの CLI)
- PowerShell (7 系でも Windows PowerShell 5.1 でも動く)
- [jq](https://jqlang.org/) は手元に入れる (`winget install jqlang.jq`)。出力の加工は手元でする

## ログイン

`aws login` (コンソールのログインをそのまま CLI に使う方式) を使う。アクセスキーは置かない。

- 表示された URL をブラウザで開いてログインすると、ブラウザが手元の `http://127.0.0.1:<ポート>/oauth/callback` に
  戻ってきて終わる。コードの貼り付けは要らない
- wslc は host ネットワークに対応していないので、そのままではブラウザの戻り先がコンテナに届かない。
  **`aws login` のときだけ `t.ps1` が手元の同じポートで待ち受けて、`wslc exec` の curl でコンテナの中の CLI に渡す**。
  受け付けるのは `GET /oauth/callback` だけで、URL はコマンドに埋め込まず curl の設定として標準入力で渡す
- 別の端末のブラウザでログインしたいときは `--remote` を付ける (中継せず、ログイン後に出るコードを貼り付ける方式)
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
- PowerShell でパイプしたもの (`'hello' | ./t.ps1 cat`) は、`t.ps1` がコンテナの標準入力に流し直す。
  行を LF でつないだ UTF-8 にして渡す (PowerShell のまま流すと CRLF になり、5.1 では日本語が `?` に化けるため、
  base64 で包んでコンテナの中で戻す)。PowerShell のパイプは行 (文字列) 単位なので、バイナリは通らない
- `t.ps1` は **BOM 付きの UTF-8** にしてある。BOM が無いと Windows PowerShell 5.1 が Shift_JIS として読み、
  日本語のコメントで構文が壊れる

## wslc の制限

- **wslc は host ネットワークに対応していない** (上のログインは t.ps1 が中継する)
- uid は指定しない (Windows のファイルに持ち主の uid は無い)
- **`wslc-compose` は使わない。** 標準入力がコンソールでもパイプでもないところ (AI のエージェントのツールなど) で
  `-i` を付けると、1 秒ほど以上かかるコマンドの出力が落ちて `ERROR_INVALID_HANDLE` になる。`wslc-compose run` は
  必ず標準入力をつなぐので避けられない。`t.ps1` は `wslc run` を直接使い、手元の端末かパイプのときだけ `-i` を付ける

## 入れるものの確かめ方

**全部、公式が出しているもので確かめてから入れる。** 一致しなければ組み立てごと止まる。

- aws: AWS CLI v2 はチェックサムのファイルを出していない (PGP の署名だけ) ので、自前では入れず、AWS 公式の
  イメージを版で固定して土台にする
- ほかの CLI: リリースのチェックサムのファイル (下の「CLI を足す」)

## CLI を足す

コンテナに入れるのは、手元に入れたくないもの (版を固定したい・ログインを手元に置きたくないもの) だけにする。
[Dockerfile](Dockerfile) に次の形で足す。`# renovate: datasource=… depName=…` の次の行に `ARG 名前=版` を書き、
公式のチェックサムで確かめてから入れる。[CI](.github/workflows/tools.yml) の確認のコマンドにも足す。

```dockerfile
ARG TARGETARCH
# renovate: datasource=github-releases depName=<owner>/<repo>
ARG FOO_VERSION=v1.2.3
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN a=${TARGETARCH:-amd64}; mkdir /tmp/dl && cd /tmp/dl; \
    curl -fsSLO "https://github.com/<owner>/<repo>/releases/download/${FOO_VERSION}/foo-linux-$a"; \
    curl -fsSL "https://github.com/<owner>/<repo>/releases/download/${FOO_VERSION}/checksums.txt" \
      | grep -E "  foo-linux-$a\$" | sha256sum -c --strict -; \
    install -m 755 "foo-linux-$a" /usr/local/bin/foo; \
    cd / && rm -r /tmp/dl
```

## 版

`FROM` は Renovate の Dockerfile の既定で、`# renovate:` の次の `ARG` は [renovate.json](renovate.json) の
customManagers で上げる。PR では [CI](.github/workflows/tools.yml) がイメージを作り、全部のコマンドが動くことを見る。
