param([ValidateSet('Status','Install','Rollback')][string]$Mode='Status',[string]$Port='COM13')
$ErrorActionPreference='Stop'
$d=$PSScriptRoot
. "$d/transport.ps1"
function Get-Sha256([byte[]]$Bytes) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-','').ToLowerInvariant() }
    finally {$sha.Dispose()}
}
$files=@{'stage.sh'=(Join-Path $d 'stage.sh')}
$expected=@{}
foreach($line in (Get-Content -LiteralPath "$d/out/SHA256SUMS")) {
    if($line -notmatch '^([a-f0-9]{64})  ([A-Za-z0-9._-]+)$'){throw 'Malformed manifest'}
    $expected[$Matches[2]]=$Matches[1]
}
foreach($name in @('pb626-x11-epd-preclear','xsession.original','xsession.experimental')) {
    $files[$name]=Join-Path "$d/out" $name
    if(!$expected.ContainsKey($name) -or (Get-FileHash -LiteralPath $files[$name] -Algorithm SHA256).Hash.ToLowerInvariant() -cne $expected[$name]){throw "Hash mismatch: $name"}
}
$serial=[IO.Ports.SerialPort]::new($Port,115200)
$serial.ReadTimeout=1000
$serial.WriteTimeout=15000
$serial.DtrEnable=$true
$serial.RtsEnable=$true
$serial.Open()
try {
    $serial.Write([string][char]3+[string][char]10)
    $path='/run/pb626-preclear-test'
    Invoke-Device "mkdir -p $path"
    foreach($name in @('stage.sh','xsession.original','xsession.experimental','pb626-x11-epd-preclear')) {
        Write-Host "Transferring $name to RAM"
        $data=[IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $files[$name]))
        $hash=Get-Sha256 $data
        Invoke-Device "cd $path && : > $name"
        # Short ASCII commands avoid intermittent USB ACM raw-transfer corruption.
        # A retry overwrites the same block; it cannot append duplicate bytes.
        $blockSize=768
        for($off=0;$off -lt $data.Length;$off+=$len) {
            $len=[Math]::Min($blockSize,$data.Length-$off)
            $piece=[byte[]]::new($len)
            [Array]::Copy($data,$off,$piece,0,$len)
            $encoded=[Convert]::ToBase64String($piece)
            $block=[int]($off/$blockSize)
            $pieceHash=Get-Sha256 $piece
            $command="(set -eu; cd $path; printf '%s' '$encoded' | base64 -d > piece; echo '$pieceHash  piece' | sha256sum -c -; dd if=piece of=$name bs=$blockSize seek=$block conv=notrunc 2>/dev/null)"
            for($attempt=1;$attempt -le 3;$attempt++) {
                try {
                    $null=Invoke-Device $command -TimeoutSeconds 15
                    break
                } catch {
                    if($attempt -eq 3){throw}
                    Write-Warning "Retrying $name block $block (attempt $attempt failed)"
                }
            }
        }
        Invoke-Device "cd $path && echo '$hash  $name' | sha256sum -c -"
    }
    $marker=switch($Mode){'Status'{'PRECLEAR_PREFLIGHT_OK'} 'Install'{'PRECLEAR_INSTALLED_VERIFIED'} 'Rollback'{'PRECLEAR_ROLLBACK_VERIFIED'}}
    $result=@(Invoke-Device "/bin/sh $path/stage.sh $($Mode.ToLowerInvariant())" -TimeoutSeconds 30)
    $result
    if($result -cnotcontains $marker){throw 'Expected marker missing. DO NOT REBOOT.'}
} finally {$serial.Dispose()}
