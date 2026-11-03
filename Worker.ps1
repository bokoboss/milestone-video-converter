param([Parameter(Mandatory=$true)][string]$Request)
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Verify.ps1"
$job = Get-Content -LiteralPath $Request -Raw -Encoding UTF8 | ConvertFrom-Json
$status = [string]$job.Status; $cancel = [string]$job.Cancel
$reportPath = [string]$job.Report
$report = [ordered]@{ version=2; appVersion=$script:AppVersion; status='running'; camera=$job.Camera; startedUtc=[datetime]::UtcNow.ToString('o'); finishedUtc=$null; timeline=$null; gaps=@(); outputs=@(); error=$null; log=$null; verification=[ordered]@{databaseToExport='Toolkit pass-through; frame count and timestamps checked';exportToMp4='Decoded pixels SHA-256 and packet presentation timestamps checked';timestampToleranceSeconds=0.002;gapPolicy='max(3*median frame interval, median frame interval + 0.1 seconds)';diagnosticRange=$false} }
$bridge=$null; $work=$null
try {
    $totalWatch=[Diagnostics.Stopwatch]::StartNew();$stageWatch=[Diagnostics.Stopwatch]::StartNew()
    $mode=Get-VerificationMode $job;Initialize-Verification
    $report['timings']=[ordered]@{};$report.verification['mode']=$mode
    $report.verification.exportToMp4=if($mode -eq 'stream_sample'){'All canonical packets SHA-256, timestamps and decoded sample windows'}else{'All decoded pixels SHA-256 and packet timestamps'}
    $splitSeconds=Get-SplitSeconds $job
    $report['segmentMinutes']=$splitSeconds/60
    $report.verification['inspect']='Compressed packet metadata; no pixel decoding during inspect'
    $camera=$job.Camera
    if (!(Test-Path -LiteralPath $job.Output)) { New-Item -ItemType Directory -Path $job.Output | Out-Null }
    # Reserve a unique directory atomically. Never share a working directory between PCs/jobs.
    $work=Join-Path $job.Output ('job_'+[Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -ErrorAction Stop | Out-Null
    $log=Join-Path $work 'conversion.log'; $report.log=$log
    $reportPath=Join-Path $work 'report.json'
    Write-JsonFile $job.Report ([ordered]@{ status='running'; report=$reportPath })
    $drive=New-Object IO.DriveInfo([IO.Path]::GetPathRoot($work))
    if ($drive.AvailableFreeSpace -lt ([long]$camera.Bytes*3+1GB)) { throw 'Insufficient free disk space. Allow 3 times the source size plus 1 GB for temporary and verified files.' }
    Set-JobStatus $status 'scan' 0 'Reading original database frames and timestamps...'
    Initialize-Toolkit $camera.Toolkit
    Add-Type -Path "$PSScriptRoot\MediaPlan.cs"
    $bridge=New-Object PortableVideo.Bridge($camera.Bank,$camera.Table)
    $timeline=$bridge.Scan($cancel)
    $report.timings['scanSeconds']=$stageWatch.Elapsed.TotalSeconds;$stageWatch.Restart()
    $report.timeline=[ordered]@{ beginUtc=$timeline.Start.ToString('o'); lastFrameUtc=$timeline.End.ToString('o'); frames=$timeline.Frames; frameInterval=$timeline.FrameInterval; compressedPayloadSha256=$timeline.CompressedPayloadSha256; timezone='UTC (display Asia/Bangkok +07:00)' }
    if ($job.PSObject.Properties['LimitSeconds'] -and $job.LimitSeconds -gt 0) {
        # Diagnostic-only option. Production jobs always export the entire database.
        $exportEnd=$timeline.Start.AddSeconds([double]$job.LimitSeconds)
        $expectedFrames=0L
        $report.verification.diagnosticRange=$true
    } else { $exportEnd=$timeline.End; $expectedFrames=$timeline.Frames }
    $mkv=Join-Path $work 'original.partial.mkv'
    Set-JobStatus $status 'export' 5 'Exporting original compressed video through Milestone Toolkit...'
    $bridge.StartExport($mkv,$timeline.Start,$exportEnd)
    while (!$bridge.Finished) {
        if (Test-Path -LiteralPath $cancel) { $bridge.Cancel(); Test-Cancel $cancel }
        Set-JobStatus $status 'export' (5+[int]($bridge.Progress*0.25)) 'Exporting original compressed video...'
        Start-Sleep -Milliseconds 250
    }
    $bridge.CheckExport(); $bridge.Dispose(); $bridge=$null
    $report.timings['exportSeconds']=$stageWatch.Elapsed.TotalSeconds;$stageWatch.Restart()
    Set-JobStatus $status 'inspect' 32 'Reading compressed packets and timestamps (no full image decoding)...'
    $probe=Get-MediaProbe $mkv $log $cancel $false
    $packetCount=0L
    try {
        $frameList=Join-Path $work 'packets.txt'
        $inspectWatch=[Diagnostics.Stopwatch]::StartNew()
        $heartbeat={param($seconds,$bytes) Set-JobStatus $status 'inspect' 32 ("Reading packet metadata without decoding images: $seconds s, "+[Math]::Round($bytes/1MB,1)+' MB metadata read...')}
        Invoke-VideoTool ffprobe @('-v','error','-select_streams','v','-show_packets','-show_entries','packet=stream_index,pts_time,flags','-of','compact=p=0:nk=0',$mkv) $log $cancel $frameList $heartbeat
        $report.verification['inspectSeconds']=[Math]::Round($inspectWatch.Elapsed.TotalSeconds,2)
        $runs=@([PortableVideo.MediaPlanner]::ReadPackets($frameList,$timeline.FrameInterval,$splitSeconds,$timeline.FrameTicks))
        $packetCount=[long](($runs | Measure-Object Frames -Sum).Sum)
        if($expectedFrames -gt 0 -and $packetCount -ne $expectedFrames){throw "Source/export frame count differs: source=$expectedFrames export=$packetCount."}
        $active=@($probe.streams | Where-Object { $_.codec_type -eq 'video' -and $_.index -eq $runs[0].Stream })
        if($active.Count -ne 1){throw 'Cannot identify the active video track.'}
        foreach($run in $runs){
            $run.Width=$active[0].width;$run.Height=$active[0].height
            foreach($gap in $run.Gaps){$report.gaps+=[ordered]@{previousFrameUtc=$timeline.Start.AddSeconds($gap.Previous).ToString('o');nextFrameUtc=$timeline.Start.AddSeconds($gap.Next).ToString('o');splitFile=$false}}
        }
        $report.timings['inspectSeconds']=$stageWatch.Elapsed.TotalSeconds;$stageWatch.Restart()
        if($mode -eq 'stream_sample' -and !(Get-CanonicalFilter $active[0].codec_name)){throw 'Fast verification supports H.264/H.265. Select decoded_full mode for this codec.'}
        Set-JobStatus $status 'inspect' 38 'Building the canonical source packet reference...'
        $reference=Get-PacketManifest $mkv $active[0].index $active[0].codec_name (Join-Path $work 'source.packet.framehash') $log $cancel $status $packetCount 'inspect' 38
        if($reference.Packets -ne $packetCount){throw 'Reference packet hash count differs from source timeline.'}
        $report.timings['sourcePacketHashSeconds']=$reference.Seconds;$stageWatch.Restart()
        $candidates=@(); $n=0;$copyOffset=0
        foreach ($run in $runs) {
            Test-Cancel $cancel; $n++
            Set-JobStatus $status 'remux' (40+[int](20*$n/$runs.Count)) "Creating lossless MP4 part $n / $($runs.Count)..."
            $stream=@($active | Where-Object { $_.index -eq $run.Stream })[0]
            if ($stream.codec_name -notin @('h264','hevc','mpeg4','mjpeg')) { throw "Codec $($stream.codec_name) cannot be approved for this MP4 workflow." }
            $safeName=([string]$camera.Camera -replace '[<>:"/\\|?*\x00-\x1f]','_').Trim().TrimEnd('.')
            if (!$safeName) { $safeName='camera' }; if ($safeName.Length -gt 60) { $safeName=$safeName.Substring(0,60) }
            $startUtc=$timeline.Start.AddSeconds($run.Start)
            $base=$safeName+'_'+$startUtc.AddHours(7).ToString('yyyyMMdd_HHmmss_fff')+'_UTC+07_part'+$n.ToString('000')
            $part=Join-Path $work ($base+'.partial.mp4')
            # Input seeking begins at a keyframe validated above; output count/hash verification is mandatory.
            Copy-VideoRange $mkv $run.Stream $reference.Manifest $copyOffset $run.Frames $part $log $cancel
            $copyOffset+=[int]$run.Frames
            $partProbe=Get-MediaProbe $part $log $cancel $false
            $outStream=@($partProbe.streams | Where-Object codec_type -eq 'video')[0]
            Assert-VideoMetadata $active[0] $outStream
            if($outStream.width -ne $run.Width -or $outStream.height -ne $run.Height){throw "Part $n resolution differs."}
            $candidates+= [pscustomobject]@{Partial=$part;Final=(Join-Path $work ($base+'.mp4'));Run=$run;Probe=$partProbe;BeginUtc=$startUtc.ToString('o');Digest=$null;Packet=$null;Samples=@()}
        }
        $report.timings['remuxSeconds']=$stageWatch.Elapsed.TotalSeconds;$stageWatch.Restart()
        Set-JobStatus $status 'verify' 65 'Checking compressed video packets and timestamps...'
        $offset=0
        foreach($candidate in $candidates){
            $candidate.Packet=Get-PacketManifest $candidate.Partial 0 $active[0].codec_name ($candidate.Partial+'.packet.framehash') $log $cancel $status $candidate.Run.Frames
            $expected=$reference.Manifest.Range($offset,[int]$candidate.Run.Frames)
            $expected.Compare($candidate.Packet.Manifest,($mode -eq 'stream_sample'))
            $candidate.Packet.Manifest.CheckTimes($candidate.Run.Times)
            if($mode -eq 'stream_sample'){
                $candidate.Samples=@(Compare-SampledPixels @('-i',$mkv) $candidate.Run.Start $candidate.Partial $candidate.Run.Times $timeline.FrameInterval ($candidate.Partial+'.sample') $log $cancel $status)
            }
            $offset+=[int]$candidate.Run.Frames
        }
        if($offset -ne $reference.Packets){throw 'Not all source packets were accounted for.'}
        if($mode -eq 'decoded_full'){
        # Verify every frame in every original track against all output parts in that track.
        Set-JobStatus $status 'verify' 65 'Decoding every frame and verifying SHA-256 pixel hashes. This can take time...'
        foreach ($stream in $active) {
            $inputHash=Join-Path $work ('source_'+$stream.index+'.framehash')
            $originalDigest=Get-FrameDigest $mkv $stream.index $inputHash $log $cancel
            $combined=Join-Path $work ('output_'+$stream.index+'.framehash')
            $combinedWriter=New-Object IO.StreamWriter($combined,$false,$script:Utf8)
            try {
                foreach ($candidate in @($candidates | Where-Object { $_.Run.Stream -eq $stream.index } | Sort-Object { $_.Run.Start })) {
                    $hashFile=$candidate.Partial+'.framehash'
                    $candidate.Digest=Get-FrameDigest $candidate.Partial 0 $hashFile $log $cancel
                    foreach ($line in [IO.File]::ReadLines($hashFile)) { if (!$line.StartsWith('#') -and $line.Trim()) { $combinedWriter.WriteLine($line) } }
                }
            } finally { $combinedWriter.Dispose() }
            $outputDigest=Get-DigestFromFramehash $combined
            if ($outputDigest.Frames -ne $originalDigest.Frames -or $outputDigest.Sha256 -ne $originalDigest.Sha256) { throw 'Decoded frame SHA-256 verification failed. No MP4 is marked successful.' }
        }
        }
        $report.timings['verifySeconds']=$stageWatch.Elapsed.TotalSeconds
        Test-Cancel $cancel
        foreach ($candidate in $candidates) {
            [IO.File]::Move($candidate.Partial,$candidate.Final)
            $report.outputs+= [ordered]@{ path=$candidate.Final; status='verified'; sourceStream=$candidate.Run.Stream; beginUtc=$candidate.BeginUtc; lastFrameUtc=$timeline.Start.AddSeconds($candidate.Run.Last).ToString('o'); firstOutputPts=$candidate.Packet.Manifest.Times()[0]; frames=$candidate.Packet.Packets; packetSha256=$candidate.Packet.Sha256; packetManifest=$candidate.Packet.Path; verificationMode=$mode; decodedSamples=@($candidate.Samples); pixelSha256=$(if($candidate.Digest){$candidate.Digest.Sha256}else{$null}); pixelManifest=$(if($candidate.Digest){$candidate.Partial+'.framehash'}else{$null}); width=$candidate.Run.Width; height=$candidate.Run.Height; reason=$candidate.Run.Reason; codec=$candidate.Probe.streams[0].codec_name; bytes=(Get-Item -LiteralPath $candidate.Final).Length }
        }
        $report.status='verified'
        # Delete only this job's known intermediate file after all outputs have passed verification.
        Remove-Item -LiteralPath $mkv
    } catch {
        if (Test-Path -LiteralPath $cancel) { throw }
        $fallback=Join-Path $work 'original_preserved.mkv'
        [IO.File]::Move($mkv,$fallback)
        $report.status='needs_review'; $report.error=$_.Exception.ToString()
        $report.outputs=@([ordered]@{ path=$fallback; status='preserved_mkv'; frames=$packetCount })
    }
} catch {
    $report.status=if (Test-Path -LiteralPath $cancel) { 'cancelled' } else { 'failed' }
    $report.error=$_.Exception.ToString()
} finally {
    if ($bridge) { $bridge.Dispose() }
    if($report.Contains('timings')){
        if($report.timings.Contains('sourcePacketHashSeconds') -and $report.timings.Contains('verifySeconds')){$report.timings['verificationTotalSeconds']=$report.timings.sourcePacketHashSeconds+$report.timings.verifySeconds}
        $report.timings['totalSeconds']=$totalWatch.Elapsed.TotalSeconds
    }
    $report.finishedUtc=[datetime]::UtcNow.ToString('o')
    Write-JsonFile $reportPath $report
    if ($reportPath -ne $job.Report) { Write-JsonFile $job.Report ([ordered]@{ status=$report.status; report=$reportPath }) }
    Set-JobStatus $status $report.status 100 $(if($report.error){$report.error}elseif($mode -eq 'stream_sample'){'All video packets verified; decoded samples passed. Output is ready.'}else{'All decoded frames verified. Output is ready.'})
}
if ($report.status -eq 'verified') { exit 0 }; if ($report.status -eq 'cancelled') { exit 2 }; exit 1
