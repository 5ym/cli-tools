# 手元で使う CLI を wslc (WSL コンテナ) で動かす (README.md)。例:
#   ./t.ps1 aws login --profile work
#   ./t.ps1 aws --profile work sts get-caller-identity
# 引数が無ければシェルに入る。Dockerfile を変えたら次の実行で作り直す (変わっていなければキャッシュで一瞬)。
#
# wslc の制限:
# - ネットワークは host にできない。aws login はブラウザのログイン結果を手元の 127.0.0.1:<ポート> に送ってくるので、
#   そのときだけ同じポートで待ち受けて、コンテナの中の CLI に渡す (下の Start-LoginRelay)。
#   --remote (表示されたコードを貼り付ける方式) を付けたときは中継しない
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

# aws login (ブラウザ方式) の中継。コンテナの中で CLI が待ち受けるポートを見つけ、手元の 127.0.0.1 の同じポートで
# ブラウザのリダイレクト (GET /oauth/callback?code=...&state=...) を受けて、wslc exec の curl でコンテナの中の CLI に渡す。
# 受け付けるのは GET /oauth/callback だけ。リクエストの値はコマンドに埋め込まず、curl の設定として標準入力で渡す
function Start-LoginRelay($name) {
    Start-Job -ArgumentList $name -ScriptBlock {
        param($name)
        $port = $null
        for ($i = 0; $i -lt 240 -and -not $port; $i++) {
            Start-Sleep -Milliseconds 500
            # /proc/net/tcp(6): LISTEN (0A) しているポート。aws login は 0.0.0.0 で待ち受ける
            foreach ($l in (wslc exec $name cat /proc/net/tcp /proc/net/tcp6 2>$null)) {
                $f = -split $l
                if ($f.Count -gt 3 -and $f[1] -match ':[0-9A-F]{4}$' -and $f[3] -eq '0A') { $port = [Convert]::ToInt32($f[1].Split(':')[-1], 16) }
            }
        }
        if (-not $port) { 'relay: the login callback port was not found in the container'; return }
        try {
            $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port
            $listener.Start()
        } catch { "relay: cannot listen on 127.0.0.1:${port}: $_"; return }
        while ($true) {
            $client = $listener.AcceptTcpClient()
            # 投機的な空の接続で止まらないように
            $client.ReceiveTimeout = 10000
            try {
                $s = $client.GetStream()
                $buf = New-Object byte[] 16384
                $data = New-Object IO.MemoryStream
                $headerEnd = -1
                while ($headerEnd -lt 0 -and $data.Length -lt 65536) {
                    $n = $s.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    $data.Write($buf, 0, $n)
                    $headerEnd = [Text.Encoding]::ASCII.GetString($data.ToArray()).IndexOf("`r`n`r`n")
                }
                if ($headerEnd -lt 0) { continue }
                $line = ([Text.Encoding]::ASCII.GetString($data.ToArray(), 0, $headerEnd) -split "`r`n")[0]
                $method, $target = ($line -split ' ')[0, 1]
                if ($method -ne 'GET' -or $target -notmatch '^/oauth/callback\?[A-Za-z0-9._~%&=+-]*$') {
                    $out = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                    $s.Write($out, 0, $out.Length)
                    continue
                }
                # 埋め込むのは自分で決めた $name だけ。URL (上の正規表現で引用符などを含まないことを確かめた) は標準入力から
                $psi = New-Object Diagnostics.ProcessStartInfo 'wslc', "exec --interactive $name curl -s -i -K -"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $p = [Diagnostics.Process]::Start($psi)
                $cfg = [Text.Encoding]::ASCII.GetBytes("url = `"http://127.0.0.1:$port$target`"`n")
                $p.StandardInput.BaseStream.Write($cfg, 0, $cfg.Length)
                $p.StandardInput.Close()
                # curl -i の出力 (CLI の応答の状態行・ヘッダ・本文) をそのままブラウザに返す
                $p.StandardOutput.BaseStream.CopyTo($s)
                $p.WaitForExit()
            } catch {
            } finally {
                $client.Close()
            }
        }
    }
}

# 標準入力は NUL のとき以外つなぐ (-i)。NUL のところ (AI のエージェントのツールなど) で -i を付けると、
# 1 秒ほど以上かかるコマンドの出力が落ちて ERROR_INVALID_HANDLE になる (2026-10-07)。NUL は中身が無いので、
# つながなくても失うものは無い。ファイルや外のパイプからの入力 (`echo x | pwsh -File t.ps1 cat`) はつなぐ
# 手元の端末から対話で使うときだけ TTY を付ける (-t)。
# このスクリプトにパイプしたもの (`x | ./t.ps1 cat`) は標準入力ではなく $input に来るので、下で流し直す
# (流さないとコンテナには何も届かない)
# 標準入力が NUL か (リダイレクトされた文字デバイス = FILE_TYPE_CHAR)。ファイル (FILE_TYPE_DISK) や
# パイプ (FILE_TYPE_PIPE) からの入力は中身があるので NUL とは扱わない。端末はリダイレクトされていないので見ない
function Test-NulStdin {
    if (-not [Console]::IsInputRedirected) { return $false }
    if (-not ('CliTools.Kernel32' -as [type])) {
        Add-Type -Namespace CliTools -Name Kernel32 -MemberDefinition (
            '[DllImport("kernel32.dll")] public static extern System.IntPtr GetStdHandle(int n);' +
            '[DllImport("kernel32.dll")] public static extern int GetFileType(System.IntPtr h);')
    }
    return [CliTools.Kernel32]::GetFileType([CliTools.Kernel32]::GetStdHandle(-10)) -eq 2
}
$piped = $MyInvocation.ExpectingInput
$opts = @('--rm', '-v', "${root}:/repo", '-w', '/repo', '-e', 'HOME=/repo/.home', '-e', 'AWS_PAGER=')
if ($piped -or -not (Test-NulStdin)) { $opts += '-i' }
if (-not ($piped -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected)) { $opts += '-t' }
# 手元で設定しているときだけ渡す
if ($env:AWS_PROFILE) { $opts += '-e', "AWS_PROFILE=$env:AWS_PROFILE" }
# 引数が 1 つのときも配列にする (if の値は 1 要素の配列が中身に展開され、$cmd[0] が 1 文字目になる)
$cmd = @(if ($args.Count) { $args } else { 'bash' })

$relay = $null
$sub = $cmd | Select-Object -Skip 1 | Where-Object { $_ -notlike '-*' } | Select-Object -First 1
if ($cmd[0] -eq 'aws' -and $sub -eq 'login' -and -not ($cmd -contains '--remote')) {
    $name = "cli-tools-login-$PID"
    $opts += '--name', $name
    $relay = Start-LoginRelay $name
}
try {
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
    $code = $LASTEXITCODE
} finally {
    if ($relay) {
        Stop-Job $relay
        Receive-Job $relay -ErrorAction SilentlyContinue | ForEach-Object { Write-Warning $_ }
        Remove-Job $relay -Force
    }
}
exit $code
