$port = 8080
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$pendingDir = Join-Path $dir 'pending'

$mime = @{
  '.html' = 'text/html; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.svg'  = 'image/svg+xml'
  '.png'  = 'image/png'
  '.ico'  = 'image/x-icon'
}

function Send-Json($res, $data) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
  $res.ContentType = 'application/json; charset=utf-8'
  $res.Headers.Add('Access-Control-Allow-Origin', '*')
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

# ファイアウォール例外を追加（管理者権限で実行時のみ成功）
$ruleName = "SuidoPhotoManager_$port"
$existing = netsh advfirewall firewall show rule name=$ruleName 2>$null
if ($existing -notmatch 'OK') {
  netsh advfirewall firewall add rule name=$ruleName dir=in action=allow protocol=TCP localport=$port | Out-Null
  Write-Host "  Firewall rule added for port $port" -ForegroundColor DarkGray
}

$ip = (Get-NetIPAddress -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
       Sort-Object -Property { $_.InterfaceIndex } |
       Select-Object -First 1).IPAddress

Write-Host ""
Write-Host "  http://localhost:$port         (このPC)" -ForegroundColor Green
if ($ip) { Write-Host "  http://${ip}:${port}   (スマホはこちら)" -ForegroundColor Yellow }
Write-Host "  Stop: Ctrl+C" -ForegroundColor DarkGray
Write-Host ""

# URLネームスペースを登録（管理者権限があれば成功、なければ無視）
& netsh http add urlacl url="http://+:${port}/" user="Everyone" 2>$null | Out-Null

$listener = New-Object System.Net.HttpListener
# まずネットワーク全体でリッスン試行、失敗したらlocalhostのみ
$networkMode = $false
try {
  $testListener = New-Object System.Net.HttpListener
  $testListener.Prefixes.Add("http://+:${port}/")
  $testListener.Start()
  $testListener.Stop()
  $networkMode = $true
} catch {}

if ($networkMode) {
  $listener.Prefixes.Add("http://+:${port}/")
} else {
  $listener.Prefixes.Add("http://localhost:${port}/")
  Write-Host "  ※ 管理者権限がないためスマホ連携は使えません" -ForegroundColor Red
  Write-Host "    アプリ起動.bat を右クリック→管理者として実行 してください" -ForegroundColor Red
  $ip = $null
}

try {
  $listener.Start()
  Start-Process "http://localhost:$port"

  while ($listener.IsListening) {
    $ctx  = $listener.GetContext()
    $req  = $ctx.Request
    $res  = $ctx.Response
    $path = $req.Url.LocalPath
    $meth = $req.HttpMethod

    try {
      if ($meth -eq 'OPTIONS') {
        $res.Headers.Add('Access-Control-Allow-Origin', '*')
        $res.Headers.Add('Access-Control-Allow-Methods', 'GET,POST,DELETE')
        $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
        $res.StatusCode = 204

      } elseif ($meth -eq 'GET' -and $path -eq '/server-info') {
        Send-Json $res ('{"ip":"' + $ip + '","port":' + $port + '}')

      } elseif ($meth -eq 'GET' -and $path -eq '/cases') {
        $f = Join-Path $dir 'case_export.json'
        if (Test-Path $f) { Send-Json $res ([IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)) }
        else               { Send-Json $res '{"cases":[],"processes":[]}' }

      } elseif ($meth -eq 'POST' -and $path -eq '/cases') {
        $body = [IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8).ReadToEnd()
        [IO.File]::WriteAllText((Join-Path $dir 'case_export.json'), $body, [System.Text.Encoding]::UTF8)
        Send-Json $res '{"ok":true}'

      } elseif ($meth -eq 'GET' -and $path -eq '/pending-photos') {
        if (-not (Test-Path $pendingDir)) { New-Item -ItemType Directory $pendingDir | Out-Null }
        $files = @(Get-ChildItem $pendingDir -Filter '*.json' -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { Send-Json $res '[]' }
        else {
          $arr = $files | ForEach-Object { [IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8) }
          Send-Json $res ('[' + ($arr -join ',') + ']')
        }

      } elseif ($meth -eq 'POST' -and $path -eq '/pending-photos') {
        if (-not (Test-Path $pendingDir)) { New-Item -ItemType Directory $pendingDir | Out-Null }
        $body = [IO.StreamReader]::new($req.InputStream, [System.Text.Encoding]::UTF8).ReadToEnd()
        $obj  = $body | ConvertFrom-Json
        $id   = $obj.id
        if (-not $id) { $id = [System.Guid]::NewGuid().ToString('N') }
        [IO.File]::WriteAllText((Join-Path $pendingDir "$id.json"), $body, [System.Text.Encoding]::UTF8)
        Send-Json $res ('{"ok":true,"id":"' + $id + '"}')

      } elseif ($meth -eq 'DELETE' -and $path -like '/pending-photos/*') {
        $id = ($path -split '/')[-1] -replace '[^a-zA-Z0-9]',''
        if ($id) {
          $f = Join-Path $pendingDir "$id.json"
          if (Test-Path $f) { Remove-Item $f -Force }
        }
        Send-Json $res '{"ok":true}'

      } elseif ($meth -eq 'GET') {
        $local = $path.TrimStart('/').Replace('/', [IO.Path]::DirectorySeparatorChar)
        if ($local -eq '' -or $local -eq [IO.Path]::DirectorySeparatorChar) { $local = 'index.html' }
        $full = Join-Path $dir $local
        if (Test-Path $full -PathType Leaf) {
          $bytes = [IO.File]::ReadAllBytes($full)
          $ext   = [IO.Path]::GetExtension($full).ToLower()
          $ct    = if ($mime[$ext]) { $mime[$ext] } else { 'application/octet-stream' }
          $res.ContentType     = $ct
          $res.ContentLength64 = $bytes.Length
          $res.OutputStream.Write($bytes, 0, $bytes.Length)
        } else {
          $res.StatusCode = 404
        }
      } else {
        $res.StatusCode = 405
      }
    } catch { $res.StatusCode = 500 }
    try { $res.OutputStream.Close() } catch {}
  }
} catch {
  Write-Host "Error: $_" -ForegroundColor Red
  Start-Sleep -Seconds 5
} finally {
  $listener.Stop()
}
