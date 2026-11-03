function Initialize-Verification {
    if(!('PortableVideo.PacketManifest' -as [type])){Add-Type -Path "$PSScriptRoot\Verification.cs"}
}
function Get-VerificationMode($Settings) {
    $mode='stream_sample'
    if($Settings.PSObject.Properties['VerificationMode']){$mode=[string]$Settings.VerificationMode}
    if($mode -notin @('stream_sample','decoded_full')){throw 'Unknown verification mode.'}
    return $mode
}
function Get-CanonicalFilter($Codec) {
    switch($Codec){'h264'{return 'h264_mp4toannexb'}'hevc'{return 'hevc_mp4toannexb'}default{return ''}}
}
function Assert-VideoMetadata($Source,$Output) {
    foreach($name in @('codec_name','width','height','color_range','color_space','color_transfer','color_primaries','sample_aspect_ratio','field_order')){
        if($Source.PSObject.Properties[$name] -and [string]$Source.$name -notin @('','unknown','unspecified','N/A','0:1')){
            if(!$Output.PSObject.Properties[$name] -or [string]$Source.$name -ne [string]$Output.$name){throw "Output video metadata differs: $name"}
        }
    }
}
function Get-PacketManifest($Path,$Stream,$Codec,$Destination,$Log,$Cancel,$Status='',$Expected=0,$Stage='verify',$Percent=65) {
    Initialize-Verification
    $arguments=@('-nostdin','-v','error','-i',$Path,'-map',"0:$Stream",'-c:v','copy','-an','-sn','-dn')
    $filter=Get-CanonicalFilter $Codec
    if($filter){$arguments+=@('-bsf:v',$filter)}
    $arguments+=@('-f','framehash','-hash','sha256','-n',$Destination)
    $counter=New-Object PortableVideo.HashProgress
    $heartbeat={param($seconds,$bytes)
        try{$count=$counter.Read($Destination)}catch [IO.IOException]{$count=$counter.Count}
        Set-JobStatus $Status $Stage $Percent "Checking compressed packets: $count / $Expected; $seconds s..."
    }
    $watch=[Diagnostics.Stopwatch]::StartNew()
    Invoke-VideoTool ffmpeg $arguments $Log $Cancel '' $heartbeat|Out-Null
    $manifest=[PortableVideo.PacketManifest]::Load($Destination)
    [pscustomobject]@{Manifest=$manifest;Path=$Destination;Packets=$manifest.Records.Count;Sha256=$manifest.Digest();Seconds=$watch.Elapsed.TotalSeconds}
}
function Copy-VideoRange($InputPath,$Stream,$Reference,$Offset,$Count,$Destination,$Log,$Cancel) {
    $key=$Reference.Records[[int]$Offset]
    $coarse=[Math]::Max(0.0,[Math]::Min($key.Pts,$key.Dts)-2.0)
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $arguments=@('-nostdin','-v','error','-ss',$coarse.ToString('0.000000',$culture),'-i',$InputPath)
    # Input seeking can land at an earlier Matroska cue. Trim compressed packets
    # at the target keyframe's decoding timestamp, then copy the exact packet count.
    if($Offset -gt 0){$arguments+=@('-ss',([Math]::Max(0.0,$key.Dts-$coarse-0.000001)).ToString('0.000000',$culture))}
    $arguments+=@('-map',"0:$Stream",'-frames:v',[string]$Count,'-c','copy','-an','-sn','-dn','-map_metadata','-1','-avoid_negative_ts','make_zero','-movflags','+faststart','-n',$Destination)
    Invoke-VideoTool ffmpeg $arguments $Log $Cancel|Out-Null
}
function Get-DecodedSample([string[]]$InputArguments,$Start,$End,$Destination,$Log,$Cancel,$ExpectedFrames=0) {
    $culture=[Globalization.CultureInfo]::InvariantCulture
    $arguments=@('-nostdin','-v','error','-xerror','-err_detect','explode','-ss',([double]$Start).ToString('0.000000',$culture))
    $arguments+=$InputArguments
    if($ExpectedFrames -gt 0){$arguments+=@('-frames:v',[string]$ExpectedFrames)}else{$arguments+=@('-t',([double]($End-$Start)).ToString('0.000000',$culture))}
    $arguments+=@('-map','0:v:0','-an','-sn','-dn','-noautoscale','-fps_mode','passthrough','-enc_time_base','1:1000000','-f','framehash','-hash','sha256','-n',$Destination)
    Invoke-VideoTool ffmpeg $arguments $Log $Cancel|Out-Null
    return (Get-DigestFromFramehash $Destination)
}
function Compare-SampledPixels([string[]]$SourceArguments,$SourceOffset,$Output,$Times,$Interval,$Prefix,$Log,$Cancel,$Status='') {
    Initialize-Verification
    $samples=@();$i=0
    foreach($window in [PortableVideo.PacketManifest]::Windows($Times,$Interval)) {
        Test-Cancel $Cancel;$i++
        Set-JobStatus $Status 'verify' 95 "Decoding sample window $i (start/middle/end and recording gaps)..."
        $a=Get-DecodedSample $SourceArguments ($SourceOffset+$window.Start) ($SourceOffset+$window.End) ($Prefix+"_source_$i.framehash") $Log $Cancel $window.Frames
        $b=Get-DecodedSample @('-i',$Output) $window.Start $window.End ($Prefix+"_output_$i.framehash") $Log $Cancel $window.Frames
        if($a.Frames -ne $window.Frames -or $b.Frames -ne $a.Frames -or $b.Sha256 -ne $a.Sha256){throw "Decoded sample mismatch at offset $($window.Start) s."}
        $samples+=[ordered]@{startSeconds=$window.Start;endSeconds=$window.End;frames=$a.Frames;pixelSha256=$a.Sha256}
    }
    return $samples
}
