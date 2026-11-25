param(
    [ValidateSet('Status','Install','Rollback')][string]$Mode='Status',
    [string]$Port='COM13',
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-f]{32}$')][string]$ExpectedCid,
    [Parameter(Mandatory=$true)][string]$FactoryBackup,
    [string]$BundleDir=$PSScriptRoot,
    [switch]$AcceptNoRecovery
)
$ErrorActionPreference='Stop'
if ($Mode -eq 'Install' -and !$AcceptNoRecovery) {throw 'Install requires -AcceptNoRecovery. Cold FEL and independent recovery are NOT proven.'}
$d=(Resolve-Path -LiteralPath $BundleDir).Path
. "$PSScriptRoot/transport.ps1"
function Get-Sha256([byte[]]$Bytes) {
    $sha=[System.Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
$backup=[byte[]]::new(40960)
$stream=[IO.File]::OpenRead((Resolve-Path -LiteralPath $FactoryBackup).Path)
try {
    $pos=0
    while ($pos -lt $backup.Length) {
        $n=$stream.Read($backup,$pos,$backup.Length-$pos)
        if ($n -le 0) {throw 'Factory backup is too short'}
        $pos+=$n
    }
} finally {$stream.Dispose()}
if ((Get-Sha256 $backup) -cne '6a3fcb2ed0c95d01799df6c9c3e7a3e6ed1045e4028fe1164a9ba44a81b56f4f') {throw 'Factory prefix mismatch; use the original user-area dump of the validated board'}
$files=@('BT0-uncaged.bin','stage.sh')
$expected=@{}
foreach ($line in (Get-Content -LiteralPath "$d/SHA256SUMS")) {
    if ($line -notmatch '^([a-f0-9]{64})  ([A-Za-z0-9._-]+)$') {throw 'Malformed manifest'}
    $expected[$Matches[2]]=$Matches[1]
}
$data=@{'factory-first80.bin'=$backup}
foreach ($name in $files) {
    if (!$expected.ContainsKey($name)) {throw "Missing hash: $name"}
    $bytes=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath "$d/$name").Path)
    if ((Get-Sha256 $bytes) -cne $expected[$name]) {throw "Hash mismatch: $name"}
    $data[$name]=$bytes
}
if ((Get-Sha256 $data['BT0-uncaged.bin']) -cne '39e4a51962e7288ddbef7dcecfbf508d43e23d3e59b2e970896dd2393f9824ae') {throw 'Not the physically validated SPL'}
$serial=[IO.Ports.SerialPort]::new($Port,115200)
$serial.ReadTimeout=1000
$serial.WriteTimeout=15000
$serial.DtrEnable=$true
$serial.RtsEnable=$true
$serial.Open()
try {
    $serial.Write([string][char]3+[string][char]10)
    $path='/run/bt0-uncaged'
    Invoke-Device "mkdir -p $path"
    foreach ($name in @('factory-first80.bin','BT0-uncaged.bin','stage.sh')) {
        Write-Host "Transferring $name to RAM"
        $bytes=$data[$name]
        $hash=Get-Sha256 $bytes
        Invoke-Device "cd $path && : > $name"
        $command='(set -eu; cd /run/bt0-uncaged; t=$(stty -g); trap ''stty "$t"'' EXIT; stty raw -echo; printf ''\nPB626_READY\n''; timeout 15 head -c LEN > piece; stty "$t"; echo ''HASH  piece'' | sha256sum -c -; cat piece > NAME)'
        $command=$command.Replace('LEN',"$($bytes.Length)").Replace('HASH',$hash).Replace('NAME',$name)
        $null=Invoke-Device $command -Payload $bytes -TimeoutSeconds 30
        Invoke-Device "cd $path && echo '$hash  $name' | sha256sum -c -"
    }
    $marker=switch ($Mode) {
        'Status' {'PRIMARY_PREFLIGHT_OK'}
        'Install' {'PRIMARY_V2_INSTALLED_VERIFIED'}
        'Rollback' {'FACTORY_BT0_RESTORED_VERIFIED'}
    }
    $flag=if ($Mode -eq 'Install') {' --accept-no-recovery'} else {''}
    $result=@(Invoke-Device "/bin/sh $path/stage.sh $($Mode.ToLowerInvariant()) $ExpectedCid$flag" -TimeoutSeconds 180)
    $result
    if ($result -cnotcontains $marker) {throw 'Expected marker missing. DO NOT REBOOT.'}
} finally { $serial.Dispose() }
