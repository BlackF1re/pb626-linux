param(
    [ValidateSet('Status','Install','Rollback')][string]$Mode='Status',
    [string]$Port='COM13',
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedCid,
    [string]$NewImage,
    [string]$RollbackImage
)
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../BT0-uncaged/transport.ps1"
function Get-Sha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally {$sha.Dispose()}
}
$files=@{'stage.sh'=(Join-Path $PSScriptRoot 'stage.sh')}
$send=@('stage.sh')
if($Mode -ne 'Status'){
    if(!$RollbackImage -or (Get-FileHash -LiteralPath $RollbackImage -Algorithm SHA256).Hash.ToLowerInvariant() -cne '5f98e5c1b946ef50e9331074494191f6df5b3f662be28b627ea184598538e301'){throw 'Exact full off-device rollback image required'}
}
if($Mode -eq 'Install'){
    if(!$NewImage -or (Get-FileHash -LiteralPath $NewImage -Algorithm SHA256).Hash.ToLowerInvariant() -cne '33380f0bf21a7ba8b0480d7c545609bf0c05b9b5999c8bf3cced9dd16283384e'){throw 'Exact tested new image required'}
    $files['raw-linux-mbusfix.img']=$NewImage; $send+='raw-linux-mbusfix.img'
}
if($Mode -eq 'Rollback'){$files['raw-linux-fast-rollback.img']=$RollbackImage; $send+='raw-linux-fast-rollback.img'}
$serial=[IO.Ports.SerialPort]::new($Port,115200)
$serial.ReadTimeout=1000; $serial.WriteTimeout=15000
$serial.DtrEnable=$true; $serial.RtsEnable=$true
$serial.Open()
try {
    $serial.Write([string][char]3+[string][char]10)
    $path='/run/pb626-mbus-install'
    Invoke-Device "mkdir -p $path"
    foreach($name in $send) {
        Write-Host "Transferring $name to RAM"
        $data=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $files[$name]))
        $hash=Get-Sha256 $data
        Invoke-Device "cd $path && : > $name"
        for($off=0;$off -lt $data.Length;$off+=$len) {
            $len=[Math]::Min(256KB,$data.Length-$off)
            $piece=[byte[]]::new($len); [Array]::Copy($data,$off,$piece,0,$len)
            $command='(set -eu; cd /run/pb626-mbus-install; t=$(stty -g); trap ''stty "$t"'' EXIT; stty raw -echo; printf ''\nPB626_READY\n''; timeout 15 head -c LEN > piece; stty "$t"; echo ''HASH  piece'' | sha256sum -c -; cat piece >> NAME)'
            $command=$command.Replace('LEN',"$len").Replace('HASH',(Get-Sha256 $piece)).Replace('NAME',$name)
            $null=Invoke-Device $command -Payload $piece -TimeoutSeconds 30
        }
        Invoke-Device "cd $path && echo '$hash  $name' | sha256sum -c -"
    }
    $marker=switch($Mode){'Status'{'MBUS_INSTALL_PREFLIGHT_OK'} 'Install'{'MBUS_KERNEL_INSTALLED_VERIFIED'} 'Rollback'{'MBUS_KERNEL_ROLLBACK_VERIFIED'}}
    $result=@(Invoke-Device "/bin/sh $path/stage.sh $($Mode.ToLowerInvariant()) $ExpectedCid" -TimeoutSeconds 180)
    $result
    if($result -cnotcontains $marker){throw 'Expected marker missing. DO NOT REBOOT.'}
} finally {$serial.Dispose()}
