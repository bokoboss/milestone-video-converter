function Write-ConcatList($Path, [string[]]$Files, [double[]]$Durations=@()) {
    $lines=@('ffconcat version 1.0')
    $i=0
    foreach($file in $Files) {
        $lines+="file '"+$file.Replace('\','/').Replace("'","'\''")+"'"
        if($i -lt $Durations.Count){$lines+='duration '+$Durations[$i].ToString('0.000000',[Globalization.CultureInfo]::InvariantCulture)}
        $i++
    }
    [IO.File]::WriteAllLines($Path,$lines,$script:Utf8)
}

function Get-MergeGroups($Results) {
    $items=@()
    foreach($result in $Results) {
        if($result.status -ne 'verified' -or !$result.PSObject.Properties['camera']) { continue }
        foreach($output in $result.outputs) {
            $items+=[pscustomobject]@{ CameraId=$result.camera.CameraId; Camera=$result.camera.Camera; Output=$output; Interval=[double]$result.timeline.frameInterval }
        }
    }
    foreach($camera in @($items | Group-Object CameraId)) {
        $group=@();$previous=$null
        foreach($item in @($camera.Group | Sort-Object { [datetime]$_.Output.beginUtc })) {
            if($previous) {
                $delta=([datetime]$item.Output.beginUtc-([datetime]$previous.Output.lastFrameUtc).AddSeconds($previous.Interval)).TotalSeconds
                if($delta -lt -0.002) { throw "Overlapping verified frames for $($item.Camera); cross-folder merge paused." }
                if([Math]::Abs($delta) -gt 0.002) { if($group.Count -gt 1){ ,$group };$group=@() }
            }
            $group+=$item;$previous=$item
        }
        if($group.Count -gt 1){ ,$group }
    }
}

function Merge-VerifiedResults($Results,$Output,[double]$SplitSeconds,$Cancel,$Mode='stream_sample',$Status='') {
    . "$PSScriptRoot\Verify.ps1"
    Initialize-Verification
    foreach($group in @(Get-MergeGroups $Results)) {
        Test-Cancel $Cancel
        $watch=[Diagnostics.Stopwatch]::StartNew()
        $dir=Join-Path $Output ('merged_'+[Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $log=Join-Path $dir 'merge.log'
        $report=[ordered]@{version=2;appVersion=$script:AppVersion;status='running';verificationMode=$Mode;cameraId=$group[0].CameraId;sources=@($group|ForEach-Object{$_.Output.path});outputs=@();error=$null;totalSeconds=0}
        try {
            $signatures=@();$codec=$null
            foreach($item in $group){
                $p=Invoke-VideoTool ffprobe @('-v','error','-show_streams','-show_data_hash','sha256','-of','json',$item.Output.path) $log $Cancel|ConvertFrom-Json
                $s=$p.streams[0];$codec=$s.codec_name
                $values=foreach($name in @('codec_name','profile','width','height','pix_fmt','time_base','extradata_hash','color_range','color_space','color_transfer','color_primaries')){if($s.PSObject.Properties[$name]){[string]$s.$name}else{''}}
                $signatures+=($values -join '|')
            }
            if(@($signatures|Select-Object -Unique).Count -ne 1){throw 'Stream configurations differ; individual files retained for review.'}
            if($Mode -eq 'stream_sample' -and !(Get-CanonicalFilter $codec)){throw 'Fast verification supports H.264/H.265. Select decoded_full.'}
            $durations=@()
            for($j=0;$j -lt $group.Count;$j++){
                $start=([datetime]$group[$j].Output.beginUtc).ToUniversalTime()
                $end=if($j+1 -lt $group.Count){([datetime]$group[$j+1].Output.beginUtc).ToUniversalTime()}else{([datetime]$group[$j].Output.lastFrameUtc).ToUniversalTime().AddSeconds($group[$j].Interval)}
                $durations+=($end-$start).TotalSeconds
            }
            $list=Join-Path $dir 'sources.ffconcat';Write-ConcatList $list @($group|ForEach-Object{$_.Output.path}) $durations
            $reference=New-Object PortableVideo.PacketManifest
            $globalStart=([datetime]$group[0].Output.beginUtc).ToUniversalTime();$i=0
            foreach($item in $group){
                $o=$item.Output
                if($o.PSObject.Properties['packetManifest'] -and (Test-Path -LiteralPath $o.packetManifest)){
                    $m=[PortableVideo.PacketManifest]::Load($o.packetManifest)
                    if(!$o.PSObject.Properties['packetSha256'] -or $m.Digest() -ne $o.packetSha256){throw 'Cached packet manifest checksum differs from the verified report.'}
                }else{
                    # Legacy reports have no packet cache; read compressed packets once, never decode the full input in fast mode.
                    $d=Get-PacketManifest $o.path 0 $codec (Join-Path $dir ("legacy_$i.packet.framehash")) $log $Cancel $Status
                    $m=$d.Manifest
                }
                $offset=(([datetime]$o.beginUtc).ToUniversalTime()-$globalStart).TotalSeconds
                $reference.Append($m,$offset);$i++
            }
            $arguments=@('-nostdin','-v','error','-f','concat','-safe','0','-i',$list,'-map','0:v:0','-c','copy','-an','-sn','-dn')
            if($SplitSeconds -gt 0){$arguments+=@('-f','segment','-segment_time',$SplitSeconds.ToString('0.######',[Globalization.CultureInfo]::InvariantCulture),'-reset_timestamps','1','-segment_format','mp4','-segment_format_options','movflags=+faststart','-n',(Join-Path $dir 'merged_%03d.partial.mp4'))}
            else{$arguments+=@('-movflags','+faststart','-n',(Join-Path $dir 'merged_000.partial.mp4'))}
            Invoke-VideoTool ffmpeg $arguments $log $Cancel|Out-Null
            $parts=@(Get-ChildItem -LiteralPath $dir -Filter '*.partial.mp4'|Sort-Object Name)
            if(!$parts.Count){throw 'Merge produced no files.'}
            $verified=@();$offset=0
            foreach($part in $parts){
                $d=Get-PacketManifest $part.FullName 0 $codec ($part.FullName+'.packet.framehash') $log $Cancel $Status
                if($offset+$d.Packets -gt $reference.Records.Count){throw 'Merged output contains extra packets.'}
                $expected=$reference.Range($offset,$d.Packets);$expected.Compare($d.Manifest,($Mode -eq 'stream_sample'))
                $times=$expected.Times();$samples=@();$pixel=$null
                if($Mode -eq 'stream_sample'){
                    $samples=@(Compare-SampledPixels @('-f','concat','-safe','0','-i',$list) $times[0] $part.FullName $times $group[0].Interval ($part.FullName+'.sample') $log $Cancel $Status)
                }
                $verified+=[pscustomobject]@{Part=$part;Digest=$d;Times=$times;Samples=$samples;Pixel=$pixel}
                $offset+=$d.Packets
            }
            if($offset -ne $reference.Records.Count){throw 'Merged output omits source packets.'}
            if($Mode -eq 'decoded_full'){
                $expectedFile=Join-Path $dir 'expected.framehash';$writer=New-Object IO.StreamWriter($expectedFile,$false,$script:Utf8)
                try{
                    $i=0
                    foreach($item in $group){
                        $o=$item.Output;$hash=Join-Path $dir ("input_$i.framehash");$i++
                        if($o.PSObject.Properties['pixelManifest'] -and $o.pixelManifest -and (Test-Path -LiteralPath $o.pixelManifest)){
                            $hash=$o.pixelManifest
                            if((Get-DigestFromFramehash $hash).Sha256 -ne $o.pixelSha256){throw 'Cached decoded manifest differs from report.'}
                        }else{Get-FrameDigest $o.path 0 $hash $log $Cancel|Out-Null}
                        foreach($line in [IO.File]::ReadLines($hash)){if(!$line.StartsWith('#') -and $line.Trim()){$writer.WriteLine($line)}}
                    }
                }finally{$writer.Dispose()}
                $actualFile=Join-Path $dir 'actual.framehash';$writer=New-Object IO.StreamWriter($actualFile,$false,$script:Utf8)
                try{foreach($v in $verified){$hash=$v.Part.FullName+'.framehash';$v.Pixel=Get-FrameDigest $v.Part.FullName 0 $hash $log $Cancel;foreach($line in [IO.File]::ReadLines($hash)){if(!$line.StartsWith('#') -and $line.Trim()){$writer.WriteLine($line)}}}}finally{$writer.Dispose()}
                $a=Get-DigestFromFramehash $expectedFile;$b=Get-DigestFromFramehash $actualFile
                if($a.Frames -ne $b.Frames -or $a.Sha256 -ne $b.Sha256){throw 'Merged decoded pixels differ.'}
            }
            Test-Cancel $Cancel
            foreach($v in $verified){
                $final=$v.Part.FullName.Replace('.partial.mp4','.mp4');[IO.File]::Move($v.Part.FullName,$final)
                $report.outputs+=@{path=$final;frames=$v.Digest.Packets;firstOutputPts=$v.Digest.Manifest.Times()[0];packetSha256=$v.Digest.Sha256;packetManifest=$v.Digest.Path;verificationMode=$Mode;decodedSamples=@($v.Samples);pixelSha256=$(if($v.Pixel){$v.Pixel.Sha256}else{$null});pixelManifest=$(if($v.Pixel){$v.Part.FullName+'.framehash'}else{$null});beginUtc=$globalStart.AddSeconds($v.Times[0]).ToString('o');lastFrameUtc=$globalStart.AddSeconds($v.Times[$v.Times.Count-1]).ToString('o')}
            }
            $report.status='verified'
        }catch{$report.status=if($Cancel -and (Test-Path -LiteralPath $Cancel)){'cancelled'}else{'needs_review'};$report.error=$_.Exception.ToString()}
        $report.totalSeconds=$watch.Elapsed.TotalSeconds
        Write-JsonFile (Join-Path $dir 'report.json') $report
        [pscustomobject]$report
    }
}
