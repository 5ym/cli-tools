# 手元で使う CLI 一式 (README.md)。手元には wslc だけを入れ、版はここで固定する。
# 版は Renovate が上げる (FROM は Renovate の dockerfile の既定、ARG は `# renovate:` の次の行。renovate.json)。
#
# 土台は AWS 公式の AWS CLI のイメージ (Amazon Linux 2023)。AWS CLI v2 はチェックサムのファイルを出していない
# (PGP の署名だけ) ので、自前で入れずに公式のイメージを版で固定して使う。
# jq など出力の加工は手元のものを使う (`./t.ps1 aws ... | jq`)。CLI を足すときは README.md「CLI を足す」
FROM public.ecr.aws/aws-cli/aws-cli:2.37.11

# 公式のイメージは ENTRYPOINT が aws。t.ps1 は aws 以外 (シェルなど) も動かすので外す
ENTRYPOINT []
# HOME はリポジトリの .home/ (t.ps1)
WORKDIR /repo
CMD ["bash"]
