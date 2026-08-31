# ---------------------------------------------------------------------------
#  Paper Reader - local server
#
#  Serves a PDF reading UI and bridges two endpoints to the local claude CLI:
#    POST /api/translate  - translate a selected passage into Korean
#    POST /api/chat       - ask a question about the paper
#
#  NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 decodes
#  BOM-less files as ANSI, which would corrupt any Korean literal placed here.
#  All Korean prompt text lives in prompts.json and is read as explicit UTF-8.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [int]$Port = 8765,
    [int]$Workers = 4,
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Definition


# --- locate the claude CLI -------------------------------------------------
function Get-NewestClaudeExe {
    param([string[]]$RootDirs)
    $found = @()
    foreach ($r in $RootDirs) {
        if (-not $r -or -not (Test-Path $r)) { continue }
        $found += Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
                  ForEach-Object { Join-Path $_.FullName 'claude.exe' } |
                  Where-Object { Test-Path $_ }
    }
    if ($found.Count -eq 0) { return $null }
    # highest version directory wins; folders that aren't a plain x.y.z fall
    # to the bottom instead of aborting the sort
    return ($found | Sort-Object {
                $v = [version]'0.0'
                [void][version]::TryParse((Split-Path (Split-Path $_ -Parent) -Leaf), [ref]$v)
                $v
            } | Select-Object -Last 1)
}

function Find-ClaudeExe {
    param([ref]$Diag)

    $cmd = Get-Command claude -ErrorAction SilentlyContinue
    $Diag.Value += "Get-Command claude -> $(if ($cmd) { $cmd.Source } else { '(not found)' })"
    if ($cmd -and $cmd.Source -and (Test-Path $cmd.Source)) { return $cmd.Source }

    # The Windows Store (MSIX-packaged) build's real files live behind package
    # virtualization at .../Packages/Claude_<hash>/LocalCache/Roaming/... - the
    # classic %APPDATA%\Claude\claude-code some tools also see is a compatibility
    # reflection of that, and on this machine it goes empty/missing on its own
    # (confirmed via startup.log across five retries), so the packaged path has
    # to be checked directly rather than relying on that reflection.
    $packagesRoot = Join-Path $env:LOCALAPPDATA 'Packages'
    $packagedRoots = @()
    if (Test-Path $packagesRoot) {
        $packagedRoots = Get-ChildItem $packagesRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude-code' }
        $Diag.Value += "packaged candidates: $($packagedRoots -join '; ')"
    }

    # normal case: same Windows account the app installed under
    $primaryRoots = @($packagedRoots) + @(
        (Join-Path $env:APPDATA 'Claude\claude-code'),
        (Join-Path $env:LOCALAPPDATA 'Claude\claude-code'),
        (Join-Path $env:USERPROFILE 'AppData\Roaming\Claude\claude-code'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Claude\claude-code')
    )
    foreach ($r in $primaryRoots) {
        $exists = Test-Path $r
        $Diag.Value += "probe: $r -> exists=$exists"
        if ($exists) {
            try {
                Get-ChildItem $r -Directory -ErrorAction Stop | ForEach-Object {
                    $exe = Join-Path $_.FullName 'claude.exe'
                    $Diag.Value += "  candidate: $exe -> exists=$(Test-Path $exe)"
                }
            } catch {
                $Diag.Value += "  Get-ChildItem failed: $($_.Exception.Message)"
            }
        }
    }
    $hit = Get-NewestClaudeExe $primaryRoots
    if ($hit) { return $hit }

    # start.bat run as a different/elevated account resolves %APPDATA% to
    # that account's own profile, not the one Claude Code is installed under -
    # fall back to scanning every local profile for the install (both the
    # classic path and the packaged one).
    $allProfileRoots = @()
    try {
        $userDirs = Get-ChildItem 'C:\Users' -Directory -ErrorAction Stop
        $allProfileRoots = @($userDirs | ForEach-Object { Join-Path $_.FullName 'AppData\Roaming\Claude\claude-code' })
        $allProfileRoots += @($userDirs | ForEach-Object {
            $pkgs = Join-Path $_.FullName 'AppData\Local\Packages'
            if (Test-Path $pkgs) {
                Get-ChildItem $pkgs -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
                    ForEach-Object { Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude-code' }
            }
        })
        $Diag.Value += "fallback scan: $($allProfileRoots -join '; ')"
    } catch {
        $Diag.Value += "fallback scan of C:\Users failed: $($_.Exception.Message)"
    }
    return (Get-NewestClaudeExe $allProfileRoots)
}

$diag = @(
    "time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "whoami: $env:USERDOMAIN\$env:USERNAME",
    "APPDATA: $env:APPDATA",
    "LOCALAPPDATA: $env:LOCALAPPDATA",
    "USERPROFILE: $env:USERPROFILE",
    "PSVersion: $($PSVersionTable.PSVersion)",
    "Root: $Root"
)

# The Claude desktop app briefly swaps out this folder while auto-updating
# itself, so a plain miss isn't necessarily a real problem - retry for a bit
# before giving up. (Confirmed via startup.log: a real "not found" moment
# landed less than 90s after this exact machine had the folder just fine.)
$ClaudeExe = $null
for ($attempt = 1; $attempt -le 5; $attempt++) {
    $diag += "--- attempt $attempt ---"
    $ClaudeExe = Find-ClaudeExe ([ref]$diag)
    if ($ClaudeExe) { break }
    if ($attempt -lt 5) { Start-Sleep -Seconds 2 }
}
$diag += "result: $(if ($ClaudeExe) { $ClaudeExe } else { '(not found)' })"

# always keep this, success or failure - it is the only record of what a
# double-clicked start.bat actually saw, since its console window closes on exit
try {
    [IO.File]::WriteAllText((Join-Path $Root 'startup.log'), ($diag -join "`r`n"), [Text.Encoding]::UTF8)
} catch { }

if (-not $ClaudeExe) {
    Write-Host "ERROR: claude.exe not found." -ForegroundColor Red
    Write-Host "Checked under: $env:APPDATA, $env:LOCALAPPDATA, the Windows Store app's" -ForegroundColor Red
    Write-Host "packaged data folder, and every profile in C:\Users." -ForegroundColor Red
    Write-Host "If you launched this as a different/elevated Windows account, retry without" -ForegroundColor Red
    Write-Host "'Run as administrator' - that switches %APPDATA% to the other account's profile." -ForegroundColor Red
    Write-Host "Otherwise install Claude Code, or edit Find-ClaudeExe in server.ps1." -ForegroundColor Red
    Write-Host ""
    Write-Host "Details written to: $(Join-Path $Root 'startup.log')" -ForegroundColor Yellow
    exit 1
}


# --- load assets (explicit UTF-8, never the ANSI default) ------------------
$utf8 = New-Object System.Text.UTF8Encoding($false)

$promptsPath = Join-Path $Root 'prompts.json'
if (-not (Test-Path $promptsPath)) {
    Write-Host "ERROR: missing required file: $promptsPath" -ForegroundColor Red
    exit 1
}
$Prompts = [IO.File]::ReadAllText($promptsPath, $utf8) | ConvertFrom-Json

# pdftotext ships with Git for Windows; PDF import needs it for text extraction
function Find-Pdftotext {
    $cmd = Get-Command pdftotext -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    foreach ($p in @('C:\Program Files\Git\mingw64\bin\pdftotext.exe',
                     'C:\Program Files\Git\usr\bin\pdftotext.exe')) {
        if (Test-Path $p) { return $p }
    }
    return $null
}
$Pdftotext = Find-Pdftotext


# --- paper library ---------------------------------------------------------
# data\papers\<id>\{paper.pdf, paper.txt, meta.json}; data\active.json points
# at the paper currently loaded. The original single-paper layout
# (data\paper.pdf + data\paper.txt) is migrated in as id 'default' once.
$DataDir     = Join-Path $Root 'data'
$PapersDir   = Join-Path $DataDir 'papers'
$SessionsDir = Join-Path $DataDir 'sessions'
$ActiveFile  = Join-Path $DataDir 'active.json'
foreach ($d in @($DataDir, $PapersDir, $SessionsDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$legacyPdf  = Join-Path $DataDir 'paper.pdf'
$legacyTxt  = Join-Path $DataDir 'paper.txt'
$defaultDir = Join-Path $PapersDir 'default'
if ((Test-Path $legacyPdf) -and (Test-Path $legacyTxt) -and -not (Test-Path $defaultDir)) {
    New-Item -ItemType Directory -Path $defaultDir -Force | Out-Null
    Copy-Item $legacyPdf (Join-Path $defaultDir 'paper.pdf')
    Copy-Item $legacyTxt (Join-Path $defaultDir 'paper.txt')
    [IO.File]::WriteAllText((Join-Path $defaultDir 'meta.json'),
        (ConvertTo-Json @{ id = 'default'; title = 'Development of a Quadrotor Test Bed - Dong, Gu, Zhu, Ding (2015)' } -Compress),
        $utf8)
}

function Get-PaperEntry {
    param([string]$Id)
    $dir = Join-Path $PapersDir $Id
    $pdf = Join-Path $dir 'paper.pdf'
    $txt = Join-Path $dir 'paper.txt'
    if (-not ((Test-Path $pdf) -and (Test-Path $txt))) { return $null }
    $title = $Id
    $metaPath = Join-Path $dir 'meta.json'
    if (Test-Path $metaPath) {
        try {
            $m = [IO.File]::ReadAllText($metaPath, $utf8) | ConvertFrom-Json
            if ($m.title) { $title = [string]$m.title }
        } catch { }
    }
    return @{ Id = $Id; Title = $title; PdfPath = $pdf; TxtPath = $txt }
}

$activeId = 'default'
if (Test-Path $ActiveFile) {
    try {
        $a = [IO.File]::ReadAllText($ActiveFile, $utf8) | ConvertFrom-Json
        if ($a.paperId) { $activeId = [string]$a.paperId }
    } catch { }
}
$entry = Get-PaperEntry $activeId
if (-not $entry) {
    $entry = Get-ChildItem $PapersDir -Directory -ErrorAction SilentlyContinue |
             ForEach-Object { Get-PaperEntry $_.Name } |
             Where-Object { $_ } | Select-Object -First 1
}
# A fresh clone ships no papers at all - start anyway and let the user import
# one from the UI, rather than refusing to boot.
if (-not $entry) {
    $entry = @{ Id = ''; Title = ''; PdfPath = ''; TxtPath = '' }
    $paperText = ''
} else {
    $paperText = [IO.File]::ReadAllText($entry.TxtPath, $utf8)
}


# --- shared state across worker threads ------------------------------------
$State = [hashtable]::Synchronized(@{
    Root         = $Root
    ClaudeExe    = $ClaudeExe
    Pdftotext    = $Pdftotext
    PapersDir    = $PapersDir
    SessionsDir  = $SessionsDir
    ActiveFile   = $ActiveFile
    TranslateTpl = $Prompts.translate
    ChatSystem   = $Prompts.chat_system
    ChatHistHdr  = $Prompts.chat_turn_header
    ChatQHdr     = $Prompts.chat_question_header
    Active       = [hashtable]::Synchronized(@{
        Id = $entry.Id; Title = $entry.Title; PdfPath = $entry.PdfPath; Text = $paperText
    })
    Sessions     = [hashtable]::Synchronized(@{})
    Cache        = [hashtable]::Synchronized(@{})
    LogPath      = (Join-Path $Root 'server.log')
})


# --- request handler, runs in each worker runspace -------------------------
$WorkerScript = {
    param($Listener, $State)

    function Write-Log {
        param([string]$Message)
        try {
            $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
            [IO.File]::AppendAllText($State.LogPath, $line + "`r`n", [Text.Encoding]::UTF8)
        } catch { }
    }

    function Get-MimeType {
        param([string]$Path)
        switch ([IO.Path]::GetExtension($Path).ToLower()) {
            '.html' { 'text/html; charset=utf-8' }
            '.js'   { 'text/javascript; charset=utf-8' }
            '.mjs'  { 'text/javascript; charset=utf-8' }
            '.css'  { 'text/css; charset=utf-8' }
            '.json' { 'application/json; charset=utf-8' }
            '.pdf'  { 'application/pdf' }
            '.txt'  { 'text/plain; charset=utf-8' }
            default { 'application/octet-stream' }
        }
    }

    function Send-Bytes {
        param($Ctx, [byte[]]$Body, [string]$ContentType, [int]$Status = 200)
        try {
            $Ctx.Response.StatusCode      = $Status
            $Ctx.Response.ContentType     = $ContentType
            $Ctx.Response.ContentLength64 = $Body.Length
            $Ctx.Response.OutputStream.Write($Body, 0, $Body.Length)
        } catch {
        } finally {
            try { $Ctx.Response.OutputStream.Close() } catch { }
        }
    }

    function Send-Json {
        param($Ctx, $Obj, [int]$Status = 200)
        $text = ConvertTo-Json $Obj -Depth 12 -Compress
        Send-Bytes $Ctx ([Text.Encoding]::UTF8.GetBytes($text)) 'application/json; charset=utf-8' $Status
    }

    function Read-Body {
        param($Ctx)
        $reader = New-Object IO.StreamReader($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }

    # Runs the claude CLI once. The whole prompt goes through stdin as raw
    # UTF-8 bytes: it dodges the ~32k command-line limit and every codepage
    # problem that comes with passing Korean text as an argument.
    # Whitelists for values that flow in from client JSON and end up in a
    # process command line - reject anything unexpected instead of quoting it.
    $AllowedModels  = @('sonnet', 'opus', 'haiku', 'fable')
    $AllowedEfforts = @('low', 'medium', 'high', 'xhigh', 'max')

    function Invoke-Claude {
        param([string]$Prompt, [int]$TimeoutSec = 300, [string]$Model = 'sonnet', [string]$Effort = 'medium')

        if ($AllowedModels  -notcontains $Model)  { $Model  = 'sonnet' }
        if ($AllowedEfforts -notcontains $Effort) { $Effort = 'medium' }

        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName               = $State.ClaudeExe
        $psi.Arguments              = "-p --safe-mode --model $Model --effort $Effort --tools `"`" --no-session-persistence --output-format json"
        $psi.WorkingDirectory       = $State.Root
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.StandardErrorEncoding  = [Text.Encoding]::UTF8

        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()

        $bytes = [Text.Encoding]::UTF8.GetBytes($Prompt)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()

        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            return @{ ok = $false; error = "claude timed out after ${TimeoutSec}s" }
        }

        $raw = $outTask.Result
        $err = $errTask.Result

        # --output-format json prints one JSON object; slice it out in case
        # anything else leaks onto stdout.
        $i = $raw.IndexOf('{')
        $j = $raw.LastIndexOf('}')
        if ($i -lt 0 -or $j -le $i) {
            Write-Log "claude produced no JSON. exit=$($proc.ExitCode) err=$err raw=$raw"
            $msg = 'claude returned no output'
            if ($err) { $msg = $err.Trim() }
            return @{ ok = $false; error = $msg }
        }

        try {
            $json = $raw.Substring($i, $j - $i + 1) | ConvertFrom-Json
        } catch {
            Write-Log "unparsable claude output: $raw"
            return @{ ok = $false; error = 'could not parse claude output' }
        }

        if ($json.is_error -or $json.subtype -ne 'success') {
            $detail = $json.result
            if (-not $detail) { $detail = $json.subtype }
            Write-Log "claude reported an error: $detail"
            return @{ ok = $false; error = [string]$detail }
        }

        return @{ ok = $true; text = [string]$json.result; cost = $json.total_cost_usd }
    }

    # --- sessions: in-memory, mirrored to data\sessions\<key>.json ----------
    function Test-SessionKey { param([string]$Key) return ($Key -match '^[A-Za-z0-9_-]{1,64}$') }
    function Get-SessionPath { param([string]$Key) Join-Path $State.SessionsDir ($Key + '.json') }

    # Returns @{ meta; turns } for the key, loading it from disk on first
    # touch. Monitor is reentrant, so callers may hold the same lock already.
    function Get-Session {
        param([string]$Key)
        $s = $State.Sessions
        [System.Threading.Monitor]::Enter($s.SyncRoot)
        try {
            if (-not $s.ContainsKey($Key)) {
                $entry = @{ meta = $null; turns = New-Object Collections.ArrayList }
                $file = Get-SessionPath $Key
                if (Test-Path $file) {
                    try {
                        $j = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8) | ConvertFrom-Json
                        $entry.meta = @{
                            title      = [string]$j.title
                            created    = [string]$j.created
                            updated    = [string]$j.updated
                            paperId    = [string]$j.paperId
                            paperTitle = [string]$j.paperTitle
                        }
                        foreach ($t in $j.turns) {
                            [void]$entry.turns.Add(@{ role = [string]$t.role; text = [string]$t.text })
                        }
                    } catch { }
                }
                $s[$Key] = $entry
            }
            return $s[$Key]
        } finally { [System.Threading.Monitor]::Exit($s.SyncRoot) }
    }

    function Add-Turn {
        param([string]$Key, [string]$Role, [string]$Text)
        $s = $State.Sessions
        [System.Threading.Monitor]::Enter($s.SyncRoot)
        try {
            $entry = Get-Session $Key
            if (-not $entry.meta) {
                $title = ($Text -replace '\s+', ' ').Trim()
                if ($title.Length -gt 44) { $title = $title.Substring(0, 44) + '...' }
                $entry.meta = @{
                    title      = $title
                    created    = (Get-Date).ToString('o')
                    updated    = (Get-Date).ToString('o')
                    paperId    = [string]$State.Active.Id
                    paperTitle = [string]$State.Active.Title
                }
            }
            $entry.meta.updated = (Get-Date).ToString('o')
            [void]$entry.turns.Add(@{ role = $Role; text = $Text })

            $doc = @{
                key        = $Key
                title      = $entry.meta.title
                created    = $entry.meta.created
                updated    = $entry.meta.updated
                paperId    = $entry.meta.paperId
                paperTitle = $entry.meta.paperTitle
                turns      = @($entry.turns.ToArray())
            }
            try {
                [IO.File]::WriteAllText((Get-SessionPath $Key), (ConvertTo-Json $doc -Depth 6 -Compress), [Text.Encoding]::UTF8)
            } catch { }
        } finally { [System.Threading.Monitor]::Exit($s.SyncRoot) }
    }

    function Get-SessionList {
        $items = @()
        Get-ChildItem $State.SessionsDir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $j = [IO.File]::ReadAllText($_.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $items += @{
                    key        = [string]$j.key
                    title      = [string]$j.title
                    updated    = [string]$j.updated
                    paperId    = [string]$j.paperId
                    paperTitle = [string]$j.paperTitle
                    turns      = @($j.turns).Count
                }
            } catch { }
        }
        return @($items | Sort-Object { $_.updated } -Descending)
    }

    # --- paper library helpers ----------------------------------------------
    function Get-PaperList {
        $items = @()
        Get-ChildItem $State.PapersDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $pdf = Join-Path $_.FullName 'paper.pdf'
            $txt = Join-Path $_.FullName 'paper.txt'
            if ((Test-Path $pdf) -and (Test-Path $txt)) {
                $title = $_.Name
                $metaPath = Join-Path $_.FullName 'meta.json'
                if (Test-Path $metaPath) {
                    try {
                        $m = [IO.File]::ReadAllText($metaPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                        if ($m.title) { $title = [string]$m.title }
                    } catch { }
                }
                $items += @{ id = $_.Name; title = $title; active = ($_.Name -eq [string]$State.Active.Id) }
            }
        }
        return @($items | Sort-Object { $_.id })
    }

    function Set-ActivePaper {
        param([string]$Id)
        if ($Id -notmatch '^[A-Za-z0-9_-]{1,64}$') { return $false }
        $dir = Join-Path $State.PapersDir $Id
        $pdf = Join-Path $dir 'paper.pdf'
        $txt = Join-Path $dir 'paper.txt'
        if (-not ((Test-Path $pdf) -and (Test-Path $txt))) { return $false }
        $title = $Id
        $metaPath = Join-Path $dir 'meta.json'
        if (Test-Path $metaPath) {
            try {
                $m = [IO.File]::ReadAllText($metaPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($m.title) { $title = [string]$m.title }
            } catch { }
        }
        $text = [IO.File]::ReadAllText($txt, [Text.Encoding]::UTF8)
        $a = $State.Active
        [System.Threading.Monitor]::Enter($a.SyncRoot)
        try {
            $a.Id = $Id; $a.Title = $title; $a.PdfPath = $pdf; $a.Text = $text
        } finally { [System.Threading.Monitor]::Exit($a.SyncRoot) }
        try {
            [IO.File]::WriteAllText($State.ActiveFile, (ConvertTo-Json @{ paperId = $Id } -Compress), [Text.Encoding]::UTF8)
        } catch { }
        return $true
    }

    function Read-BodyBytes {
        param($Ctx)
        $ms = New-Object IO.MemoryStream
        $Ctx.Request.InputStream.CopyTo($ms)
        return $ms.ToArray()
    }

    # Saves the uploaded PDF under an ASCII-safe id, extracts page-marked text
    # with pdftotext, and switches the active paper to it. The original
    # (possibly Korean) filename only ever lands inside UTF-8 meta.json, never
    # on a command line - Korean paths through cmdline encoding broke before.
    function Import-Paper {
        param([byte[]]$Bytes, [string]$OriginalName)
        if (-not $State.Pdftotext) {
            return @{ ok = $false; error = 'pdftotext not found (install Git for Windows)' }
        }
        if (-not $Bytes -or $Bytes.Length -lt 1024) { return @{ ok = $false; error = 'file too small or empty' } }
        if ($Bytes.Length -gt 200MB) { return @{ ok = $false; error = 'file larger than 200MB' } }
        $sig = [Text.Encoding]::ASCII.GetString($Bytes, 0, [Math]::Min(5, $Bytes.Length))
        if ($sig -ne '%PDF-') { return @{ ok = $false; error = 'not a PDF file' } }

        $id  = 'p' + (Get-Date -Format 'yyyyMMddHHmmss')
        $dir = Join-Path $State.PapersDir $id
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $pdf = Join-Path $dir 'paper.pdf'
        [IO.File]::WriteAllBytes($pdf, $Bytes)

        $rawTxt = Join-Path $dir 'raw.txt'
        $psi = New-Object Diagnostics.ProcessStartInfo
        $psi.FileName               = $State.Pdftotext
        $psi.Arguments              = '-enc UTF-8 "' + $pdf + '" "' + $rawTxt + '"'
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true
        $psi.RedirectStandardError  = $true
        $proc = New-Object Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(120000)) {
            try { $proc.Kill() } catch { }
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            return @{ ok = $false; error = 'pdftotext timed out' }
        }
        if ($proc.ExitCode -ne 0 -or -not (Test-Path $rawTxt)) {
            $err = $errTask.Result
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            return @{ ok = $false; error = ('text extraction failed: ' + ([string]$err).Trim()) }
        }

        $t = [IO.File]::ReadAllText($rawTxt, [Text.Encoding]::UTF8)
        $pages = $t -split [string][char]12
        $sb = New-Object Text.StringBuilder
        $n = 0
        for ($i = 0; $i -lt $pages.Count; $i++) {
            $body = $pages[$i].Trim()
            if ($body.Length -eq 0 -and $i -eq $pages.Count - 1) { continue }
            $n++
            [void]$sb.AppendLine('===== [p.' + $n + '] =====')
            [void]$sb.AppendLine($body)
            [void]$sb.AppendLine()
        }
        [IO.File]::WriteAllText((Join-Path $dir 'paper.txt'), $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
        Remove-Item $rawTxt -Force -ErrorAction SilentlyContinue

        $title = $id
        if ($OriginalName) {
            try { $title = [IO.Path]::GetFileNameWithoutExtension($OriginalName) } catch { }
            if (-not $title) { $title = $id }
        }
        [IO.File]::WriteAllText((Join-Path $dir 'meta.json'),
            (ConvertTo-Json @{ id = $id; title = $title } -Compress), [Text.Encoding]::UTF8)

        [void](Set-ActivePaper $id)
        return @{ ok = $true; id = $id; title = $title; pages = $n }
    }

    # --- main accept loop --------------------------------------------------
    while ($true) {
        $ctx = $null
        try { $ctx = $Listener.GetContext() } catch { break }
        if (-not $ctx) { break }

        try {
            $req    = $ctx.Request
            $path   = $req.Url.AbsolutePath
            $method = $req.HttpMethod

            if ($path -eq '/') { $path = '/index.html' }

            # ---- API -----------------------------------------------------
            if ($path -eq '/api/health') {
                Send-Json $ctx @{ ok = $true; claude = $State.ClaudeExe }
                continue
            }

            if ($path -eq '/api/state') {
                $pid_ = [string]$State.Active.Id
                Send-Json $ctx @{
                    ok        = $true
                    paper     = $(if ($pid_) { @{ id = $pid_; title = [string]$State.Active.Title } } else { $null })
                    canImport = [bool]$State.Pdftotext
                }
                continue
            }

            if ($path -eq '/api/papers' -and $method -eq 'GET') {
                Send-Json $ctx @{ ok = $true; papers = @(Get-PaperList) }
                continue
            }

            if ($path -eq '/api/paper/activate' -and $method -eq 'POST') {
                $body = Read-Body $ctx | ConvertFrom-Json
                if (Set-ActivePaper ([string]$body.id)) { Send-Json $ctx @{ ok = $true } }
                else { Send-Json $ctx @{ ok = $false; error = 'unknown paper id' } 400 }
                continue
            }

            if ($path -eq '/api/paper/import' -and $method -eq 'POST') {
                $bytes = Read-BodyBytes $ctx
                $name  = ''
                $enc   = [string]$req.Headers['X-File-Name']
                if ($enc) { try { $name = [Uri]::UnescapeDataString($enc) } catch { } }
                if (-not $name) { $name = [string]$req.QueryString['name'] }
                $res = Import-Paper $bytes $name
                if ($res.ok) { Send-Json $ctx $res } else { Send-Json $ctx $res 500 }
                continue
            }

            if ($path -eq '/api/sessions' -and $method -eq 'GET') {
                Send-Json $ctx @{ ok = $true; sessions = @(Get-SessionList) }
                continue
            }

            if ($path -eq '/api/session' -and $method -eq 'GET') {
                $key = [string]$req.QueryString['key']
                if (-not (Test-SessionKey $key)) {
                    Send-Json $ctx @{ ok = $false; error = 'bad session key' } 400
                    continue
                }
                $entry = Get-Session $key
                $meta  = $entry.meta
                Send-Json $ctx @{
                    ok      = $true
                    exists  = [bool]$meta
                    paperId = $(if ($meta) { [string]$meta.paperId } else { '' })
                    title   = $(if ($meta) { [string]$meta.title } else { '' })
                    turns   = @($entry.turns.ToArray())
                }
                continue
            }

            if ($path -eq '/api/session/delete' -and $method -eq 'POST') {
                $body = Read-Body $ctx | ConvertFrom-Json
                $key  = [string]$body.key
                if (-not (Test-SessionKey $key)) {
                    Send-Json $ctx @{ ok = $false; error = 'bad session key' } 400
                    continue
                }
                $s = $State.Sessions
                [System.Threading.Monitor]::Enter($s.SyncRoot)
                try { $s.Remove($key) } finally { [System.Threading.Monitor]::Exit($s.SyncRoot) }
                Remove-Item (Get-SessionPath $key) -Force -ErrorAction SilentlyContinue
                Send-Json $ctx @{ ok = $true }
                continue
            }

            if ($path -eq '/api/translate' -and $method -eq 'POST') {
                $body = Read-Body $ctx | ConvertFrom-Json
                $text = [string]$body.text
                if (-not $text -or $text.Trim().Length -eq 0) {
                    Send-Json $ctx @{ ok = $false; error = 'empty selection' } 400
                    continue
                }
                if ($text.Length -gt 20000) { $text = $text.Substring(0, 20000) }

                $cacheKey = $text.Trim()
                if ($State.Cache.ContainsKey($cacheKey)) {
                    Send-Json $ctx @{ ok = $true; text = $State.Cache[$cacheKey]; cached = $true }
                    continue
                }

                $paperTitle = [string]$State.Active.Title
                if (-not $paperTitle) { $paperTitle = '(제목 미상)' }
                $prompt = $State.TranslateTpl.Replace('{{PAPER_TITLE}}', $paperTitle).Replace('{{TEXT}}', $text)
                $res = Invoke-Claude $prompt 180
                if ($res.ok) {
                    $State.Cache[$cacheKey] = $res.text
                    Send-Json $ctx @{ ok = $true; text = $res.text; cost = $res.cost }
                } else {
                    Send-Json $ctx @{ ok = $false; error = $res.error } 500
                }
                continue
            }

            if ($path -eq '/api/chat' -and $method -eq 'POST') {
                $body   = Read-Body $ctx | ConvertFrom-Json
                $key    = [string]$body.sessionKey
                $msg    = [string]$body.message
                $model  = [string]$body.model
                $effort = [string]$body.effort
                if (-not $key)    { $key    = 'default' }
                if (-not $model)  { $model  = 'sonnet' }
                if (-not $effort) { $effort = 'medium' }
                if (-not $msg -or $msg.Trim().Length -eq 0) {
                    Send-Json $ctx @{ ok = $false; error = 'empty message' } 400
                    continue
                }

                # deeper effort levels think a lot longer over a 17k-token paper
                $timeout = switch ($effort) {
                    'xhigh' { 600 }
                    'max'   { 720 }
                    'high'  { 450 }
                    default { 300 }
                }

                if (-not (Test-SessionKey $key)) {
                    Send-Json $ctx @{ ok = $false; error = 'bad session key' } 400
                    continue
                }
                if (-not [string]$State.Active.Id) {
                    Send-Json $ctx @{ ok = $false; error = '먼저 상단 [논문] 메뉴에서 PDF를 가져오세요.' } 400
                    continue
                }

                # The CLI's own --resume did not carry context in print mode,
                # so the conversation is rebuilt here on every turn instead.
                $sb = New-Object Text.StringBuilder
                [void]$sb.Append($State.ChatSystem.Replace('{{PAPER}}', [string]$State.Active.Text))
                [void]$sb.AppendLine()

                # full history persists on disk; only the tail rides the prompt
                $hist = @((Get-Session $key).turns.ToArray())
                if ($hist.Count -gt 32) { $hist = @($hist[($hist.Count - 32)..($hist.Count - 1)]) }
                if ($hist.Count -gt 0) {
                    [void]$sb.AppendLine()
                    [void]$sb.Append($State.ChatHistHdr)
                    foreach ($h in $hist) {
                        $who = 'USER'
                        if ($h.role -eq 'assistant') { $who = 'ASSISTANT' }
                        [void]$sb.AppendLine("<$who>")
                        [void]$sb.AppendLine($h.text)
                        [void]$sb.AppendLine("</$who>")
                    }
                }

                [void]$sb.Append($State.ChatQHdr)
                [void]$sb.AppendLine($msg)

                $res = Invoke-Claude $sb.ToString() $timeout $model $effort
                if ($res.ok) {
                    Add-Turn $key 'user' $msg
                    Add-Turn $key 'assistant' $res.text
                    Send-Json $ctx @{ ok = $true; text = $res.text; cost = $res.cost }
                } else {
                    Send-Json $ctx @{ ok = $false; error = $res.error } 500
                }
                continue
            }

            if ($path -eq '/api/chat/reset' -and $method -eq 'POST') {
                $body = Read-Body $ctx | ConvertFrom-Json
                $key  = [string]$body.sessionKey
                if (-not $key) { $key = 'default' }
                $s = $State.Sessions
                [System.Threading.Monitor]::Enter($s.SyncRoot)
                try { $s.Remove($key) } finally { [System.Threading.Monitor]::Exit($s.SyncRoot) }
                Send-Json $ctx @{ ok = $true }
                continue
            }

            # ---- static files --------------------------------------------
            if ($method -ne 'GET') {
                Send-Json $ctx @{ ok = $false; error = 'not found' } 404
                continue
            }

            $rel = $path.TrimStart('/')
            if ($rel.Contains('..')) {
                Send-Json $ctx @{ ok = $false; error = 'bad path' } 400
                continue
            }

            if ($rel -eq 'paper.pdf') {
                $file = [string]$State.Active.PdfPath
            } elseif ($rel -like 'vendor/*') {
                $file = Join-Path $State.Root ($rel -replace '/', '\')
            } else {
                $file = Join-Path $State.Root ('web\' + ($rel -replace '/', '\'))
            }

            if (-not (Test-Path $file -PathType Leaf)) {
                Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes('404 not found')) 'text/plain; charset=utf-8' 404
                continue
            }

            $ctx.Response.Headers.Add('Cache-Control', 'no-store')
            Send-Bytes $ctx ([IO.File]::ReadAllBytes($file)) (Get-MimeType $file)
        }
        catch {
            Write-Log "handler error: $($_.Exception.Message)"
            try { Send-Json $ctx @{ ok = $false; error = $_.Exception.Message } 500 } catch { }
        }
    }
}


# --- start listening -------------------------------------------------------
$listener = New-Object Net.HttpListener
$bound    = $false
for ($p = $Port; $p -lt ($Port + 20); $p++) {
    try {
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add("http://127.0.0.1:$p/")
        $listener.Start()
        $Port  = $p
        $bound = $true
        break
    } catch {
        $listener = New-Object Net.HttpListener
    }
}
if (-not $bound) {
    Write-Host "ERROR: could not bind a port in range $Port..$($Port+19)." -ForegroundColor Red
    exit 1
}

$url = "http://127.0.0.1:$Port/"

Write-Host ''
Write-Host '  Paper Reader' -ForegroundColor Cyan
Write-Host '  ------------'
Write-Host "  claude : $ClaudeExe"
if ([string]$State.Active.Id) {
    Write-Host "  paper  : $($State.Active.Title) ($([int](([string]$State.Active.Text).Length / 1000))k chars)"
} else {
    Write-Host "  paper  : none yet - import a PDF from the [paper] menu in the UI" -ForegroundColor Yellow
}
Write-Host "  import : $(if ($Pdftotext) { 'pdftotext OK' } else { 'pdftotext NOT FOUND - PDF import disabled' })"
Write-Host "  url    : $url" -ForegroundColor Green
Write-Host ''
Write-Host '  Leave this window open while you read. Ctrl+C stops the server.'
Write-Host ''

$threads = @()
for ($i = 0; $i -lt $Workers; $i++) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($WorkerScript.ToString()).AddArgument($listener).AddArgument($State)
    $threads += [pscustomobject]@{ PS = $ps; Handle = $ps.BeginInvoke(); RS = $rs }
}

if (-not $NoBrowser) { Start-Process $url | Out-Null }

try {
    while ($listener.IsListening) { Start-Sleep -Seconds 1 }
}
finally {
    Write-Host 'stopping...'
    try { $listener.Stop() }  catch { }
    try { $listener.Close() } catch { }
    foreach ($t in $threads) {
        try { $t.PS.Stop() }     catch { }
        try { $t.PS.Dispose() }  catch { }
        try { $t.RS.Dispose() }  catch { }
    }
}
