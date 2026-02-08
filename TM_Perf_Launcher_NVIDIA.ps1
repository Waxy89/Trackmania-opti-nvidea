<# ===========================================================
 Trackmania Performance Launcher - NVIDIA (GUID-safe, Ultimate TEMP, Balanced Restore)
 - Samma upplägg som AMD, men med (valfri) NVIDIA Profile Inspector-import.
 - INGA overlays/prog stängs (GeForce Experience/ShadowPlay, RTSS/MSI, Game Bar, Steam/Epic, Discord - allt lämnas)
=========================================================== #>

# --------- KONFIG ---------
$TrackmaniaUri       = "uplay://launch/5595/0"

$KillOverlays        = $false        # lämnar ALLA overlays/program i fred
$KeepMonitoringOsd   = $true
$DisableGameBarDvr   = $false        # lämnar Game Bar/DVR i fred när false

$DoSessionNicTweaks  = $true
$SetProcessAffinity  = $true
$PreferAutoPCores    = $true

# (Valfritt) NVIDIA Profile Inspector
$NPI_Exe     = ""  # t.ex. "C:\Tools\nvidiaProfileInspector\nvidiaProfileInspector.exe"
$NPI_Profile = ""  # t.ex. "C:\Tools\npi\Trackmania_LowLatency.nip"

# CPU-policy (AC) på TEMP-plan
$CPU_MinState    = 5
$CPU_MaxState    = 100
$CPU_IdleDisable = 0
$CPU_MinCores    = 100
$CPU_EPP         = 0
$CPU_BoostMode   = 2
# --------------------------

# Elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Start-Process powershell -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`""
  exit
}
$ErrorActionPreference = 'Stop'

function OK($m){ Write-Host "OK - $m" -ForegroundColor Green }
function WARN($m){ Write-Host $m -ForegroundColor DarkYellow }
function FAIL($m){ Write-Host "FEL - $m" -ForegroundColor Red }

Write-Host "`n========== TRACKMANIA PERFORMANCE LAUNCHER (NVIDIA) ==========" -ForegroundColor Cyan

# --- P/Invoke: Timer + P-core discovery (TM.Native) ---
$code = @"
using System;
using System.Runtime.InteropServices;
namespace TM {
  public static class Native {
    [DllImport("ntdll.dll")] public static extern int NtSetTimerResolution(uint Desired, bool Set, out uint Current);
    [StructLayout(LayoutKind.Sequential)] public struct GROUP_AFFINITY { public UIntPtr Mask; public ushort Group; [MarshalAs(UnmanagedType.ByValArray, SizeConst=3)] public ushort[] Reserved; }
    [StructLayout(LayoutKind.Sequential)] public struct SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX { public int Relationship; public int Size; }
    [StructLayout(LayoutKind.Sequential)] public struct PROCESSOR_RELATIONSHIP { public byte Flags; public byte EfficiencyClass; [MarshalAs(UnmanagedType.ByValArray, SizeConst=20)] public byte[] Reserved; public ushort GroupCount; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetLogicalProcessorInformationEx(int RelationshipType, IntPtr Buffer, ref int ReturnedLength);
    const int RelationProcessorCore = 0;
    public static UInt64 GetPCoreMaskGroup0() {
      int len = 0; GetLogicalProcessorInformationEx(RelationProcessorCore, IntPtr.Zero, ref len);
      if (len <= 0) return 0;
      IntPtr buf = Marshal.AllocHGlobal(len);
      try {
        if (!GetLogicalProcessorInformationEx(RelationProcessorCore, buf, ref len)) return 0;
        IntPtr ptr = buf; int offset = 0; UInt64 pMask = 0;
        while (offset < len) {
          int size = Marshal.ReadInt32(ptr, 4);
          byte eff = Marshal.ReadByte(ptr, 8);
          ushort groupCount = (ushort)Marshal.ReadInt16(ptr, 30);
          IntPtr gaPtr = ptr + 32;
          for (int i=0; i<groupCount; i++) {
            UInt64 mask = (UInt64)Marshal.ReadIntPtr(gaPtr);
            ushort grp = (ushort)Marshal.ReadInt16(gaPtr, IntPtr.Size);
            if (grp == 0 && eff == 0) pMask |= mask;
            gaPtr += (IntPtr.Size==8 ? 16 : 12);
          }
          ptr += size; offset += size;
        }
        return pMask;
      } finally { Marshal.FreeHGlobal(buf); }
    }
  }
}
"@
if (-not ([Type]::GetType('TM.Native'))) { Add-Type -TypeDefinition $code -Language CSharp -IgnoreWarnings | Out-Null }

# Timer lock 0.5 ms
[uint32]$cur=0; [void][TM.Native]::NtSetTimerResolution(5000,$true,[ref]$cur); OK "Timer låst (0.5 ms)"

# powercfg GUIDs
$GUID_BALANCED_TEMPLATE='381b4222-f694-41f0-9685-ff5bb260df2e'
$GUID_HIGH_TEMPLATE    ='8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$SUB_PROCESSOR='54533251-82be-4824-96c1-47b60b740d00'; $SUB_USB='2a737441-1930-4402-8d77-b2bebba308a3'; $SUB_DISK='0012ee47-9041-4b5d-9b77-535fba8b1442'
$PROC_MIN_STATE='893dee8e-2bef-41e0-89c6-b55d0929964c'; $PROC_MAX_STATE='bc5038f7-23e0-4960-96da-33abaf5935ec'
$PROC_IDLE_DISABLE='5d76a2ca-e8c0-402f-a133-2158492d58ad'; $PROC_MIN_CORES='0cc5b647-c1df-4637-891a-dec35c318583'
$PROC_EPP='36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; $PROC_BOOST_MODE='be337238-0d82-4146-a960-4f3749d470c7'
$USB_SUSPEND='3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; $DISK_IDLE='6738e2c4-e8a5-4a42-b16a-e040e769756e'

function Unhide([string]$S,[string]$T){ try{ & powercfg -attributes $S $T -ATTRIB_HIDE 2>$null }catch{} }
function Exists([string]$P,[string]$S,[string]$T){ try{ $null=& powercfg /q $P $S $T 2>$null; $true }catch{ $false } }
function SetAC([string]$P,[string]$S,[string]$T,[int]$V,[string]$L){ Unhide $S $T; if(Exists $P $S $T){ $o=& powercfg -setacvalueindex $P $S $T $V 2>&1; if($LASTEXITCODE -eq 0){ OK "$L = $V" } else { FAIL "$L kunde inte sättas"; if($o){$o|%{"  $_"}} } } else { WARN "Saknas: $L" } }

# Hämta alla planer + aktiv plan
function Plans{
  powercfg /L |%{
    if($_ -match 'Power Scheme GUID:\s+([0-9a-fA-F-]+)\s+\((.+?)\)'){
      [pscustomobject]@{
        Guid=$Matches[1].ToLower()
        Name=$Matches[2].Trim()
        Active=($_ -match '\*')
      }
    }
  }
}

$plans = Plans
# Sätt restore-guid till den aktiva planen oavsett namn
$RestorePlan = $plans | ?{$_.Active} | Select-Object -First 1
if(-not $RestorePlan){ throw "Hittar ingen aktiv strömplan." }
OK ("Återställning -> {0} ({1})" -f $RestorePlan.Name,$RestorePlan.Guid)

$UltimatePlan=$plans|?{$_.Name -match '(?i)ultimate'}|Select-Object -First 1

# TEMP-plan
$gameGuid=$null
if($UltimatePlan){
  $dup=& powercfg -duplicatescheme $UltimatePlan.Guid 2>&1
  if($LASTEXITCODE -eq 0 -and ($dup -match 'Power Scheme GUID:\s*([0-9a-fA-F-]+)')){$gameGuid=$Matches[1].ToLower(); OK "TEMP från Ultimate"}
}
if(-not $gameGuid){
  $dup=& powercfg -duplicatescheme $GUID_BALANCED_TEMPLATE 2>&1
  if($LASTEXITCODE -eq 0 -and ($dup -match 'Power Scheme GUID:\s*([0-9a-fA-F-]+)')){$gameGuid=$Matches[1].ToLower(); OK "TEMP från Balanced-mall"}
}
if(-not $gameGuid){
  $dup=& powercfg -duplicatescheme $GUID_HIGH_TEMPLATE 2>&1
  if($LASTEXITCODE -eq 0 -and ($dup -match 'Power Scheme GUID:\s*([0-9a-fA-F-]+)')){$gameGuid=$Matches[1].ToLower(); OK "TEMP från High Performance-mall"}
}
if(-not $gameGuid){ throw "Kunde inte skapa TEMP-plan." }
try{ & powercfg -changename $gameGuid "TM TEMP (Do Not Keep)" "Skapad $(Get-Date -Format s)" 2>$null }catch{}
$null=& powercfg -setactive $gameGuid; OK "TEMP-plan aktiv: $gameGuid"

# CPU/Device policys (TEMP)
SetAC $gameGuid $SUB_PROCESSOR $PROC_EPP          $CPU_EPP         "EPP"
SetAC $gameGuid $SUB_PROCESSOR $PROC_BOOST_MODE   $CPU_BoostMode   "Boost mode"
SetAC $gameGuid $SUB_PROCESSOR $PROC_MIN_CORES    $CPU_MinCores    "Core parking min cores (%)"
SetAC $gameGuid $SUB_PROCESSOR $PROC_IDLE_DISABLE $CPU_IdleDisable "Processor idle disable"
SetAC $gameGuid $SUB_PROCESSOR $PROC_MIN_STATE    $CPU_MinState    "Minimum processor state (%)"
SetAC $gameGuid $SUB_PROCESSOR $PROC_MAX_STATE    $CPU_MaxState    "Maximum processor state (%)"
SetAC $gameGuid $SUB_DISK      $DISK_IDLE         0                "Disk idle timeout (AC)"
SetAC $gameGuid $SUB_USB       $USB_SUSPEND       0                "USB selective suspend (AC)"

# Registry perf snapshot + tweaks
$mmKey="HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
$regSnap=[ordered]@{}
function SnapVal($p,$n){$k="$p|$n";$regSnap["$k.Exists"]=$false;try{$v=(Get-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue).$n;if($null -ne $v){$regSnap["$k.Exists"]=$true;$regSnap["$k.Value"]=[int]$v}}catch{}}
SnapVal "HKCU:\Control Panel\Desktop" "ForegroundLockTimeout"
SnapVal "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation"
SnapVal $mmKey "NetworkThrottlingIndex"; SnapVal $mmKey "SystemResponsiveness"
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "ForegroundLockTimeout" -Type DWord -Value 0
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Type DWord -Value 26
New-ItemProperty -Path $mmKey -Name "NetworkThrottlingIndex" -PropertyType DWord -Value 0xffffffff -Force | Out-Null
Set-ItemProperty -Path $mmKey -Name "SystemResponsiveness" -Type DWord -Value 0
OK "Registry tweaks tillämpade"

# (VALBART) Game Bar/DVR/FSO - AV som standard
$uiSnap=[ordered]@{}
function SnapSet($p,$n,$v){$k="$p|$n";$uiSnap["$k.Exists"]=$false;try{$cv=(Get-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue).$n;if($null -ne $cv){$uiSnap["$k.Exists"]=$true;$uiSnap["$k.Value"]=[int]$cv}}catch{};New-Item -Path $p -Force|Out-Null;New-ItemProperty -Path $p -Name $n -PropertyType DWord -Value $v -Force|Out-Null}
if($DisableGameBarDvr){
  SnapSet "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR" "AppCaptureEnabled" 0
  SnapSet "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
  SnapSet "HKCU:\System\GameConfigStore" "GameDVR_FSEBehavior" 2
  SnapSet "HKCU:\System\GameConfigStore" "GameDVR_FSEBehaviorMode" 2
  SnapSet "HKCU:\SOFTWARE\Microsoft\GameBar" "ShowStartupPanel" 0
  SnapSet "HKCU:\SOFTWARE\Microsoft\GameBar" "AutoGameModeEnabled" 1
  OK "Game Bar/DVR/FSO OFF (global)"
}else{
  Write-Host "Game Bar/DVR lämnas orörda (DisableGameBarDvr=false)." -ForegroundColor DarkGray
}

# (VALFRITT) NVIDIA Profile Inspector
if($NPI_Exe -and $NPI_Profile -and (Test-Path $NPI_Exe) -and (Test-Path $NPI_Profile)){
  Write-Host "Importerar NPI-profil." -ForegroundColor Yellow
  $npo = & $NPI_Exe -importProfile $NPI_Profile 2>&1
  if($LASTEXITCODE -eq 0){ OK "NPI-profil importerad" } else { WARN "NPI: $($npo -join ' ')" }
}

# TCP tweaks
function Get-TcpGlobal { (& netsh int tcp show global 2>&1) -join "`n" }
$tcpBefore = Get-TcpGlobal
& netsh int tcp set global autotuninglevel=normal | Out-Null
& netsh int tcp set global rss=enabled          | Out-Null
try{ & netsh int tcp set global dca=enabled   | Out-Null }catch{}
try{ & netsh int tcp set global netdma=enabled| Out-Null }catch{}
OK "TCP tweaks klara"

# NIC tweaks
$NicSnap=@{}; $nic=$null
function Set-IfExists([string]$NicName,[string]$Disp,[string]$Val){
  $prop=Get-NetAdapterAdvancedProperty -Name $NicName -ErrorAction SilentlyContinue|?{$_.DisplayName -eq $Disp}
  if($prop){
    $script:NicSnap[$Disp]=$prop.DisplayValue
    try{Set-NetAdapterAdvancedProperty -Name $NicName -DisplayName $Disp -DisplayValue $Val -NoRestart -ErrorAction Stop; OK "$Disp -> $Val"}catch{Write-Host "Hoppar över ($Disp): $($_.Exception.Message)" -ForegroundColor Yellow}
  }
}
if($DoSessionNicTweaks){
  $nic=Get-NetAdapter|?{$_.Status -eq 'Up'}|Select-Object -First 1
  if($nic){
    Set-IfExists $nic.Name "Interrupt Moderation" "Disabled"
    Set-IfExists $nic.Name "Energy Efficient Ethernet" "Disabled"
    Set-IfExists $nic.Name "Green Ethernet" "Disabled"
    Set-IfExists $nic.Name "System Idle Power Saver" "Disabled"
    Set-IfExists $nic.Name "Ultra Low Power Mode" "Disabled"
    Set-IfExists $nic.Name "Power Saving Mode" "Disabled"
    Set-IfExists $nic.Name "Reduce link speed during system idle" "Disabled"
    try{ Set-NetAdapterRss -Name $nic.Name -Enabled $true -ErrorAction Stop; $NicSnap["__RSS__"]="Enabled"; OK "RSS -> Enabled"}catch{Write-Host "Hoppar över RSS: $($_.Exception.Message)" -ForegroundColor Yellow}
  }
}

# Starta Trackmania
Start-Process $TrackmaniaUri
while(-not (Get-Process -Name "trackmania*" -ErrorAction SilentlyContinue)){ Start-Sleep -Milliseconds 400 }
$tm=Get-Process -Name "trackmania*" -ErrorAction SilentlyContinue|Select-Object -First 1
if($tm){
  try{ $tm.PriorityClass='High'; OK "Processprioritet = High" }catch{}
  try{
    $tm.Refresh(); $exePath=$tm.MainModule.FileName
    if($exePath){
      $appCompat="HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"
      New-Item -Path $appCompat -Force|Out-Null
      $flags="~ DISABLEDXMAXIMIZEDWINDOWEDMODE ~ HIGHDPIAWARE"
      New-ItemProperty -Path $appCompat -Name $exePath -PropertyType String -Value $flags -Force|Out-Null
      OK "Per-exe: FSO OFF + High DPI Aware satt ($exePath) - gäller nästa start"
    }
  }catch{ WARN "Kunde inte sätta per-exe FSO/DPI: $($_.Exception.Message)" }
  if($SetProcessAffinity){
    try{
      $mask=[TM.Native]::GetPCoreMaskGroup0()
      if($PreferAutoPCores -and $mask -ne 0){ $tm.ProcessorAffinity=[intptr]::new([long]$mask); OK ("Affinitet -> P-cores (0x{0:X})" -f $mask) }
      else{ [long]$m=0; $n=[Environment]::ProcessorCount; for($i=0;$i -lt $n;$i+=2){ $m=$m -bor (1 -shl $i) }; if($m -ne 0){ $tm.ProcessorAffinity=[intptr]::new($m); OK ("Affinitet -> varannan tråd (0x{0:X})" -f $m) } }
    }catch{ WARN "Affinitet misslyckades: $($_.Exception.Message)" }
  }
}
while(Get-Process -Name "trackmania*" -ErrorAction SilentlyContinue){ Start-Sleep -Seconds 5 }

# Återställning
[void][TM.Native]::NtSetTimerResolution(5000,$false,[ref]$cur); OK "Timer släppt"

if($DoSessionNicTweaks -and $nic){
  foreach($k in $NicSnap.Keys){
    if($k -eq "__RSS__"){
      try{ Set-NetAdapterRss -Name $nic.Name -Enabled ($NicSnap[$k] -eq 'Enabled') -ErrorAction Stop }catch{}
      continue
    }
    try{ Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $k -DisplayValue $NicSnap[$k] -NoRestart -ErrorAction Stop }catch{}
  }
  OK "NIC-egenskaper återställda"
}

function RestoreVal($p,$n){$k="$p|$n"; if($regSnap["$k.Exists"]){ Set-ItemProperty -Path $p -Name $n -Type DWord -Value $regSnap["$k.Value"] } else { Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue } }
RestoreVal "HKCU:\Control Panel\Desktop" "ForegroundLockTimeout"
RestoreVal "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation"
RestoreVal $mmKey "NetworkThrottlingIndex"; RestoreVal $mmKey "SystemResponsiveness"

if($DisableGameBarDvr){
  foreach($kv in $uiSnap.Keys | ?{$_ -like "*|*" -and $_ -like "*.Exists"}){
    $base=$kv -replace '\.Exists$',''; $parts=$base.Split('|',2); $p=$parts[0]; $n=$parts[1]
    if($uiSnap[$kv]){ Set-ItemProperty -Path $p -Name $n -Type DWord -Value $uiSnap["$base.Value"] } else { Remove-ItemProperty -Path $p -Name $n -ErrorAction SilentlyContinue }
  }
  OK "Game Bar/DVR/FSO (global) återställda"
}

$null=& powercfg -setactive $RestorePlan.Guid; OK ("Återställd plan aktiv: {0}" -f $RestorePlan.Guid)
try{ & powercfg -delete $gameGuid 2>$null; OK "TEMP-plan borttagen" }catch{}
Write-Host "`n? KLART - Sessionen stängd, allt återställt." -ForegroundColor Cyan
