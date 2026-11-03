param([switch]$SkipMedia)
. "$PSScriptRoot\..\Core.ps1"
. "$PSScriptRoot\..\Merge.ps1"
Add-Type -Path "$PSScriptRoot\..\MediaPlan.cs"
$scratch=Join-Path $PSScriptRoot ('scratch_'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch|Out-Null
$script:passed=0
function Assert($Condition,$Message){if(!$Condition){throw "FAIL: $Message"};$script:passed++;Write-Host "PASS: $Message"}
function Assert-Throws($Action,$Message){$thrown=$false;try{&$Action|Out-Null}catch{$thrown=$true};Assert $thrown $Message}
function New-Frame($Time,$Key=0,$Width=64){'stream_index=0|key_frame='+$Key+'|best_effort_timestamp_time='+$Time+'|width='+$Width+'|height=48|pix_fmt=yuv420p'}
function Read-Plan($Lines,$Seconds=0){$path=Join-Path $scratch 'frames.txt';[IO.File]::WriteAllLines($path,[string[]]$Lines,$script:Utf8);return @([PortableVideo.MediaPlanner]::Read($path,0.04,$Seconds,$null))}
try{
    Assert ((Get-ContainedPath $scratch 'child\file') -eq (Join-Path $scratch 'child\file')) 'Source paths remain inside the source root'
    Assert-Throws {Get-ContainedPath $scratch '..\outside'} 'Reject path traversal in project metadata'
    $xml=Join-Path $scratch 'unsafe.xml';[IO.File]::WriteAllText($xml,'<!DOCTYPE x [<!ENTITY y SYSTEM "file:///C:/Windows/win.ini">]><x>&y;</x>')
    Assert-Throws {Read-SafeXml $xml} 'Reject XML DTD and external entities'
    Assert ((Quote-NativeArgument 'a"b\') -eq '"a\"b\\"') 'Quote Windows native arguments including trailing slash and quote'
    $runs=@(Read-Plan @((New-Frame '0' 1),(New-Frame '0.04'),(New-Frame '0.08')))
    Assert ($runs.Count -eq 1 -and $runs[0].Frames -eq 3) 'Keep continuous frames in one run'
    $ticks=New-Object 'Collections.Generic.List[long]';$ticks.Add(0);$ticks.Add(400000);$ticks.Add(800000)
    $sourceMatch=@([PortableVideo.MediaPlanner]::Read((Join-Path $scratch 'frames.txt'),0.04,$false,$ticks))
    Assert ($sourceMatch[0].Frames -eq 3) 'Export frame timestamps match original database timestamps'
    $ticks[1]=900000
    Assert-Throws {[PortableVideo.MediaPlanner]::Read((Join-Path $scratch 'frames.txt'),0.04,$false,$ticks)} 'Reject source-to-export timestamp changes'
    $runs=@(Read-Plan @((New-Frame '0' 1),(New-Frame '0.04'),(New-Frame '2' 1),(New-Frame '2.04')))
    Assert ($runs.Count -eq 1 -and $runs[0].Gaps.Count -eq 1 -and $runs[0].Frames -eq 4 -and $runs[0].Times[2] -eq 2) 'Keep gaps and original timestamps inside one file'
    $otherStream=(New-Frame '0.08' 1).Replace('stream_index=0','stream_index=1')
    Assert-Throws {Read-Plan @((New-Frame '0' 1),(New-Frame '0.04'),$otherStream)} 'Preserve MKV for incompatible active tracks instead of splitting files'
    $overlapStream=(New-Frame '0.02' 1).Replace('stream_index=0','stream_index=1')
    Assert-Throws {Read-Plan @((New-Frame '0' 1),(New-Frame '0.04'),$overlapStream)} 'Keep MKV when multiple active video tracks overlap'
    $nonKeyGap=@(Read-Plan @((New-Frame '0' 1),(New-Frame '2' 0)))
    Assert ($nonKeyGap.Count -eq 1 -and $nonKeyGap[0].Gaps.Count -eq 1) 'A gap at a non-keyframe does not force another file'
    Assert-Throws {Read-Plan @((New-Frame '0' 1),(New-Frame '0.04' 1 128))} 'Never silently split on image format changes'
    Assert-Throws {Read-Plan @((New-Frame '0' 1),(New-Frame '0'))} 'Reject duplicate frame timestamps'
    foreach($minutes in @(0,10,15,30,60,120,45)){
        Assert ((Get-SplitSeconds ([pscustomobject]@{SegmentMinutes=$minutes})) -eq $minutes*60) "Accept split preset/custom minutes: $minutes"
    }
    Assert-Throws {Get-SplitSeconds ([pscustomobject]@{SegmentMinutes=-1})} 'Reject negative split duration'
    Assert-Throws {Get-SplitSeconds ([pscustomobject]@{SegmentMinutes=1.5})} 'Reject fractional split minutes'
    $packetFixture=Join-Path $scratch 'fixture-packets.txt'
    [IO.File]::WriteAllLines($packetFixture,@('stream_index=0|pts_time=0|flags=K_','stream_index=0|pts_time=0.04|flags=__','stream_index=0|pts_time=2|flags=__'))
    $packetRuns=@([PortableVideo.MediaPlanner]::ReadPackets($packetFixture,0.04,0,$null))
    Assert ($packetRuns.Count -eq 1 -and $packetRuns[0].Frames -eq 3 -and $packetRuns[0].Gaps.Count -eq 1) 'Fast inspect uses packets and keeps a gap in one output'
    $lines=New-Object 'Collections.Generic.List[string]'
    for($i=0;$i -le 90100;$i++){$lines.Add((New-Frame (($i*0.04).ToString('0.00',[Globalization.CultureInfo]::InvariantCulture)) $(if($i -eq 0 -or $i -eq 90000){1}else{0})))}
    $runs=Read-Plan $lines 3600
    Assert ($runs.Count -eq 2 -and $runs[1].Start -eq 3600) 'Split an hour at a keyframe without duplicated frames'
    $status=Join-Path $scratch 'cancel';[IO.File]::WriteAllText($status,'cancel')
    Assert-Throws {Test-Cancel $status} 'Honor cancellation'
    $result1=[pscustomobject]@{status='verified';camera=[pscustomobject]@{CameraId='id';Camera='camera'};timeline=[pscustomobject]@{frameInterval=0.04};outputs=@([pscustomobject]@{beginUtc='2026-01-01T00:00:00Z';lastFrameUtc='2026-01-01T00:00:00.960Z';path='a'})}
    $result2=[pscustomobject]@{status='verified';camera=$result1.camera;timeline=$result1.timeline;outputs=@([pscustomobject]@{beginUtc='2026-01-01T00:00:01Z';lastFrameUtc='2026-01-01T00:00:01.960Z';path='b'})}
    $groups=@(Get-MergeGroups @($result1,$result2));Assert ($groups.Count -eq 1 -and $groups[0].Count -eq 2) 'Merge only continuous periods from the same camera'
    $result2.outputs[0].beginUtc='2026-01-01T00:00:00.5Z'
    Assert-Throws {Get-MergeGroups @($result1,$result2)} 'Pause overlapping periods'
    $result2.outputs[0].beginUtc='2026-01-01T00:00:04Z'
    Assert (@(Get-MergeGroups @($result1,$result2)).Count -eq 0) 'Do not merge across a time gap'
    # Two independent project fixtures establish discovery is metadata-driven.
    $discovered=@()
    for($fixture=0;$fixture -lt 2;$fixture++){
        $root=Join-Path $scratch ("ชุดเวลา ' "+$fixture)
        $projectDir=Join-Path $root 'Client Files';$bin=Join-Path $projectDir 'Client\bin'
        $bank=Join-Path $projectDir 'Data\Mediadata\bank';$media=Join-Path $bank 'table\media'
        New-Item -ItemType Directory -Path $bin,$media -Force|Out-Null
        $pe=New-Object byte[] 128;$pe[60]=64;$pe[64]=80;$pe[65]=69;$pe[68]=76;$pe[69]=1
        [IO.File]::WriteAllBytes((Join-Path $bin 'VideoOS.Toolkit.dll'),$pe)
        [IO.File]::WriteAllText((Join-Path $media 'cindex.idx'),'fixture');[IO.File]::WriteAllText((Join-Path $media 'block0.blk'),'fixture')
        $begin=1791428400000L+$fixture*3600000L;$end=$begin+3599960
        [IO.File]::WriteAllText((Join-Path $bank 'cache.xml'),"<bank><table><name>table</name><column><name>media</name><type>master</type><begin_time>$begin</begin_time><end_time>$end</end_time></column></table></bank>")
        $xml='<ProjectFile><SystemInformation><Recorders><OfflineRecorderInfo><OfflineSources><OfflineSourceInfo><SourceId>source</SourceId><DatabaseType>MediaStorage</DatabaseType><BankPath>Mediadata\bank</BankPath><TableName>table</TableName></OfflineSourceInfo></OfflineSources><Cameras><OfflineCameraInfo><SourceId>source</SourceId><DeviceId>camera-id</DeviceId><Name>Camera from metadata</Name><CameraSecurity><ExportAvi>true</ExportAvi></CameraSecurity></OfflineCameraInfo></Cameras></OfflineRecorderInfo></Recorders></SystemInformation></ProjectFile>'
        [IO.File]::WriteAllText((Join-Path $projectDir 'Any Project.scp'),$xml)
        $discovered+=@(Get-SourceCameras $root)
    }
    Assert ($discovered.Count -eq 2 -and $discovered[0].Camera -eq 'Camera from metadata' -and ([datetime]$discovered[1].BeginUtc-[datetime]$discovered[0].BeginUtc).TotalHours -eq 1) 'Discover different source folders and time periods without fixed folder names or dates'
    $deniedProject=Join-Path $discovered[0].Source 'Client Files\Any Project.scp'
    [IO.File]::WriteAllText($deniedProject,$xml.Replace('<ExportAvi>true','<ExportAvi>false'))
    Assert-Throws {Get-SourceCameras $discovered[0].Source} 'Honor source export permissions'
    $session=Join-Path $scratch 'cancelled-queue';New-Item -ItemType Directory -Path $session|Out-Null
    $queueRequest=Join-Path $session 'request.json'
    Write-JsonFile $queueRequest ([ordered]@{Cameras=@($discovered[1]);Output=$scratch;Session=$session;Status=(Join-Path $session 'status.json');Cancel=$status;Hourly=$false;Merge=$false})
    & (Get-PowerShellHost) -NoProfile -File "$PSScriptRoot\..\Queue.ps1" -Request $queueRequest
    $summary=Get-Content -LiteralPath (Join-Path $session 'queue-report.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($summary.status -eq 'cancelled') 'Queue cancellation writes a final report without exporting'
    $session=Join-Path $scratch 'overlapping-queue';New-Item -ItemType Directory -Path $session|Out-Null
    $queueRequest=Join-Path $session 'request.json'
    Write-JsonFile $queueRequest ([ordered]@{Cameras=@($discovered[1],$discovered[1]);Output=$scratch;Session=$session;Status=(Join-Path $session 'status.json');Cancel=(Join-Path $session 'not-cancelled');Hourly=$false;Merge=$true})
    & (Get-PowerShellHost) -NoProfile -File "$PSScriptRoot\..\Queue.ps1" -Request $queueRequest
    $summary=Get-Content -LiteralPath (Join-Path $session 'queue-report.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($summary.status -eq 'needs_review' -and $summary.results.Count -eq 0 -and $summary.errors[0] -match 'Overlapping') 'Queue pauses overlapping groups before loading Toolkit'
    $session=Join-Path $scratch 'failed-jobs-queue';New-Item -ItemType Directory -Path $session|Out-Null
    $bad1=$discovered[0].PSObject.Copy();$bad2=$discovered[1].PSObject.Copy()
    $bad1.Toolkit=Join-Path $scratch 'missing-toolkit';$bad2.Toolkit=$bad1.Toolkit
    $bad1.Bytes=[long]::MaxValue;$bad2.Bytes=1
    $queueRequest=Join-Path $session 'request.json'
    Write-JsonFile $queueRequest ([ordered]@{Cameras=@($bad1,$bad2);Output=$scratch;Session=$session;Status=(Join-Path $session 'status.json');Cancel=(Join-Path $session 'not-cancelled');Hourly=$false;Merge=$false})
    & (Get-PowerShellHost) -NoProfile -File "$PSScriptRoot\..\Queue.ps1" -Request $queueRequest
    $summary=Get-Content -LiteralPath (Join-Path $session 'queue-report.json') -Raw -Encoding UTF8|ConvertFrom-Json
    Assert ($summary.results.Count -eq 2 -and $summary.results[0].error -match 'Insufficient free disk space' -and $summary.results[1].status -eq 'failed') 'A low-space or missing-runtime failure does not stop subsequent queued jobs'
    if(!$SkipMedia){
        $inputFile=Join-Path $scratch "ภาพ ' & `$ ตัวอย่าง.mkv";$log=Join-Path $scratch 'tools.log'
        Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-f','lavfi','-i','testsrc2=size=64x48:rate=25','-frames:v','50','-c:v','libx264','-bf','0','-g','25','-n',$inputFile) $log ''|Out-Null
        $mp4=Join-Path $scratch 'result.mp4'
        Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-i',$inputFile,'-map','0:v:0','-c','copy','-n',$mp4) $log ''|Out-Null
        $a=Get-FrameDigest $inputFile 0 (Join-Path $scratch 'input.framehash') $log ''
        $b=Get-FrameDigest $mp4 0 (Join-Path $scratch 'output.framehash') $log ''
        Assert ($a.Frames -eq 50 -and $a.Sha256 -eq $b.Sha256) 'Lossless MP4 keeps all decoded frame hashes (Thai, spaces, apostrophe and shell symbols in paths)'
        Assert-Throws {Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-i',$inputFile,'-c','copy','-n',$mp4) $log ''} 'Existing output is never overwritten'
        $cancelFile=Join-Path $scratch 'ffmpeg.cancel';[IO.File]::WriteAllText($cancelFile,'cancel')
        Assert-Throws {Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-re','-f','lavfi','-i','testsrc2=size=64x48:rate=25','-t','30','-f','null','-') $log $cancelFile} 'Cancellation stops a running FFmpeg process'
        $frames=Join-Path $scratch 'actual-frames.txt'
        Invoke-VideoTool ffprobe @('-v','error','-show_frames','-show_entries','frame=stream_index,key_frame,best_effort_timestamp_time,width,height,pix_fmt','-of','compact=p=0:nk=0',$mp4) $log '' $frames
        $actualRuns=@([PortableVideo.MediaPlanner]::Read($frames,0.04,$false,$null))
        Assert ($actualRuns.Count -eq 1 -and $actualRuns[0].Frames -eq 50) 'Plan runs from actual decoded FFprobe output'
        $packets=Join-Path $scratch 'packets.txt'
        Invoke-VideoTool ffprobe @('-v','error','-show_packets','-show_entries','packet=pts_time','-of','compact=p=0:nk=0',$mp4) $log '' $packets
        [PortableVideo.MediaPlanner]::VerifyPacketTimes($packets,$actualRuns[0].Times)
        Assert $true 'MP4 preserves frame timing'
        $fake=Join-Path $scratch 'fake-times.txt';[IO.File]::WriteAllLines($fake,@('pts_time=0','pts_time=0.4'))
        Assert-Throws {[PortableVideo.MediaPlanner]::VerifyPacketTimes($fake,$actualRuns[0].Times)} 'Reject a timing/frame-count mismatch'
        $corrupt=Join-Path $scratch 'broken.mkv';[IO.File]::WriteAllText($corrupt,'broken')
        Assert-Throws {Get-MediaProbe $corrupt $log ''} 'Corrupted video cannot pass verification'
        $gappy=Join-Path $scratch 'gappy.mkv'
        Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-f','lavfi','-i','testsrc2=size=64x48:rate=25','-frames:v','150','-vf','setpts=PTS+gte(N\,50)*2/TB','-fps_mode','passthrough','-c:v','libx264','-bf','0','-g','25','-n',$gappy) $log ''|Out-Null
        $gapPackets=Join-Path $scratch 'gap-packets.txt'
        Invoke-VideoTool ffprobe @('-v','error','-select_streams','v','-show_packets','-show_entries','packet=stream_index,pts_time,flags','-of','compact=p=0:nk=0',$gappy) $log '' $gapPackets
        $gapRuns=@([PortableVideo.MediaPlanner]::ReadPackets($gapPackets,0.04,0,$null))
        Assert ($gapRuns.Count -eq 1 -and $gapRuns[0].Frames -eq 150 -and $gapRuns[0].Gaps.Count -eq 1) 'A real video with missing recording time remains one file'
        $gapMp4=Join-Path $scratch 'gappy.mp4'
        Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-i',$gappy,'-map','0:v:0','-c','copy','-n',$gapMp4) $log ''|Out-Null
        $gapSourceHash=Get-FrameDigest $gappy 0 (Join-Path $scratch 'gap-source.framehash') $log ''
        $gapOutputHash=Get-FrameDigest $gapMp4 0 (Join-Path $scratch 'gap-output.framehash') $log ''
        Assert ($gapSourceHash.Frames -eq 150 -and $gapSourceHash.Sha256 -eq $gapOutputHash.Sha256) 'Gap-preserving MP4 keeps every original decoded frame'
        $gapOutputTimes=Join-Path $scratch 'gap-output-times.txt'
        Invoke-VideoTool ffprobe @('-v','error','-select_streams','v','-show_packets','-show_entries','packet=pts_time','-of','compact=p=0:nk=0',$gapMp4) $log '' $gapOutputTimes
        [PortableVideo.MediaPlanner]::VerifyPacketTimes($gapOutputTimes,$gapRuns[0].Times)
        Assert $true 'Gap duration and frame presentation times remain unchanged in MP4'
        $heartbeatCount=0
        Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-re','-f','lavfi','-i','testsrc2=size=16x16:rate=5','-t','2','-f','null','-') $log '' '' {param($seconds,$bytes) $script:heartbeatCount++}|Out-Null
        Assert ($script:heartbeatCount -gt 0) 'Long-running tool calls update elapsed-time heartbeat'
        # Integration of concatenation with independently verified input parts.
        $first=Join-Path $scratch 'first.mp4';$second=Join-Path $scratch 'second.mp4'
        Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-i',$mp4,'-c','copy','-f','segment','-segment_time','1','-reset_timestamps','1','-n',(Join-Path $scratch 'piece_%d.mp4')) $log ''|Out-Null
        $result1.outputs[0].path=Join-Path $scratch 'piece_0.mp4';$result2.outputs[0].path=Join-Path $scratch 'piece_1.mp4'
        $result2.outputs[0].beginUtc='2026-01-01T00:00:01Z'
        $merged=@(Merge-VerifiedResults @($result1,$result2) $scratch $false '')
        Assert ($merged.Count -eq 1 -and $merged[0].status -eq 'verified' -and $merged[0].outputs[0].frames -eq 50) 'Join separate compatible clips and verify all frame hashes'
    }
    Write-Host "ALL $script:passed CHECKS PASSED. Artifacts: $scratch" -ForegroundColor Green
}catch{Write-Host $_.Exception.ToString() -ForegroundColor Red;exit 1}

