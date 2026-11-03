param([Parameter(Mandatory=$true)][string]$Request)
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Verify.ps1"
. "$PSScriptRoot\Merge.ps1"
$q=Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
$results=@(); $failures=@(); $child=$null
try {
    $splitSeconds=Get-SplitSeconds $q
    $verificationMode=Get-VerificationMode $q
    $cameras=@($q.Cameras)
    if ($q.Merge) {
        # Pause overlapping camera groups before exporting anything from those groups.
        $blocked=@{}
        foreach ($group in @($cameras | Group-Object CameraId)) {
            $ordered=@($group.Group | Sort-Object { [datetime]$_.BeginUtc })
            for($i=1;$i -lt $ordered.Count;$i++) {
                if ([datetime]$ordered[$i].BeginUtc -le [datetime]$ordered[$i-1].EndUtc) {
                    $blocked[$group.Name]=$true
                    $failures+= "Overlapping source periods for $($ordered[$i].Camera): $($ordered[$i-1].Source) / $($ordered[$i].Source). Group paused; remove the overlapping source and retry."
                }
            }
        }
        $cameras=@($cameras | Where-Object { !$blocked.ContainsKey($_.CameraId) })
    }
    for($index=0;$index -lt $cameras.Count;$index++) {
        Test-Cancel $q.Cancel
        $camera=$cameras[$index]; $id=[Guid]::NewGuid().ToString('N')
        $childStatus=Join-Path $q.Session ($id+'.status.json')
        $childReport=Join-Path $q.Session ($id+'.result.json')
        $childRequest=Join-Path $q.Session ($id+'.request.json')
        Write-JsonFile $childRequest ([ordered]@{ Camera=$camera; Output=$q.Output; Status=$childStatus; Cancel=$q.Cancel; Report=$childReport; SegmentMinutes=($splitSeconds/60); VerificationMode=$verificationMode })
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=Get-PowerShellHost $camera.Architecture
        $info.Arguments=(@('-NoProfile','-STA','-File',"$PSScriptRoot\Worker.ps1",'-Request',$childRequest) | ForEach-Object { Quote-NativeArgument $_ }) -join ' '
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $child=[Diagnostics.Process]::Start($info)
        while (!$child.WaitForExit(250)) {
            if (Test-Path -LiteralPath $childStatus) {
                try {
                    $state=Get-Content -LiteralPath $childStatus -Raw -Encoding UTF8 | ConvertFrom-Json
                    Set-JobStatus $q.Status $state.stage ([int](($index*100+$state.percent)/[Math]::Max(1,$cameras.Count))) ("[$($index+1)/$($cameras.Count)] $($camera.Camera): "+$state.message)
                } catch { }
            }
            # The worker notices the shared cancellation file, kills its FFmpeg child and releases Toolkit.
        }
        $exitCode=$child.ExitCode; $child.Dispose(); $child=$null
        if (Test-Path -LiteralPath $childReport) {
            $pointer=Get-Content -LiteralPath $childReport -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($pointer.PSObject.Properties['report']) {
                $r=Get-Content -LiteralPath $pointer.report -Raw -Encoding UTF8 | ConvertFrom-Json
                $results+=$r
                if ($r.status -ne 'verified') { $failures+="$($camera.Camera): $($r.status) - $($r.error)" }
            } else { $results+=$pointer; $failures+="$($camera.Camera): $($pointer.error)" }
        } else { $failures+="Worker stopped before writing a report (exit $exitCode). Check PowerShell policy and Toolkit prerequisites." }
    }
    if ($q.Merge -and !(Test-Path -LiteralPath $q.Cancel)) {
        Set-JobStatus $q.Status 'merge' 90 'Checking verified files for safe cross-folder joining...'
        $merged=Merge-VerifiedResults $results $q.Output $splitSeconds $q.Cancel $verificationMode $q.Status
        $results+=@($merged)
        foreach($result in @($merged)){if($result.status -ne 'verified'){$failures+=$result.error}}
    }
} catch { $failures+=$_.Exception.ToString() }
finally {
    $final=if(Test-Path -LiteralPath $q.Cancel){'cancelled'}elseif($failures.Count){'needs_review'}else{'verified'}
    $summary=[ordered]@{status=$final;finishedUtc=[datetime]::UtcNow.ToString('o');results=@($results);errors=@($failures)}
    Write-JsonFile (Join-Path $q.Session 'queue-report.json') $summary
    Set-JobStatus $q.Status $final 100 $(if($failures.Count){$failures -join "`r`n"}else{'Finished. Open the output folder for videos and JSON reports.'})
}
if ($final -eq 'verified') { exit 0 }; exit 1
