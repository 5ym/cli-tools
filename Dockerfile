# 手元で使う CLI 一式 (README.md)。手元には wslc だけを入れ、版はここで固定する。
# 版は Renovate が上げる (FROM は Renovate の dockerfile の既定、ARG は `# renovate:` の次の行。renovate.json)。
#
# 土台は AWS 公式の AWS CLI のイメージ (Amazon Linux 2023)。AWS CLI v2 はチェックサムのファイルを出していない
# (PGP の署名だけ) ので、自前で入れずに公式のイメージを版で固定して使う
FROM public.ecr.aws/aws-cli/aws-cli:2.37.10
ARG TARGETARCH

# renovate: datasource=github-releases depName=jqlang/jq
ARG JQ_VERSION=jq-1.8.2

# **入れるものは公式が出しているチェックサムと照らし合わせる。** get は「ファイルを取る」、ok は
# 「チェックサムのファイル (ハッシュ  ファイル名 の形) に照らす」。一致しなければ組み立てごと止まる
SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
RUN a=${TARGETARCH:-amd64}; \
    mkdir /tmp/dl && cd /tmp/dl; \
    get() { curl -fsSLO "$1"; }; \
    ok() { curl -fsSL "$1" | grep -E "  ($2)\$" | sha256sum -c --strict -; }; \
    gh=https://github.com; \
    get "$gh/jqlang/jq/releases/download/${JQ_VERSION}/jq-linux-$a"; \
    ok "$gh/jqlang/jq/releases/download/${JQ_VERSION}/sha256sum.txt" "jq-linux-$a"; \
    install -m 755 "jq-linux-$a" /usr/local/bin/jq; \
    cd / && rm -r /tmp/dl

# 公式のイメージは ENTRYPOINT が aws。t.ps1 は aws 以外 (jq やシェル) も動かすので外す
ENTRYPOINT []
# HOME はリポジトリの .home/ (compose.yaml)
WORKDIR /repo
CMD ["bash"]
