param([string]$Source,[switch]$ToolkitProbe,[string]$ToolkitDirectory,[string]$Bank,[string]$Table)
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Verify.ps1"
try{
    if($ToolkitProbe){
        Initialize-Toolkit $ToolkitDirectory
        $factory=New-Object VideoOS.Toolkit.ToolkitFactory;$toolkit=$null;$data=$null
        try{
            $xml='<toolkit type="source"><provider>mpms</provider><config><table include_archives="yes"><name>'+[Security.SecurityElement]::Escape($Table)+'</name><bank><path>'+[Security.SecurityElement]::Escape($Bank)+'</path></bank></table></config></toolkit>'
            $toolkit=$factory.CreateInstance($xml);$toolkit.Connect()
            if($toolkit.MoveFirst().ToString() -ne 'MOVED_OK'){throw 'Database has no readable first record.'}
            [VideoOS.Toolkit.IData]$data=$null
            if($toolkit.GetData([ref]$data).ToString() -ne 'DATA_RETRIEVED'){throw 'Cannot read the first video record.'}
            Write-Host ('Toolkit PASS: first record '+$data.BeginTimeStamp.ToString('o'))
        }finally{if($data -is [IDisposable]){$data.Dispose()};if($toolkit){$factory.DeleteInstance($toolkit)};$factory.Dispose()}
        exit 0
    }
    Write-Host 'Portable CCTV Converter - readiness check'
    Initialize-Verification
    if($PSVersionTable.PSEdition -eq 'Core' -or $PSVersionTable.PSVersion -lt [version]'5.1'){throw 'Use Windows PowerShell 5.1 through setup.bat.'}
    if(![Environment]::Is64BitOperatingSystem){throw '64-bit Windows is required for the bundled FFmpeg.'}
    Write-Host ('PowerShell: '+$PSVersionTable.PSVersion+'; CLR: '+[Environment]::Version)
    Get-ExecutionPolicy -List|Format-Table|Out-Host
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    $manifestPath=Join-Path $PSScriptRoot 'tools\manifest.json'
    if(!(Test-Path -LiteralPath $manifestPath)){throw 'Tool manifest is missing. Copy the complete converter folder.'}
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    $toolsDir=Split-Path -Parent $manifestPath
    $missing=@($manifest | Where-Object { !(Test-Path -LiteralPath (Get-ContainedPath $toolsDir $_.Name) -PathType Leaf) })
    if($missing.Count){
        $stage=Join-Path $toolsDir ('.setup-'+[Guid]::NewGuid().ToString('N'))
        try{
            New-Item -ItemType Directory -Path $stage -ErrorAction Stop | Out-Null
            $archive=Join-Path $stage 'ffmpeg.zip'
            Write-Host 'Downloading FFmpeg Essentials from Gyan (about 109 MB)...'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $archive -TimeoutSec 300 -ErrorAction Stop
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip=[IO.Compression.ZipFile]::OpenRead($archive)
            try{
                foreach($entry in $manifest){
                    $member=$zip.GetEntry(('ffmpeg-9.0.2-essentials_build/bin/'+$entry.Name))
                    if(!$member -or $member.Length -ne $entry.Bytes){throw 'Expected FFmpeg 9.0.2 Essentials build. See tools/README.md for manual setup.'}
                    $stagedFile=Get-ContainedPath $stage $entry.Name
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($member,$stagedFile)
                    if((Get-FileHash -LiteralPath $stagedFile -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry.Sha256){throw "Downloaded tool checksum mismatch: $($entry.Name)."}
                }
            }finally{$zip.Dispose()}
            foreach($entry in $missing){
                [IO.File]::Move((Get-ContainedPath $stage $entry.Name),(Get-ContainedPath $toolsDir $entry.Name))
            }
        }finally{
            if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Recurse -Force}
        }
    }
    foreach($entry in $manifest){
        $file=Get-ContainedPath (Join-Path $PSScriptRoot 'tools') $entry.Name
        if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Sha256){throw "Tool checksum mismatch: $($entry.Name). Copy the bundle again."}
    }
    foreach($tool in @('ffmpeg','ffprobe')){
        $version=Invoke-VideoTool $tool @('-version') '' ''
        Write-Host (($version -split "`n")[0])
    }
    $test=Join-Path $PSScriptRoot ('.write-test-'+[Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($test,'test');Remove-Item -LiteralPath $test
    # Machine readiness and recording compatibility are independent checks.
    # CCTV data is not required during initial setup.
    if($Source){
        if(!(Test-Path -LiteralPath $Source -PathType Container)){throw "Recording folder does not exist: $Source"}
        $cameras=@(Get-SourceCameras $Source)
        if(!$cameras.Count){throw 'No supported camera database found in the specified recording folder.'}
        foreach($camera in $cameras){
            $hostPath=Get-PowerShellHost $camera.Architecture
            & $hostPath -NoProfile -File "$PSScriptRoot\Setup.ps1" -ToolkitProbe -ToolkitDirectory $camera.Toolkit -Bank $camera.Bank -Table $camera.Table
            if($LASTEXITCODE -ne 0){throw 'Toolkit compatibility check failed for this recording.'}
        }
        Write-Host ('PASS: tools ready; Toolkit tested with '+$cameras.Count+' camera(s).') -ForegroundColor Green
    }else{
        Write-Host 'PASS: converter tools ready. No CCTV recording folder is needed during setup.' -ForegroundColor Green
        Write-Host 'To test a particular export, run setup.bat -Source "C:\recording-folder".'
    }
    Write-Host 'No installation, registry, PATH or execution policy changes were made.'
    exit 0
}catch{Write-Host ('CHECK FAILED: '+$_.Exception.ToString()) -ForegroundColor Red;exit 1}

