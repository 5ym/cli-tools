# 手元で使う CLI を wslc (WSL コンテナ) で動かす (README.md)。例:
#   ./t.ps1 aws login --profile work
#   ./t.ps1 aws --profile work sts get-caller-identity
# 引数が無ければシェルに入る。Dockerfile を変えたら次の実行で作り直す (変わっていなければキャッシュで一瞬)。
#
# wslc の制限:
# - ネットワークは host にできない。aws login はブラウザのログイン結果を手元の localhost に送ってくるので
#   届かない。--remote (表示されたコードを貼り付ける方式) を自動で付ける
# - uid の指定はしない (Windows のファイルに持ち主の uid は無い)
# - wslc-compose ではなく wslc run を直接使う。wslc-compose run は標準入力を必ずつなぐので、コンソールの無いところ
#   (AI のエージェントのツールなど) から呼ぶと 1 秒ほど以上かかるコマンドの出力が落ちる (下の -i の注)
# 5.1 でも読めるように、このファイルは BOM 付きの UTF-8 にする (BOM が無いと 5.1 は Shift_JIS として読み、
# 日本語のコメントで構文が壊れる)。文字列は ASCII だけにする
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$image = 'cli-tools:latest'

# ログインの置き場 (コンテナの中の HOME)。git には入らない。自分だけが読める権限にする (chmod 700 相当)
$home_ = Join-Path $root '.home'
if (-not (Test-Path $home_)) {
    New-Item -ItemType Directory $home_ | Out-Null
    icacls $home_ /inheritance:r /grant:r "${env:USERNAME}:(OI)(CI)F" | Out-Null
}

$build = wslc image build --tag $image --progress quiet $root 2>&1
if ($LASTEXITCODE -ne 0) { $build | Write-Host; throw "tools: image build failed ($LASTEXITCODE)" }

# 標準入力は、手元の端末かパイプのときだけつなぐ (-i)。標準入力がどちらでもないところ (AI のエージェントのツールなど) で
# -i を付けると、1 秒ほど以上かかるコマンドの出力が落ちて ERROR_INVALID_HANDLE になる (2026-10-07)。
# 手元の端末から対話で使うときだけ TTY を付ける (-t)。
# このスクリプトにパイプしたもの (`x | ./t.ps1 jq .`) は標準入力ではなく $input に来るので、下で流し直す
# (流さないとコンテナには何も届かない)
$piped = $MyInvocation.ExpectingInput
$opts = @('--rm', '-v', "${root}:/repo", '-w', '/repo', '-e', 'HOME=/repo/.home', '-e', 'AWS_PAGER=')
if ($piped -or -not [Console]::IsInputRedirected) { $opts += '-i' }
if (-not ($piped -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) { $opts += '-t' }
# 手元で設定しているときだけ渡す
if ($env:AWS_PROFILE) { $opts += '-e', "AWS_PROFILE=$env:AWS_PROFILE" }
$cmd = if ($args.Count) { @($args) } else { @('bash') }

# aws login: コールバックの localhost がコンテナに届かないので、コードを貼り付ける方式にする
$sub = $cmd | Select-Object -Skip 1 | Where-Object { $_ -notlike '-*' } | Select-Object -First 1
if ($cmd[0] -eq 'aws' -and $sub -eq 'login' -and -not ($cmd -contains '--remote')) { $cmd += '--remote' }

if ($piped) {
    # PowerShell からネイティブのコマンドに流すと、改行が CRLF になり、5.1 では日本語が ? に化ける。
    # 行を LF でつないだ UTF-8 を base64 (ASCII だけ) にして渡し、コンテナの中で戻してからコマンドに渡す
    $text = (@($input) -join "`n") + "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text))
    # 7.3 より前 (5.1 も) は引数の中の " をネイティブのコマンドに渡すときにエスケープしないので、自分でする
    $wrap = 'base64 -d -i | "$@"'
    if ($PSVersionTable.PSVersion -lt [version]'7.3') { $wrap = $wrap.Replace('"', '\"') }
    $b64 | wslc run @opts $image sh -c $wrap sh @cmd
} else {
    wslc run @opts $image @cmd
}
exit $LASTEXITCODE
