. "$PSScriptRoot\..\Core.ps1"
. "$PSScriptRoot\..\Verify.ps1"
. "$PSScriptRoot\..\Merge.ps1"
Initialize-Verification
if(!('PortableVideo.MediaPlanner' -as [type])){Add-Type -Path "$PSScriptRoot\..\MediaPlan.cs"}
$root=Join-Path $PSScriptRoot ('v3_'+[guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $root|Out-Null
$log=Join-Path $root 'tools.log';$script:passed=0
function Assert($Condition,$Text){if(!$Condition){throw "FAIL: $Text"};$script:passed++;Write-Host "PASS: $Text"}
function Reject($Action,$Text){$thrown=$false;try{&$Action|Out-Null}catch{$thrown=$true};Assert $thrown $Text}
try{
    Assert ((Get-VerificationMode ([pscustomobject]@{})) -eq 'stream_sample') 'Fast verification is the default'
    Reject {Get-VerificationMode ([pscustomobject]@{VerificationMode='skip'})} 'Reject verification bypass mode'
    Assert ((Get-VerificationMode ([pscustomobject]@{VerificationMode='decoded_full'})) -eq 'decoded_full') 'Detailed verification remains selectable'
    Reject {Assert-VideoMetadata ([pscustomobject]@{codec_name='h264';color_range='pc'}) ([pscustomobject]@{codec_name='h264';color_range='tv'})} 'Reject changed color interpretation metadata'
    Assert (!(Get-CanonicalFilter 'mpeg4')) 'Unsupported fast codec requires explicit decoded_full selection'
    foreach($codec in @('h264','hevc')){
        $src=Join-Path $root ($codec+'.mkv');$dst=Join-Path $root ($codec+'.mp4')
        $args=@('-nostdin','-v','error','-f','lavfi','-i','testsrc2=size=64x64:rate=25','-frames:v','200','-vf','setpts=PTS+gte(N\,75)*2/TB','-fps_mode','passthrough')
        if($codec -eq 'h264'){$args+=@('-c:v','libx264','-bf','0','-g','25')}else{$args+=@('-c:v','libx265','-x265-params','log-level=error:pools=1:frame-threads=1:keyint=25:min-keyint=25:scenecut=0:open-gop=0')}
        $args+=@('-n',$src);Invoke-VideoTool ffmpeg $args $log ''|Out-Null
        Invoke-VideoTool ffmpeg @('-nostdin','-v','error','-i',$src,'-map','0:v:0','-c','copy','-n',$dst) $log ''|Out-Null
        $a=Get-PacketManifest $src 0 $codec (Join-Path $root ($codec+'_source.packet.framehash')) $log ''
        $b=Get-PacketManifest $dst 0 $codec (Join-Path $root ($codec+'_output.packet.framehash')) $log ''
        $a.Manifest.Compare($b.Manifest,$true)
        Assert ($a.Packets -eq 200 -and $a.Sha256 -eq $b.Sha256) "$codec canonical SHA-256 checks all packets"
        $samples=@(Compare-SampledPixels @('-i',$src) 0 $dst $a.Manifest.Times() 0.04 (Join-Path $root ($codec+'_samples')) $log '')
        Assert ($samples.Count -gt 0 -and ($samples|ForEach-Object{[int]$_.frames}|Measure-Object -Sum).Sum -gt 0) "$codec decoded samples agree across recording gaps"
        $changed=[PortableVideo.PacketManifest]::Load($b.Path);$changed.Records[50].Hash=('0'*64)
        Reject {$a.Manifest.Compare($changed,$true)} "$codec detects a changed compressed packet"
        $changed=[PortableVideo.PacketManifest]::Load($b.Path);$changed.Records.RemoveAt(10)
        Reject {$a.Manifest.Compare($changed,$true)} "$codec detects a missing packet"
        $changed=[PortableVideo.PacketManifest]::Load($b.Path);$changed.Records[60].Pts+=0.1
        Reject {$a.Manifest.Compare($changed,$true)} "$codec detects a modified timestamp"
        $changed=[PortableVideo.PacketManifest]::Load($b.Path);$tmp=$changed.Records[60];$changed.Records[60]=$changed.Records[61];$changed.Records[61]=$tmp
        Reject {$a.Manifest.Compare($changed,$true)} "$codec detects reordered packets"
        $probe=Get-MediaProbe $dst $log '' $false
        Assert (!$probe.streams[0].PSObject.Properties['nb_read_packets']) 'Header-only probe does not perform another packet-count pass'
        if($codec -eq 'hevc'){
            $packets=Join-Path $root 'hevc-packets.txt';Invoke-VideoTool ffprobe @('-v','error','-select_streams','v','-show_packets','-show_entries','packet=stream_index,pts_time,flags','-of','compact=p=0:nk=0',$src) $log '' $packets
            $runs=@([PortableVideo.MediaPlanner]::ReadPackets($packets,0.04,2,$null));$offset=0;$n=0
            foreach($run in $runs){
                $part=Join-Path $root ("hevc_part_$n.mp4");$n++
                Copy-VideoRange $src 0 $a.Manifest $offset $run.Frames $part $log ''
                $d=Get-PacketManifest $part 0 $codec ($part+'.packet.framehash') $log ''
                $a.Manifest.Range($offset,[int]$run.Frames).Compare($d.Manifest,$true);$d.Manifest.CheckTimes($run.Times)
                @(Compare-SampledPixels @('-i',$src) $run.Start $part $run.Times 0.04 ($part+'.sample') $log '')|Out-Null
                $offset+=$run.Frames
            }
            Assert ($offset -eq 200) 'H.265 closed-GOP splits preserve all canonical packets and timings'
        }
        if($codec -eq 'h264'){
            $tampered=Join-Path $root 'tampered.mp4';$bytes=[IO.File]::ReadAllBytes($dst)
            $pos=-1;for($i=4;$i -lt $bytes.Length-32;$i++){if($bytes[$i]-eq 109 -and $bytes[$i+1]-eq 100 -and $bytes[$i+2]-eq 97 -and $bytes[$i+3]-eq 116){$pos=$i+20;break}}
            if($pos -lt 0){throw 'Fixture has no mdat'};$bytes[$pos]=$bytes[$pos] -bxor 1;[IO.File]::WriteAllBytes($tampered,$bytes)
            Reject {$t=Get-PacketManifest $tampered 0 $codec (Join-Path $root 'tampered.packet.framehash') $log '';$a.Manifest.Compare($t.Manifest,$true)} 'Detect mutation in an actual video file'
            $packets=Join-Path $root 'packets.txt';Invoke-VideoTool ffprobe @('-v','error','-select_streams','v','-show_packets','-show_entries','packet=stream_index,pts_time,flags','-of','compact=p=0:nk=0',$src) $log '' $packets
            $runs=@([PortableVideo.MediaPlanner]::ReadPackets($packets,0.04,2,$null));$offset=0;$n=0
            foreach($run in $runs){
                $part=Join-Path $root ("part_$n.mp4");$n++
                Copy-VideoRange $src 0 $a.Manifest $offset $run.Frames $part $log ''
                $d=Get-PacketManifest $part 0 $codec ($part+'.packet.framehash') $log ''
                $a.Manifest.Range($offset,[int]$run.Frames).Compare($d.Manifest,$true);$d.Manifest.CheckTimes($run.Times)
                $offset+=$run.Frames
            }
            Assert ($offset -eq 200) 'Duration splits account for every canonical packet, including keyframe boundaries'
            # Reuse cached manifests for a merge; no rereading input payloads for verification.
            $firstTimes=$b.Manifest.Times();$base=[datetime]::SpecifyKind([datetime]'2026-01-01',[DateTimeKind]::Utc)
            $o1=[pscustomobject]@{path=$dst;beginUtc=$base.ToString('o');lastFrameUtc=$base.AddSeconds($firstTimes[$firstTimes.Count-1]).ToString('o');packetManifest=$b.Path;packetSha256=$b.Sha256}
            $o2=$o1.PSObject.Copy();$o2.beginUtc=$base.AddSeconds(10).ToString('o');$o2.lastFrameUtc=$base.AddSeconds(19.96).ToString('o')
            $r1=[pscustomobject]@{status='verified';camera=[pscustomobject]@{CameraId='fixture';Camera='fixture'};timeline=[pscustomobject]@{frameInterval=0.04};outputs=@($o1)}
            $r2=[pscustomobject]@{status='verified';camera=$r1.camera;timeline=$r1.timeline;outputs=@($o2)}
            $merged=@(Merge-VerifiedResults @($r1,$r2) $root 0 '' 'stream_sample')
            Assert ($merged.Count -eq 1 -and $merged[0].status -eq 'verified' -and $merged[0].outputs[0].frames -eq 400) 'Fast merged verification reuses cached packet references and samples pixels'
            $mergeDir=Split-Path $merged[0].outputs[0].path
            Assert (@(Get-ChildItem -LiteralPath $mergeDir -Filter 'legacy_*').Count -eq 0) 'No fallback input hashing when verified packet caches exist'
            $pixelPath=Join-Path $root 'cached-full.framehash';$pixel=Get-FrameDigest $dst 0 $pixelPath $log ''
            foreach($o in @($o1,$o2)){$o|Add-Member -NotePropertyName pixelManifest -NotePropertyValue $pixelPath;$o|Add-Member -NotePropertyName pixelSha256 -NotePropertyValue $pixel.Sha256}
            $detailed=@(Merge-VerifiedResults @($r1,$r2) $root 0 '' 'decoded_full')
            Assert ($detailed[0].status -eq 'verified' -and $detailed[0].outputs[0].pixelSha256) 'Detailed merging verifies every decoded frame and reuses pixel caches'
        }
    }
    Write-Host "ALL $script:passed V3 CHECKS PASSED. Artifacts: $root" -ForegroundColor Green
}catch{Write-Host $_.Exception.ToString() -ForegroundColor Red;Write-Host $_.ScriptStackTrace;exit 1}
