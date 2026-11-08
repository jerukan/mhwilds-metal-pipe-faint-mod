<#
  Builds the Metal Pipe faint-sound mod for Monster Hunter Wilds.

  Replaces voice lines in hunter voice banks (natives/STM/Sound/Wwise/*.sbnk.1.X64.En).
  Which media IDs to replace comes from every voiceline-ids-*.txt next to this script, in the form:
       Player_ActVoice_M01.sbnk.1.X64.En
       - 3919603
       - 30638291
  i.e. a bank file name line followed by "- <id>" lines. Lists for the same bank are merged.
    voiceline-ids-faint.txt    multiplayer faint lines (from the "Fah Faint Chat Team EN" mod)
    voiceline-ids-heavyhit.txt heavy-hit grunts

  A .sbnk here is a plain Wwise .bnk: BKHD (header) + DIDX (id/offset/size table) + DATA (concatenated .wem).
  We decode the mp3 with ffmpeg, wrap it in a Wwise PCM .wem header (stereo, same layout as the
  Fah mod), swap it into the target slots, and rewrite the DIDX offsets/sizes. No Wwise install needed.

  Base banks: vanilla files from reference\natives\STM\Sound\Wwise\ when present,
  otherwise the Fah mod's banks (only its faint slots differ from vanilla, and we overwrite those).

  Requires: ffmpeg on PATH.

  Usage:
    powershell -ExecutionPolicy Bypass -File build.ps1 [-Mp3 <path>] [-RefDir <path>] [-SampleRate <int>]
                                                       [-GainDb <double>] [-OutDir <path>]

  Parameters (all optional):
    -Mp3         Sound to insert. Default: examples\metal pipe falling sound effect [iDLmYZ5HqgM].mp3
    -RefDir      Folder holding the vanilla .sbnk banks. Default: reference\natives\STM\Sound\Wwise
    -SampleRate  Output sample rate in Hz. Default: 48000 (matches the game's voice banks)
    -GainDb      Volume change in dB, e.g. 6 = louder, -6 = quieter. Default: 0
    -OutDir      Mod folder to write; <OutDir>.zip is created next to it. Default: Metal Pipe Faint

  Examples:
    powershell -ExecutionPolicy Bypass -File build.ps1
    powershell -ExecutionPolicy Bypass -File build.ps1 -GainDb -4
    powershell -ExecutionPolicy Bypass -File build.ps1 -Mp3 "C:\sounds\bonk.mp3" -OutDir "C:\mods\Bonk Faint"

  Output: <OutDir>\modinfo.ini + <OutDir>\natives\STM\Sound\Wwise\<bank>, zipped for Fluffy Mod Manager.
#>
param(
    [string]$Mp3      = "$PSScriptRoot\metal pipe falling sound effect [iDLmYZ5HqgM].mp3",
    [string]$RefDir   = "$PSScriptRoot\reference\natives\STM\Sound\Wwise",
    [int]$SampleRate  = 48000,
    [double]$GainDb   = 0,
    [string]$OutDir   = "$PSScriptRoot\Metal Pipe Faint"
)
$ErrorActionPreference = 'Stop'
$ascii = [Text.Encoding]::ASCII
$FahDir = "$PSScriptRoot\reference\natives\STM\Sound\Wwise"

function U32([byte[]]$b, [int]$o) { [BitConverter]::ToUInt32($b, $o) }

# ---------- mp3 -> Wwise PCM .wem (stereo WAVE_FORMAT_EXTENSIBLE, as in the Fah mod) ----------
function New-Wem([string]$mp3) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "metalpipe_$PID.pcm"
    & ffmpeg -v error -y -i $mp3 -af "volume=${GainDb}dB" -ac 2 -ar $SampleRate -f s16le -acodec pcm_s16le $tmp
    if ($LASTEXITCODE -ne 0) { throw "ffmpeg failed on $mp3" }
    $pcm = [IO.File]::ReadAllBytes($tmp); Remove-Item $tmp

    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $w.Write($ascii.GetBytes('RIFF')); $w.Write([uint32]0)        # size patched below
    $w.Write($ascii.GetBytes('WAVE'))
    $w.Write($ascii.GetBytes('fmt ')); $w.Write([uint32]40)
    $w.Write([uint16]0xFFFE); $w.Write([uint16]2); $w.Write([uint32]$SampleRate)
    $w.Write([uint32]($SampleRate * 4)); $w.Write([uint16]4); $w.Write([uint16]16)
    $w.Write([uint16]22); $w.Write([uint16]16); $w.Write([uint32]3)          # cbSize, valid bits, FL|FR
    $w.Write(([guid]'00000001-0000-0010-8000-00aa00389b71').ToByteArray()) # KSDATAFORMAT_SUBTYPE_PCM
    $w.Write($ascii.GetBytes('JUNK')); $w.Write([uint32]4); $w.Write([uint32]0)
    $w.Write($ascii.GetBytes('data')); $w.Write([uint32]$pcm.Length); $w.Write($pcm)
    $w.Flush(); $wem = $ms.ToArray()
    [BitConverter]::GetBytes([uint32]($wem.Length - 8)).CopyTo($wem, 4)
    Write-Host ("Encoded {0}: {1:N2}s, {2} bytes" -f (Split-Path $mp3 -Leaf), ($pcm.Length / 4 / $SampleRate), $wem.Length)
    return ,$wem
}

# ---------- bank rebuild ----------
function Rebuild-Bank([string]$basePath, [uint32[]]$ids, [byte[]]$wem) {
    $b = [IO.File]::ReadAllBytes($basePath)
    $chunks = [ordered]@{}; $i = 0
    while ($i -lt $b.Length) {
        $tag = $ascii.GetString($b, $i, 4); $len = U32 $b ($i + 4)
        $chunks[$tag] = @{ Off = $i + 8; Len = $len }; $i += 8 + $len
    }
    if (($chunks.Keys -join ',') -ne 'BKHD,DIDX,DATA') { throw "Unexpected chunks in ${basePath}: $($chunks.Keys -join ',')" }

    $didx = $chunks['DIDX']; $data = $chunks['DATA']
    $entries = for ($k = 0; $k -lt $didx.Len / 12; $k++) {
        $o = $didx.Off + $k * 12
        $id = U32 $b $o; $off = U32 $b ($o + 4); $sz = U32 $b ($o + 8)
        $bytes = New-Object byte[] $sz; [Array]::Copy($b, $data.Off + $off, $bytes, 0, $sz)
        [pscustomobject]@{ Id = $id; Bytes = $bytes }
    }
    foreach ($id in $ids) {
        $e = $entries | Where-Object Id -eq $id
        if (-not $e) { throw "Media ID $id not found in $basePath" }
        $e.Bytes = $wem
    }

    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
    $bk = $chunks['BKHD']; $w.Write($b, $bk.Off - 8, $bk.Len + 8)     # BKHD verbatim
    $w.Write($ascii.GetBytes('DIDX')); $w.Write([uint32]($entries.Count * 12))
    $off = 0
    foreach ($e in $entries) { $w.Write([uint32]$e.Id); $w.Write([uint32]$off); $w.Write([uint32]$e.Bytes.Length); $off += $e.Bytes.Length }
    $w.Write($ascii.GetBytes('DATA')); $w.Write([uint32]$off)
    foreach ($e in $entries) { $w.Write($e.Bytes) }
    $w.Flush(); return ,$ms.ToArray()
}

# ---------- targets ----------
$wem = New-Wem $Mp3

# Read every voiceline-ids-*.txt: a bank file name line, then "- <id>" lines. Same-bank lists merge.
$BankIds = [ordered]@{}
foreach ($list in Get-ChildItem $PSScriptRoot -Filter 'voiceline-ids-*.txt' | Sort-Object Name) {
    $bank = $null; $n = 0
    foreach ($line in Get-Content $list.FullName) {
        $line = $line.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }
        if ($line -match '^-\s*(\d+)$') {
            if (-not $bank) { throw "$($list.Name): ID '$line' appears before any bank name" }
            $BankIds[$bank].Add([uint32]$Matches[1]) | Out-Null; $n++
        } elseif ($line -match '^[\w.]+$') {
            $bank = $line
            if (-not $BankIds.Contains($bank)) { $BankIds[$bank] = New-Object 'System.Collections.Generic.HashSet[uint32]' }
        } else { throw "$($list.Name): can't parse line '$line'" }
    }
    Write-Host ("Loaded {0}: {1} IDs" -f $list.Name, $n)
}
if ($BankIds.Count -eq 0) { throw "No voiceline-ids-*.txt lists found next to build.ps1" }
$Jobs = @(foreach ($name in $BankIds.Keys) {
    @{ Name = $name; Ids = [uint32[]]@($BankIds[$name]); Fallback = $FahDir; FallbackLabel = 'Fah mod' }
})

# ---------- write Fluffy Mod Manager layout ----------
if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
$wwiseDir = Join-Path $OutDir 'natives\STM\Sound\Wwise'
New-Item -ItemType Directory -Force $wwiseDir | Out-Null

foreach ($job in $Jobs) {
    $base = Join-Path $RefDir $job.Name; $src = 'vanilla'
    if (-not (Test-Path -LiteralPath $base)) { $base = Join-Path $job.Fallback $job.Name; $src = $job.FallbackLabel }
    if (-not (Test-Path -LiteralPath $base)) { throw "No base bank found for $($job.Name) (put the vanilla file in $RefDir)" }
    $bank = Rebuild-Bank $base $job.Ids $wem
    [IO.File]::WriteAllBytes((Join-Path $wwiseDir $job.Name), $bank)
    Write-Host ("  {0}: replaced {1} entries (base: {2})" -f $job.Name, $job.Ids.Count, $src)
}

@"
name=Metal Pipe Faint
version=v1.0
description=Replaces the faint and heavy-hit voice lines (English) with the metal pipe falling sound effect
"@ | Set-Content -Encoding ascii (Join-Path $OutDir 'modinfo.ini')

# Build the zip by hand: PS 5.1's Compress-Archive writes backslash paths and bare directory
# entries ("natives\"), which Fluffy Mod Manager tries to copy as files and fails on.
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = "$OutDir.zip"
if (Test-Path $zip) { Remove-Item $zip }
$root = Split-Path $OutDir -Parent
$archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    Get-ChildItem $OutDir -Recurse -File | ForEach-Object {
        $entry = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry) | Out-Null
    }
} finally { $archive.Dispose() }
Write-Host "Built: $OutDir"
Write-Host "Zip:   $zip  (drag into Fluffy Mod Manager)"
