Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# Use only this Windows PowerShell host's built-in modules. A parent pwsh process
# can otherwise pass incompatible PowerShell 7 modules through PSModulePath.
$env:PSModulePath = Join-Path $PSHOME 'Modules'
$script:AppRoot = $PSScriptRoot
$script:AppVersion = '3.0.0'
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)

function Write-JsonFile($Path, $Value) {
    $text = ConvertTo-Json -InputObject $Value -Depth 30
    [IO.File]::WriteAllText($Path, $text, $script:Utf8)
}

function Read-SafeXml([string]$Path) {
    $settings = New-Object Xml.XmlReaderSettings
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try { $doc = New-Object Xml.XmlDocument; $doc.XmlResolver = $null; $doc.Load($reader); return ,$doc }
    finally { $reader.Dispose() }
}

function Get-ContainedPath($Root, $Relative) {
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath $Relative))
    if (!$path.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Path escapes source folder: $Relative" }
    return $path
}

function Get-PeArchitecture($Path) {
    $f = [IO.File]::OpenRead($Path); $r = New-Object IO.BinaryReader($f)
    try {
        $f.Position = 60; $offset = $r.ReadInt32(); $f.Position = $offset
        if ($r.ReadUInt32() -ne 17744) { throw "Invalid PE file: $Path" }
        switch ($r.ReadUInt16()) { 332 { return 'x86' }; 34404 { return 'x64' }; default { throw "Unsupported architecture: $Path" } }
    } finally { $r.Dispose() }
}

function Get-PowerShellHost([string]$Architecture = 'x64') {
    if ($Architecture -eq 'x86') { return "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" }
    if ([Environment]::Is64BitOperatingSystem -and ![Environment]::Is64BitProcess) { return "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" }
    return "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Get-SourceCameras([string]$Folder) {
    $Folder = (Get-Item -LiteralPath $Folder).FullName
    $projects = @(Get-ChildItem -LiteralPath $Folder -Filter '*.scp' -Recurse -File -ErrorAction Stop)
    if (!$projects.Count) { throw 'No Milestone .scp project found. Select the complete exported folder, including Client Files.' }
    foreach ($project in $projects) {
        $doc = Read-SafeXml $project.FullName
        $dataRoot = Join-Path $project.DirectoryName 'Data'
        $client = Join-Path $project.DirectoryName 'Client\bin'
        if (!(Test-Path -LiteralPath (Join-Path $client 'VideoOS.Toolkit.dll'))) { throw "Player Toolkit missing beside $($project.FullName). Copy the complete original export." }
        foreach ($recorder in $doc.SelectNodes('//OfflineRecorderInfo')) {
            foreach ($camera in $recorder.SelectNodes('./Cameras/OfflineCameraInfo')) {
                $source = @($recorder.SelectNodes('./OfflineSources/OfflineSourceInfo') | Where-Object { $_.SourceId -eq $camera.SourceId })
                if ($source.Count -ne 1 -or $source[0].DatabaseType -ne 'MediaStorage') { throw 'Unsupported or ambiguous offline database type.' }
                if ($camera.CameraSecurity.ExportAvi -ne 'true') { throw "Export is not permitted for camera $($camera.Name)." }
                $bank = Get-ContainedPath $dataRoot ([string]$source[0].BankPath)
                $cache = Read-SafeXml (Join-Path $bank 'cache.xml')
                $table = [string]$source[0].TableName
                if (!$table) { throw 'Missing database table identifier.' }
                $tableNode = @($cache.SelectNodes('/bank/table') | Where-Object { $_.name -eq $table })
                if ($tableNode.Count -ne 1) { throw "Database cache does not identify table $table." }
                $media = @($tableNode[0].SelectNodes('./column') | Where-Object { $_.type -eq 'master' })
                if ($media.Count -ne 1) { throw 'Unsupported media column layout.' }
                $mediaDir = Get-ContainedPath $bank ($table + '\' + [string]$media[0].name)
                if (!(Test-Path -LiteralPath (Join-Path $mediaDir 'cindex.idx'))) { throw 'Missing database index.' }
                $blocks = @(Get-ChildItem -LiteralPath $mediaDir -Filter '*.blk' -File)
                if (!$blocks.Count) { throw 'No .blk video records found.' }
                $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
                [pscustomobject]@{
                    Source = $Folder; Project = $project.FullName; Bank = $bank; Table = $table
                    CameraId = [string]$camera.DeviceId; Camera = [string]$camera.Name; Toolkit = $client
                    Architecture = Get-PeArchitecture (Join-Path $client 'VideoOS.Toolkit.dll')
                    BeginUtc = $epoch.AddMilliseconds([double]$media[0].begin_time).ToString('o')
                    EndUtc = $epoch.AddMilliseconds([double]$media[0].end_time).ToString('o')
                    Bytes = [long](($blocks | Measure-Object Length -Sum).Sum)
                }
            }
        }
    }
}

function Initialize-Toolkit($Directory) {
    if (('PortableVideo.Bridge' -as [type])) { return }
    # A job is isolated in its own process. Never change the machine or user's PATH.
    Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class NativeSearch { [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool SetDllDirectory(string path); }'
    if (![NativeSearch]::SetDllDirectory($Directory)) { throw 'Cannot set the process-local native DLL directory.' }
    $dll = Join-Path $Directory 'VideoOS.Toolkit.dll'
    [Reflection.Assembly]::LoadFrom($dll) | Out-Null
    Add-Type -Path (Join-Path $script:AppRoot 'ToolkitBridge.cs') -ReferencedAssemblies $dll -ErrorAction Stop
}

function Test-Cancel($CancelPath) { if ($CancelPath -and (Test-Path -LiteralPath $CancelPath)) { throw [OperationCanceledException]::new('Cancelled by user.') } }

function Set-JobStatus($Path, $Stage, $Percent, $Message) {
    if (!$Path) { return }
    # The UI retries a read if it catches a write in progress.
    Write-JsonFile $Path ([ordered]@{ stage=$Stage; percent=$Percent; message=$Message; updatedUtc=[datetime]::UtcNow.ToString('o') })
}

function Quote-NativeArgument([string]$Value) {
    # Windows CommandLineToArgvW quoting. No shell or expression evaluation.
    return '"' + ([regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1')) + '"'
}

function Invoke-VideoTool($Name, [string[]]$Arguments, $Log, $CancelPath, $StdoutPath = '', [scriptblock]$Heartbeat=$null) {
    $exe = Join-Path $script:AppRoot ('tools\' + $Name + '.exe')
    if (!(Test-Path -LiteralPath $exe)) { throw "Missing portable tool: $exe" }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = ($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $p = New-Object Diagnostics.Process; $p.StartInfo = $info
    $writer = $null; $started = $false
    try {
        if ($StdoutPath) { $writer = [IO.File]::Create($StdoutPath) }
        $p.Start() | Out-Null; $started = $true
        $errTask = $p.StandardError.ReadToEndAsync()
        if ($writer) { $outTask = $p.StandardOutput.BaseStream.CopyToAsync($writer) }
        else { $outTask = $p.StandardOutput.ReadToEndAsync() }
        $watch=[Diagnostics.Stopwatch]::StartNew();$lastHeartbeat=0
        while (!$p.WaitForExit(200)) {
            Test-Cancel $CancelPath
            if($Heartbeat -and $watch.Elapsed.TotalSeconds-$lastHeartbeat -ge 1){
                $lastHeartbeat=$watch.Elapsed.TotalSeconds
                & $Heartbeat ([int]$lastHeartbeat) $(if($writer){$writer.Length}else{0})
            }
        }
        $outTask.GetAwaiter().GetResult() | Out-Null
        $err = $errTask.GetAwaiter().GetResult()
        if ($Log) { [IO.File]::AppendAllText($Log, "$Name $($info.Arguments)`r`n$err`r`n", $script:Utf8) }
        # These calls use -v error. Some FFmpeg builds return 0 for refused output writes.
        if ($p.ExitCode -ne 0 -or ($err.Trim() -and $Arguments -notcontains '-version')) { throw "$Name failed (exit $($p.ExitCode)): $err" }
        if (!$writer) { return $outTask.Result }
    } finally {
        if ($started -and !$p.HasExited) { $p.Kill(); $p.WaitForExit() }
        if ($writer) { $writer.Dispose() }; $p.Dispose()
    }
}

function Get-SplitSeconds($Settings) {
    if($Settings.PSObject.Properties['SegmentMinutes']){
        $minutes=[double]$Settings.SegmentMinutes
        if([double]::IsNaN($minutes) -or [double]::IsInfinity($minutes) -or $minutes -lt 0 -or $minutes -ne [Math]::Floor($minutes) -or $minutes -gt [int]::MaxValue){throw 'Split minutes must be a nonnegative whole number (0 = one file).'}
        return $minutes*60.0
    }
    if($Settings.PSObject.Properties['Hourly'] -and $Settings.Hourly){return 3600.0}
    return 0.0
}

function Get-MediaProbe($Path, $Log, $CancelPath, [bool]$CountPackets=$true) {
    $arguments=@('-v','error')
    if($CountPackets){$arguments+='-count_packets'}
    $arguments+=@('-show_streams','-show_format','-of','json',$Path)
    return (Invoke-VideoTool ffprobe $arguments $Log $CancelPath | ConvertFrom-Json)
}

function Get-FrameDigest($Path, $Stream, $Destination, $Log, $CancelPath) {
    Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-xerror','-err_detect','explode','-i',$Path,'-map',"0:$Stream",'-an','-sn','-dn','-noautoscale','-fps_mode','passthrough','-f','framehash','-hash','sha256','-n',$Destination) $Log $CancelPath | Out-Null
    return (Get-DigestFromFramehash $Destination)
}

function Get-DigestFromFramehash($Destination) {
    # Compare frame pixels, size and order; container time bases can legitimately differ.
    $sha = [Security.Cryptography.SHA256]::Create(); $count = 0L
    try {
        foreach ($line in [IO.File]::ReadLines($Destination)) {
            if ($line.StartsWith('#') -or !$line.Trim()) { continue }
            $parts = $line.Split(',')
            if ($parts.Length -ne 6) { throw 'Invalid framehash record.' }
            $bytes = $script:Utf8.GetBytes($parts[4].Trim() + ':' + $parts[5].Trim() + "`n")
            $sha.TransformBlock($bytes,0,$bytes.Length,$bytes,0) | Out-Null; $count++
        }
        $sha.TransformFinalBlock((New-Object byte[] 0),0,0) | Out-Null
        return [pscustomobject]@{ Frames=$count; Sha256=([BitConverter]::ToString($sha.Hash).Replace('-','').ToLowerInvariant()) }
    } finally { $sha.Dispose() }
}
