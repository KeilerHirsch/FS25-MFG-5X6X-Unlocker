# Driver-only export tests. Never touch the game EXE, driver profile, or installed DLLs.
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot '..\src\FS25_MFG_Unlocker.ps1'
$source = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $sourcePath).Path)
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "PowerShell parse failed: $($parseErrors -join '; ')" }
foreach ($name in @('Export-MfgDriverNip','Get-MfgDriverTestReadiness')) {
    $func = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name
    }, $true))
    if ($func.Count -ne 1) { throw "Expected exactly one $name function." }
    . ([scriptblock]::Create($func[0].Extent.Text))
}
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
$dir = Join-Path ([IO.Path]::GetTempPath()) ('FS25_NPI_TEST_' + [Guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $dir)
try {
    foreach ($n in @(5,6)) {
        $path = Join-Path $dir ("mode_{0}.nip" -f $n)
        $returned = Export-MfgDriverNip 'Farming Simulator 25' $n $path
        Assert ($returned -eq $path) 'Exporter must return exact output path.'
        $doc = New-Object System.Xml.XmlDocument
        $doc.Load($path)
        Assert ($doc.DocumentElement.Name -eq 'ArrayOfProfile') 'NPI XML root must match XmlSerializer.'
        Assert ($doc.SelectSingleNode('/ArrayOfProfile/Profile/ProfileName').InnerText -eq 'Farming Simulator 25') 'Profile name wrong.'
        Assert ($doc.SelectNodes('/ArrayOfProfile/Profile/Executeables/*').Count -eq 0) 'Never reassign executables.'
        $setting = @{}
        foreach ($node in $doc.SelectNodes('/ArrayOfProfile/Profile/Settings/ProfileSetting')) {
            Assert ($node.SelectSingleNode('ValueType').InnerText -eq 'Dword') 'NPI value type wrong.'
            $setting[$node.SelectSingleNode('SettingID').InnerText] = $node.SelectSingleNode('SettingValue').InnerText
        }
        Assert ($setting.Count -eq 2) 'Unexpected settings risk overwriting user preferences.'
        Assert ($setting['271614616'] -eq '2') 'FG mode must be Fixed (ID 0x10308298; value 2).'
        Assert ($setting['273507943'] -eq [string]($n - 1)) '5X/6X frame count must be 4/5 (ID 0x104D6667).'
    }
    $blocked = $false
    try { Export-MfgDriverNip 'Farming Simulator 25' 7 (Join-Path $dir 'bad.nip') | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Unsupported multiplier must be rejected.'
    Assert (-not (Test-Path (Join-Path $dir 'bad.nip'))) 'Rejected export must not write.'
    $blocked = $false
    try { Export-MfgDriverNip ('bad' + [char]10 + 'profile') 5 (Join-Path $dir 'bad.nip') | Out-Null } catch { $blocked = $true }
    Assert $blocked 'Invalid profile name must be rejected.'
    Assert (-not $source.Contains('function Apply-PatchBytesForce')) 'Unsafe EXE patch must remain absent.'
    Assert ($source.Contains('Test-TrustedPatch $liveProbe $versionInfo $beforeHash')) 'EXE patch must remain gated.'
    Assert ($source.Contains('Write-VerifiedLockedFile $script:CurrentExe $beforeHash')) 'Locked verified EXE write must remain.'
    $empty = Get-MfgDriverTestReadiness ''
    Assert (-not $empty.Helper -and -not $empty.StreamlineModern) 'Missing game path must be safely handled.'
} finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'PASS: driver-only 5X/6X NVIDIA Profile Inspector exports and safety tests.'
