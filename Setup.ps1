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
    foreach($entry in $manifest){
        $file=Get-ContainedPath (Join-Path $PSScriptRoot 'tools') $entry.Name
        if(!(Test-Path -LiteralPath $file -PathType Leaf)){throw "Missing $($entry.Name). The GitHub source repository excludes FFmpeg binaries; see README.md to prepare tools."}
        if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $entry.Sha256){throw "Tool checksum mismatch: $($entry.Name). Copy the bundle again."}
    }
    foreach($tool in @('ffmpeg','ffprobe')){
        $version=Invoke-VideoTool $tool @('-version') '' ''
        Write-Host (($version -split "`n")[0])
    }
    $test=Join-Path $PSScriptRoot ('.write-test-'+[Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($test,'test');Remove-Item -LiteralPath $test
    if(!$Source){
        $d=New-Object Windows.Forms.FolderBrowserDialog;$d.Description='Select a complete Milestone export to test its included Toolkit'
        try{if($d.ShowDialog() -eq 'OK'){$Source=$d.SelectedPath}}finally{$d.Dispose()}
    }
    if(!$Source){throw 'Toolkit not tested. Run setup.bat again and select a complete recording folder.'}
    $cameras=@(Get-SourceCameras $Source)
    if(!$cameras.Count){throw 'No supported camera database found.'}
    foreach($camera in $cameras){
        $hostPath=Get-PowerShellHost $camera.Architecture
        & $hostPath -NoProfile -File "$PSScriptRoot\Setup.ps1" -ToolkitProbe -ToolkitDirectory $camera.Toolkit -Bank $camera.Bank -Table $camera.Table
        if($LASTEXITCODE -ne 0){throw 'Toolkit prerequisite check failed. No components were installed.'}
    }
    Write-Host ('PASS: '+$cameras.Count+' camera(s). Open start.bat to convert.') -ForegroundColor Green
    Write-Host 'No installation, registry, PATH or execution policy changes were made.'
    exit 0
}catch{Write-Host ('CHECK FAILED: '+$_.Exception.ToString()) -ForegroundColor Red;exit 1}
