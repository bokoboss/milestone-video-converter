param([switch]$SmokeTest)
. "$PSScriptRoot\Core.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='Portable CCTV Converter v3 | แปลงวิดีโอสำหรับนับรถ'
$form.Size=New-Object Drawing.Size(1040,760)
$form.MinimumSize=New-Object Drawing.Size(850,650)
$form.StartPosition='CenterScreen';$form.AutoScaleMode='Dpi'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$layout=New-Object Windows.Forms.TableLayoutPanel
$layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(16)
$layout.ColumnCount=1;$layout.RowCount=8
foreach($height in @(55,44,0,44,76,44,28,105)){
    $style=New-Object Windows.Forms.RowStyle
    if($height -eq 0){$style.SizeType='Percent';$style.Height=100}else{$style.SizeType='Absolute';$style.Height=$height}
    $layout.RowStyles.Add($style)|Out-Null
}
$form.Controls.Add($layout)
$intro=New-Object Windows.Forms.Label
$intro.Text="เลือกชุดไฟล์บันทึกครบทั้งโฟลเดอร์ แล้วแปลงเป็น MP4 โดยไม่บีบอัดภาพซ้ำ`r`nโหมดเร็วตรวจสตรีมครบและสุ่มภาพ • ไฟล์ยังมีขนาดใกล้ต้นฉบับ • ทำงานได้โดยไม่ใช้อินเทอร์เน็ต"
$intro.Dock='Fill';$layout.Controls.Add($intro,0,0)
function New-Button($Text,$Name){$b=New-Object Windows.Forms.Button;$b.Text=$Text;$b.AutoSize=$true;$b.Height=32;$b.AccessibleName=$Name;return $b}
$sourceButtons=New-Object Windows.Forms.FlowLayoutPanel;$sourceButtons.Dock='Fill'
$add=New-Button '&เพิ่มโฟลเดอร์...' 'เพิ่มโฟลเดอร์บันทึก';$remove=New-Button '&ลบรายการที่เลือก' 'ลบรายการที่เลือก';$check=New-Button 'ตรวจความพร้อม' 'ตรวจความพร้อมเครื่อง'
$sourceButtons.Controls.AddRange(@($add,$remove,$check));$layout.Controls.Add($sourceButtons,0,1)
$list=New-Object Windows.Forms.ListView
$list.View='Details';$list.CheckBoxes=$true;$list.FullRowSelect=$true;$list.Dock='Fill';$list.HideSelection=$false
$list.AccessibleName='คิวกล้อง เลือกเครื่องหมายถูกหน้ากล้องที่ต้องการแปลง'
foreach($col in @(@('กล้อง',210),@('เริ่ม (+07:00)',160),@('สิ้นสุด (+07:00)',160),@('โฟลเดอร์ต้นทาง',430))){$list.Columns.Add($col[0],[int]$col[1])|Out-Null}
$layout.Controls.Add($list,0,2)
$outRow=New-Object Windows.Forms.TableLayoutPanel;$outRow.Dock='Fill';$outRow.ColumnCount=3
$outRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',95)))|Out-Null
$outRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))|Out-Null
$outRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',110)))|Out-Null
$outLabel=New-Object Windows.Forms.Label;$outLabel.Text='ปลายทาง';$outLabel.Dock='Fill';$outLabel.TextAlign='MiddleLeft'
$out=New-Object Windows.Forms.TextBox;$out.Dock='Fill';$out.AccessibleName='โฟลเดอร์ปลายทาง';$out.Text=Join-Path $PSScriptRoot 'output'
$browse=New-Button 'เลือก...' 'เลือกโฟลเดอร์ปลายทาง'
$outRow.Controls.Add($outLabel,0,0);$outRow.Controls.Add($out,1,0);$outRow.Controls.Add($browse,2,0);$layout.Controls.Add($outRow,0,3)
$options=New-Object Windows.Forms.FlowLayoutPanel;$options.Dock='Fill'
$splitLabel=New-Object Windows.Forms.Label;$splitLabel.Text='แบ่งไฟล์ (นาที):';$splitLabel.AutoSize=$true;$splitLabel.Margin=New-Object Windows.Forms.Padding(0,6,4,0)
$split=New-Object Windows.Forms.ComboBox;$split.Width=150;$split.DropDownStyle='DropDown';$split.AccessibleName='ระยะเวลาต่อไฟล์เป็นนาที หรือรวมไฟล์เดียว'
$split.Items.AddRange(@('รวมไฟล์เดียว','10','15','30','60','120'));$split.SelectedIndex=0
$merge=New-Object Windows.Forms.CheckBox;$merge.Text='รวมข้ามโฟลเดอร์ (กล้องเดียวกันและเวลาต่อเนื่อง)';$merge.AutoSize=$true;$merge.AccessibleName=$merge.Text
$options.Controls.AddRange(@($splitLabel,$split,$merge));$layout.Controls.Add($options,0,4)
$options.SetFlowBreak($merge,$true)
$verifyLabel=New-Object Windows.Forms.Label;$verifyLabel.Text='ตรวจผล:';$verifyLabel.AutoSize=$true;$verifyLabel.Margin=New-Object Windows.Forms.Padding(0,6,4,0)
$verification=New-Object Windows.Forms.ComboBox;$verification.Width=340;$verification.DropDownStyle='DropDownList';$verification.AccessibleName='วิธีตรวจผลวิดีโอ'
$verification.Items.AddRange(@('เร็ว: ตรวจสตรีมครบ + สุ่มภาพ','ละเอียด: ตรวจภาพทุกเฟรม'));$verification.SelectedIndex=0
$options.Controls.AddRange(@($verifyLabel,$verification))
$actions=New-Object Windows.Forms.FlowLayoutPanel;$actions.Dock='Fill'
$start=New-Button '&เริ่มแปลง' 'เริ่มแปลงไฟล์ที่เลือก';$cancelButton=New-Button '&ยกเลิก' 'ยกเลิกงานปัจจุบัน';$cancelButton.Enabled=$false
$open=New-Button 'เปิดปลายทาง' 'เปิดโฟลเดอร์ผลลัพธ์'
$actions.Controls.AddRange(@($start,$cancelButton,$open));$layout.Controls.Add($actions,0,5)
$progress=New-Object Windows.Forms.ProgressBar;$progress.Dock='Fill';$progress.AccessibleName='ความคืบหน้าการแปลง';$layout.Controls.Add($progress,0,6)
$messages=New-Object Windows.Forms.TextBox;$messages.Multiline=$true;$messages.ReadOnly=$true;$messages.ScrollBars='Vertical';$messages.Dock='Fill';$messages.AccessibleName='สถานะและข้อผิดพลาด'
$messages.Text='พร้อมใช้งาน: เพิ่มโฟลเดอร์ แล้วเลือกกล้องที่ต้องการ ไม่แก้ไขไฟล์ต้นฉบับ'
$layout.Controls.Add($messages,0,7)
$script:queueProcess=$null;$script:session=$null;$script:statusPath=$null;$script:cancelPath=$null;$script:lastStatus='';$script:closingAfterCancel=$false
function Show-Error($Exception){$messages.Text=$Exception.Message;[Windows.Forms.MessageBox]::Show($form,$Exception.Message,'ตรวจสอบข้อมูล','OK','Error')|Out-Null}
function Choose-Folder($Description,$Initial){$d=New-Object Windows.Forms.FolderBrowserDialog;$d.Description=$Description;if($Initial){$d.SelectedPath=$Initial};try{if($d.ShowDialog($form)-eq 'OK'){return $d.SelectedPath}}finally{$d.Dispose()}}
function Set-Busy($Busy){foreach($c in @($add,$remove,$check,$out,$browse,$split,$merge,$verification,$list,$start)){$c.Enabled=!$Busy};$cancelButton.Enabled=$Busy}
$add.Add_Click({
    $folder=Choose-Folder 'เลือกโฟลเดอร์ที่มี SmartClient-Player และ Client Files' ''
    if(!$folder){return}
    try{
        $cameras=@(Get-SourceCameras $folder)
        if(!$cameras.Count){throw 'ไม่พบกล้องในโฟลเดอร์นี้'}
        foreach($camera in $cameras){
            $duplicate=@($list.Items|Where-Object{$_.Tag.Project -eq $camera.Project -and $_.Tag.CameraId -eq $camera.CameraId})
            if($duplicate.Count){continue}
            $item=New-Object Windows.Forms.ListViewItem($camera.Camera);$item.Checked=$true;$item.Tag=$camera
            $item.SubItems.Add(([datetime]$camera.BeginUtc).ToUniversalTime().AddHours(7).ToString('yyyy-MM-dd HH:mm:ss'))|Out-Null
            $item.SubItems.Add(([datetime]$camera.EndUtc).ToUniversalTime().AddHours(7).ToString('yyyy-MM-dd HH:mm:ss'))|Out-Null
            $item.SubItems.Add($camera.Source)|Out-Null;$list.Items.Add($item)|Out-Null
        }
        $messages.Text="พบกล้องพร้อมเข้าคิว $($list.Items.Count) รายการ เลือกเครื่องหมายถูกหน้ากล้องที่ต้องการ"
    }catch{Show-Error $_.Exception}
})
$remove.Add_Click({foreach($item in @($list.SelectedItems)){$list.Items.Remove($item)}})
$browse.Add_Click({$folder=Choose-Folder 'เลือกปลายทางสำหรับไฟล์และรายงาน' $out.Text;if($folder){$out.Text=$folder}})
$open.Add_Click({try{if(Test-Path -LiteralPath $out.Text){Start-Process -FilePath explorer.exe -ArgumentList (Quote-NativeArgument $out.Text)}}catch{Show-Error $_.Exception}})
$check.Add_Click({
    try{
        $scriptPath=Join-Path $PSScriptRoot 'Setup.ps1'
        Start-Process -FilePath (Get-PowerShellHost) -ArgumentList ((@('-NoProfile','-NoExit','-File',$scriptPath)|ForEach-Object{Quote-NativeArgument $_})-join ' ') -WindowStyle Normal|Out-Null
    }catch{Show-Error $_.Exception}
})
$start.Add_Click({
    try{
        $cameras=@($list.CheckedItems|ForEach-Object{$_.Tag})
        if(!$cameras.Count){throw 'กรุณาเลือกกล้องอย่างน้อยหนึ่งรายการ'}
        $segmentMinutes=0
        if($split.Text.Trim() -ne 'รวมไฟล์เดียว'){
            if(![int]::TryParse($split.Text.Trim(),[ref]$segmentMinutes) -or $segmentMinutes -le 0){throw 'ระบุจำนวนนาทีเป็นจำนวนเต็มบวก เช่น 10, 15, 30, 60, 120 หรือเลือก รวมไฟล์เดียว'}
        }
        $destination=[IO.Path]::GetFullPath($out.Text.Trim())
        foreach($camera in $cameras){
            if($destination.TrimEnd('\').Equals($camera.Source.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase) -or $destination.StartsWith($camera.Source.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'เลือกปลายทางนอกโฟลเดอร์ต้นฉบับ เพื่อไม่เขียนข้อมูลลงในชุดบันทึก'}
        }
        New-Item -ItemType Directory -Path $destination -Force|Out-Null
        $script:session=Join-Path $destination ('queue_'+[Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $script:session|Out-Null
        $script:statusPath=Join-Path $script:session 'status.json';$script:cancelPath=Join-Path $script:session 'cancel'
        $request=Join-Path $script:session 'request.json'
        Write-JsonFile $request ([ordered]@{Cameras=$cameras;Output=$destination;Session=$script:session;Status=$script:statusPath;Cancel=$script:cancelPath;SegmentMinutes=$segmentMinutes;VerificationMode=$(if($verification.SelectedIndex -eq 0){'stream_sample'}else{'decoded_full'});Merge=$merge.Checked})
        $info=New-Object Diagnostics.ProcessStartInfo;$info.FileName=Get-PowerShellHost
        $info.Arguments=(@('-NoProfile','-File',"$PSScriptRoot\Queue.ps1",'-Request',$request)|ForEach-Object{Quote-NativeArgument $_})-join ' '
        $info.UseShellExecute=$false;$info.CreateNoWindow=$true
        $script:queueProcess=[Diagnostics.Process]::Start($info);$script:lastStatus='';$progress.Value=0;Set-Busy $true
        $messages.Text='กำลังเริ่มงาน... ผลที่ตรวจผ่านจะลงท้าย .mp4 ส่วนไฟล์ .partial.mp4 ยังไม่ถือว่าสำเร็จ'
    }catch{Show-Error $_.Exception}
})
$cancelButton.Add_Click({if($script:cancelPath){[IO.File]::WriteAllText($script:cancelPath,'cancel');$cancelButton.Enabled=$false;$messages.Text='กำลังยกเลิกและปิดไฟล์อย่างปลอดภัย กรุณารอ...'}})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=500
$timer.Add_Tick({
    if(!$script:queueProcess){return}
    if(Test-Path -LiteralPath $script:statusPath){
        try{
            $state=Get-Content -LiteralPath $script:statusPath -Raw -Encoding UTF8|ConvertFrom-Json
            $progress.Style=if($state.stage -in @('scan','inspect','verify','merge')){'Marquee'}else{'Continuous'}
            $progress.Value=[Math]::Max(0,[Math]::Min(100,[int]$state.percent))
            $text=$state.stage+": "+$state.message
            if($text -ne $script:lastStatus){$messages.Text=$text;$script:lastStatus=$text}
        }catch{}
    }
    if($script:queueProcess.HasExited){
        if($script:queueProcess.ExitCode -ne 0 -and !(Test-Path -LiteralPath $script:statusPath)){$messages.Text='เริ่มงานไม่สำเร็จ ตรวจ PowerShell policy และรัน setup.bat เพื่อดูรายละเอียด'}
        $script:queueProcess.Dispose();$script:queueProcess=$null;Set-Busy $false
        $progress.Style='Continuous'
        $messages.AppendText("`r`nรายงาน: "+(Join-Path $script:session 'queue-report.json'))
        if($script:closingAfterCancel){$form.Close()}
    }
})
$form.Add_FormClosing({param($sender,$eventArgs)
    if($script:queueProcess -and !$script:queueProcess.HasExited){
        $eventArgs.Cancel=$true;$script:closingAfterCancel=$true
        [IO.File]::WriteAllText($script:cancelPath,'cancel');$messages.Text='กำลังหยุดงานก่อนปิดหน้าต่าง...'
    }
})
$timer.Start()
try{
    if($SmokeTest){
        $form.Show();[Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($form.Width,$form.Height)
        try{$form.DrawToBitmap($bitmap,(New-Object Drawing.Rectangle(0,0,$form.Width,$form.Height)));$bitmap.Save((Join-Path $PSScriptRoot 'tests\ui-preview.png'),[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose()}
        Write-Output 'UI smoke test passed';$form.Close()
    }else{[Windows.Forms.Application]::Run($form)}
}finally{$timer.Stop();$timer.Dispose();$form.Dispose()}
