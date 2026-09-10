# ============================================================
#  Apex FPS Optimizer  ·  通用版
#  XIAOMING6680
# ============================================================
$ErrorActionPreference = 'Continue'

# ---------- 1. DPI 感知（必须在创建任何窗口之前） ----------
try {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DpiNative {
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
"@ -ErrorAction Stop
} catch { }
$dpiSet = $false
try { if ([DpiNative]::SetProcessDpiAwareness(2) -eq 0) { $dpiSet = $true } } catch { }
if (-not $dpiSet) { try { [void][DpiNative]::SetProcessDPIAware() } catch { } }
try {
    $cw = [DpiNative]::GetConsoleWindow()
    if ($cw -ne [IntPtr]::Zero) { [void][DpiNative]::ShowWindow($cw, 0) }
} catch { }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$WINTITLE = "Apex 帧数优化工具"

# 启动日志：万一以后又出现"点了没反应"，这个文件能直接看出卡在哪一步
# 日志放工具自己的目录，方便直接看；每次启动覆盖，不会无限增长
$here0 = $PSScriptRoot
if (-not $here0) { $here0 = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $here0) { $here0 = $env:TEMP }
$STARTLOG = Join-Path $here0 "启动日志.txt"
$script:BOOTFIRST = $true
function Boot-Log($s){
    try {
        $line = (Get-Date -Format "HH:mm:ss.fff") + "  " + $s
        if ($script:BOOTFIRST) {
            Set-Content -LiteralPath $STARTLOG -Value $line -Encoding UTF8
            $script:BOOTFIRST = $false
        } else {
            Add-Content -LiteralPath $STARTLOG -Value $line -Encoding UTF8
        }
    } catch { }
}
Boot-Log "=== 启动 PID $PID ==="

# 没有管理员权限时，所有 HKLM 写入都会静默失败，必须先拦住
$isAdmin = $false
try {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wp = New-Object Security.Principal.WindowsPrincipal($wi)
    $isAdmin = $wp.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }
if (-not $isAdmin) {
    $me = $PSCommandPath
    if (-not $me) { $me = $MyInvocation.MyCommand.Path }
    $ans = [System.Windows.Forms.MessageBox]::Show(
        "本工具需要管理员权限才能读写系统设置。`n`n当前没有提权，继续运行的话所有修改都会静默失败。`n`n点「是」以管理员身份重新启动。",
        "需要管理员权限",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes -and $me) {
        try {
            Start-Process -FilePath "powershell.exe" -Verb RunAs -WindowStyle Hidden `
                -ArgumentList @("-NoProfile","-STA","-ExecutionPolicy","Bypass","-File",$me)
        } catch { }
    }
    exit
}

# 清理系统缓存(Standby List)。这是 ISLC 那类工具真正在做的事：
# 系统缓存被撑大后，游戏要新内存时系统需要先回收，容易造成瞬间卡顿。
# 注意：这里刻意不做"清空已用内存"——那是多数国产内存优化的做法，
# 会把正在用的页刷到磁盘，用到时再缺页调回，对游戏是负优化。
try {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MemNative {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint Count; public LUID_AND_ATTRIBUTES Priv; }
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES np, uint len, IntPtr prev, IntPtr rl);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("ntdll.dll")] public static extern int NtSetSystemInformation(int cls, IntPtr info, int len);

    public static bool Enable(string priv){
        IntPtr tok;
        if(!OpenProcessToken(GetCurrentProcess(), 0x20|0x8, out tok)) return false;
        LUID luid;
        if(!LookupPrivilegeValue(null, priv, out luid)) return false;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.Count = 1; tp.Priv.Luid = luid; tp.Priv.Attributes = 2;
        return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
    // SystemMemoryListInformation = 80, MemoryPurgeStandbyList = 4
    public static int PurgeStandby(){
        Enable("SeProfileSingleProcessPrivilege");
        IntPtr p = Marshal.AllocHGlobal(4);
        Marshal.WriteInt32(p, 4);
        int r = NtSetSystemInformation(80, p, 4);
        Marshal.FreeHGlobal(p);
        return r;
    }
    // MemoryEmptyWorkingSets = 2，仅在内存确实吃紧时才用
    public static int EmptyWorkingSets(){
        Enable("SeProfileSingleProcessPrivilege");
        IntPtr p = Marshal.AllocHGlobal(4);
        Marshal.WriteInt32(p, 2);
        int r = NtSetSystemInformation(80, p, 4);
        Marshal.FreeHGlobal(p);
        return r;
    }
}
"@ -ErrorAction Stop
} catch { }

try {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MouseNative {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, int[] pvParam, uint fWinIni);
    // SPI_GETMOUSE=0x0003  SPI_SETMOUSE=0x0004
    // SPIF_UPDATEINIFILE=0x01  SPIF_SENDCHANGE=0x02
    public static int[] GetMouse(){
        int[] p = new int[3];
        if (!SystemParametersInfo(0x0003, 0, p, 0)) return null;
        return p;
    }
    public static bool SetMouse(int a, int b, int c){
        int[] p = new int[3]; p[0]=a; p[1]=b; p[2]=c;
        return SystemParametersInfo(0x0004, 0, p, 0x01|0x02);
    }
}
"@ -ErrorAction Stop
} catch { }

# 优雅关闭需要向进程的顶层窗口发 WM_CLOSE。
# 直接 Stop-Process -Force 等于 TerminateProcess，程序来不及保存状态，
# 下次启动会报"上次非正常关闭" —— 壁纸引擎就是这么报错的。
try {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class MmcssNative {
    [DllImport("avrt.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr AvSetMmThreadCharacteristicsW(string task, ref uint index);
    [DllImport("avrt.dll", SetLastError = true)]
    public static extern bool AvRevertMmThreadCharacteristics(IntPtr h);
}
"@
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class WinClose {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    public static int CloseByPid(uint target){
        List<IntPtr> hits = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr l){
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid == target) hits.Add(h);
            return true;
        }, IntPtr.Zero);
        foreach (IntPtr h in hits) { PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); } // WM_CLOSE
        return hits.Count;
    }
}
"@ -ErrorAction Stop
} catch { }

Boot-Log "已确认管理员权限"

# ---------- 单实例锁 ----------
# 必须放在提权检查之后：否则未提权的那个进程先抢到锁，
# 它拉起的提权副本会以为"已经有一个在跑"而静默退出，表现就是点了没反应。
$script:APPMUTEX = $null
$createdNew = $false
foreach ($scope in @("Global","Local")) {
    try {
        $script:APPMUTEX = New-Object System.Threading.Mutex($true, "$scope\ApexFpsTool_XIAOMING6680", [ref]$createdNew)
        break
    } catch { $script:APPMUTEX = $null }
}
if ($null -eq $script:APPMUTEX) { $createdNew = $true }   # 锁都建不了就别拦着用户

if (-not $createdNew) {
    Boot-Log "检测到已有实例，查找其窗口"
    $h = [IntPtr]::Zero
    try { $h = [DpiNative]::FindWindow($null, $WINTITLE) } catch { }
    if ($h -ne [IntPtr]::Zero) {
        # 确实有窗口，把它调到前台就好
        Boot-Log "已有窗口，调到前台后退出"
        try {
            if ([DpiNative]::IsIconic($h)) { [void][DpiNative]::ShowWindow($h, 9) }
            [void][DpiNative]::SetForegroundWindow($h)
        } catch { }
        exit
    }
    # 锁在但窗口没有 = 上次异常退出留下的残锁。
    # 绝不能因为一个残锁就把用户永久挡在门外，放行继续启动。
    Boot-Log "锁存在但无窗口，判定为残留锁，继续启动"
    try { $script:APPMUTEX.Dispose() } catch { }
    $script:APPMUTEX = $null
}
Boot-Log "单实例检查通过"

$gfx = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$SCALE = $gfx.DpiX / 96.0
$gfx.Dispose()

# 启动要探测硬件和扫描游戏目录，耗时可观。先弹个小提示，
# 否则用户会以为没反应而反复双击。
$splash = New-Object System.Windows.Forms.Form
$splash.FormBorderStyle = "None"
$splash.StartPosition = "CenterScreen"
$splash.BackColor = [System.Drawing.Color]::FromArgb(23,30,38)
$splash.Size = New-Object System.Drawing.Size([int](300*$SCALE),[int](96*$SCALE))
$splash.TopMost = $true
$spBar = New-Object System.Windows.Forms.Panel
$spBar.BackColor = [System.Drawing.Color]::FromArgb(45,205,200)
$spBar.Location = New-Object System.Drawing.Point(0,0)
$spBar.Size = New-Object System.Drawing.Size([int](300*$SCALE),[int](3*$SCALE))
$splash.Controls.Add($spBar)
$spL1 = New-Object System.Windows.Forms.Label
$spL1.Text = "Apex 帧数优化工具"
$spL1.ForeColor = [System.Drawing.Color]::FromArgb(228,236,243)
$spL1.Font = New-Object System.Drawing.Font("Microsoft YaHei UI",11,[System.Drawing.FontStyle]::Bold)
$spL1.Location = New-Object System.Drawing.Point([int](22*$SCALE),[int](24*$SCALE))
$spL1.Size = New-Object System.Drawing.Size([int](260*$SCALE),[int](24*$SCALE))
$spL1.BackColor = [System.Drawing.Color]::Transparent
$splash.Controls.Add($spL1)
$spL2 = New-Object System.Windows.Forms.Label
$spL2.Text = "正在检测硬件与游戏目录..."
$spL2.ForeColor = [System.Drawing.Color]::FromArgb(132,149,166)
$spL2.Font = New-Object System.Drawing.Font("Microsoft YaHei UI",8.5)
$spL2.Location = New-Object System.Drawing.Point([int](22*$SCALE),[int](54*$SCALE))
$spL2.Size = New-Object System.Drawing.Size([int](260*$SCALE),[int](20*$SCALE))
$spL2.BackColor = [System.Drawing.Color]::Transparent
$splash.Controls.Add($spL2)
Boot-Log "显示启动提示窗"
$splash.Show()
[System.Windows.Forms.Application]::DoEvents()
function Splash-Say($s){
    try { $spL2.Text = $s; [System.Windows.Forms.Application]::DoEvents() } catch { }
}
function S([int]$n) { return [int][math]::Round($n * $SCALE) }
function Pt($x,$y) { return New-Object System.Drawing.Point((S $x),(S $y)) }
function Sz($w,$h) { return New-Object System.Drawing.Size((S $w),(S $h)) }

# ---------- 2. 共享逻辑（主线程与后台刷新线程共用） ----------
$SharedFns = @'
$ULTGUID = "e9a42b02-d5df-448d-aa00-03f14749eb61"
$HIGHGUID = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
$BKDIR   = Join-Path $env:LOCALAPPDATA "ApexOptBackup"
$BKFILE  = Join-Path $BKDIR "backup.txt"
$OURFILE = Join-Path $BKDIR "created_scheme.txt"
$VBSFILE = Join-Path $BKDIR "vbs_disabled.txt"

$K_GCS  = "HKCU:\System\GameConfigStore"
$K_POL  = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
$K_GB   = "HKCU:\Software\Microsoft\GameBar"
$K_GD   = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
$K_DG   = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard"
$K_HVCI = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity"
$K_CG   = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\CredentialGuard"
$K_GPU  = "HKCU:\Software\Microsoft\DirectX\UserGpuPreferences"

$APEXNAMES = @("r5apex_dx12.exe","r5apex.exe","start_protected_game.exe")

# 电源设置一律用显式 GUID：别名在部分语言/精简版系统上可能解析不到。
# 这两项在多数机器上是隐藏设置，写入前先取消隐藏，
# 这样你也能在 Windows 电源选项里自己看到值，便于核对。
$SUB_PROC  = "54533251-82be-4824-96c1-47b60b740d00"
$SET_PMIN  = "893dee8e-2bef-41e0-89c6-b55d0929964c"
$SET_PMAX  = "bc5038f7-23e0-4960-96da-33abaf5935ec"
$SUB_PCIE  = "501a4d13-42af-4429-9fd1-a8218c268e20"
$SET_ASPM  = "ee12f906-d277-404b-b6da-e5fa1a576df5"
$SUB_USB   = "2a737441-1930-4402-8d77-b2bebba308a3"
$SET_USBS  = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
$SUB_DISK  = "0012ee47-9041-4b5d-9b77-535fba8b1442"
$SET_DIDLE = "6738e2c4-e8a5-4a42-b16a-e040e769756e"
$SUB_VIDEO = "7516b95f-f776-4464-8c53-06167f40cc99"
$SET_VIDLE = "3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e"
$SUB_SLEEP = "238c9fa8-0aad-41ed-83f4-97be242c8f20"
$SET_STDBY = "29f6c1db-86da-48c5-9fdb-f2b67b1f44da"
$SUB_GFX   = "44f3beca-a7c0-460e-9df2-bb8b99e0cba6"
# 卓越性能区别于高性能的几项（默认隐藏，写入前会先取消隐藏）
$SET_CPARK   = "0cc5b647-c1df-4637-891a-dec35c318583"   # 核心停放最小核心数 0-100
$SET_BOOST   = "be337238-0d82-4146-a960-4f3749d470c7"   # 0禁用 1启用 2激进
$SET_PERFINC = "465e1f50-b610-473a-ab58-00d1077dc418"   # 0理想 1单步 2火箭 3理想激进
$SET_AUTON   = "8baa4a8a-14c6-4451-8e8b-14bdbd197537"   # 0禁用 1启用
$SET_LATHINT = "619b7505-003b-4e82-b7a6-4dd29c300971"   # 0-100
$SET_GFX   = "3619c3f2-afb2-4afc-b0e9-e7fef372de36"

# 绝不出现在清理清单里：杀掉会直接影响开黑或导致游戏异常
$PROTECTED = @(
  # 语音 / 直播 / 串流
  "Discord","DiscordCanary","DiscordPTB","DiscordDevelopment",
  "oopz","Oopz","OOPZ","OopzApp",
  "YY","yy","YYLive","yylive","YYGame",
  "ts3client_win64","ts3client_win32","TeamSpeak","TeamSpeak3",
  "Mumble","RaidCall","Ventrilo","Overtone",
  "KOOK","kaiheila","kookapp","KookApp",
  "wemeetapp","Zoom","ZoomIt","Skype","SkypeApp",
  "obs64","obs32","Streamlabs OBS","XSplit.Core","XSplit.Broadcaster",
  # 反作弊 —— 杀掉会导致游戏崩溃甚至误判
  "EasyAntiCheat","EasyAntiCheat_EOS","start_protected_game",
  "BEService","BEDaisy","vgtray","vgc","ACE-Tray","ACE-BASE","SGuard","SGuard64",
  "TenProtect","TPHelper","anticheat","AntiCheatExpert",
  # Steam 本体与游戏运行时
  "steam","steamwebhelper","steamservice","GameOverlayUI",
  # 显卡驱动与叠加层
  "NVDisplay.Container","nvcontainer","NVIDIA Share","NVIDIA Web Helper",
  "RadeonSoftware","AMDRSServ","atieclxx"
)

# risky=1 的分类默认不勾选。游戏相关的一律 risky=1：
# 加速器杀掉会当场掉线，启动器杀掉可能导致游戏无法启动或成就不同步
$KILLGROUPS = @(
  @{ cat="动态壁纸"; risky=0; names=@("wallpaper64","wallpaper32","wallpaperservice64","wallpaperservice32","Lively") },
  @{ cat="音乐播放"; risky=0; names=@("cloudmusic","cloudmusicn","QQMusic","KuGou","kwmusic","Spotify","foobar2000") },
  @{ cat="外设灯效"; risky=0; names=@("RazerAppEngine","RzSDKService","LogiOptionsMgr","LogiOverlay","iCUE","ArmouryCrate.UserSessionHelper","NahimicSvc64","OpenRGB") },
  @{ cat="远程控制"; risky=0; names=@("GameViewerServer","GameViewerHealthd","ToDesk","SunloginClient","AnyDesk","TeamViewer","RustDesk") },
  @{ cat="下载工具"; risky=0; names=@("Thunder","XLLiveUD","IDMan","qbittorrent","BitComet","aria2c") },
  @{ cat="虚拟机";   risky=1; names=@("Docker Desktop","com.docker.backend","vmware-tray","VBoxSVC","vmnat") },
  @{ cat="游戏加速器"; risky=1; names=@("uu","UU","uugamebooster","UUGameBooster","uuplugin","XunYouClient","xunyou","XunYou","LeiShen","leishen","qiyou","QiYou","Steam++","Steampp","Watt Toolkit","NetBooster","wgc") },
  @{ cat="游戏平台"; risky=1; names=@("EpicGamesLauncher","EADesktop","EABackgroundService","Battle.net","Agent","upc","UbisoftConnect","GalaxyClient","WeGame","wegame","TenioDL") },
  @{ cat="性能监控"; risky=1; names=@("MSIAfterburner","RTSS","RTSSHooksLoader64","HWiNFO64","GPU-Z","CPUID HWMonitor") },
  @{ cat="云盘同步"; risky=1; names=@("OneDrive","BaiduNetdisk","Dropbox","GoogleDriveFS","aDrive","Seafile") },
  @{ cat="浏览器";   risky=1; names=@("msedge","chrome","firefox","360se","QQBrowser","opera","brave") },
  @{ cat="聊天办公"; risky=1; names=@("Weixin","WeChat","WeChatAppEx","WeChatPlayer","QQ","TIM","DingTalk","Teams","ms-teams","Slack","Feishu","Lark") }
)

# New-Item -Path <已存在的注册表键> -Force 会把整个键重建，里面的值全部丢失。
# 实测教训：它把用户 UserGpuPreferences 里其它游戏的显卡指定全清了。
# 这里改成"不存在才建"，绝不碰已有键的内容。
function Ensure-Key($path){
    if (-not (Test-Path $path)) {
        try { New-Item -Path $path -Force -ErrorAction Stop | Out-Null } catch { }
    }
}
function RegGet($key,$name){ try { return (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name } catch { return $null } }
function RegHas($key,$name){ try { $null = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name; return $true } catch { return $false } }

function Get-SchemeList { return ((powercfg /list 2>$null) -join " ") }
function Get-SchemeGuid {
    $o = powercfg /getactivescheme 2>$null
    $m = [regex]::Match(($o -join " "), '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}
function Get-SchemeName {
    $o = powercfg /getactivescheme 2>$null
    $m = [regex]::Match(($o -join " "), '\(([^)]+)\)')
    if ($m.Success) { return $m.Groups[1].Value }
    return "未知"
}
function Get-AcIndex($sub,$setting){
    $o = powercfg /query SCHEME_CURRENT $sub $setting 2>$null
    $line = $o | Where-Object { $_ -match '(?i)(当前交流|Current AC)' } | Select-Object -First 1
    if ($line -and $line -match '0x([0-9a-fA-F]+)') { return [Convert]::ToInt32($matches[1],16) }
    return $null
}
function Get-Hypervisor {
    $o = bcdedit /enum ACTIVE 2>$null
    $line = $o | Where-Object { $_ -match '(?i)hypervisorlaunchtype' } | Select-Object -First 1
    if ($line) {
        $p = @(($line -split '\s+') | Where-Object { $_ -ne '' })
        if ($p.Count -ge 2) { return $p[1] }
    }
    return "NOTSET"
}
function Get-VbsRunning {
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace root\Microsoft\Windows\DeviceGuard -ErrorAction Stop
        return ($dg.VirtualizationBasedSecurityStatus -eq 2)
    } catch { return $false }
}
# ===== 多硬件适配 =====
# 原则：能测到就报真值，测不到就明说测不到，绝不用默认值冒充。
$script:GPUVENDOR = $null
function Get-GpuVendor {
    if ($script:GPUVENDOR) { return $script:GPUVENDOR }
    $v = @{ Vendor="未知"; Name="未知显卡"; Driver=""; HasSmi=$false }
    try {
        $cards = @(Get-CimInstance Win32_VideoController -ErrorAction Stop |
                   Where-Object { $_.Name -notmatch '(?i)virtual|idd|remote|dummy|parsec|sunshine|basic' })
        $g = $cards | Where-Object { $_.Name -match '(?i)nvidia|geforce|rtx|gtx|quadro' } | Select-Object -First 1
        if ($g) { $v.Vendor = "NVIDIA" }
        if (-not $g) {
            $g = $cards | Where-Object { $_.Name -match '(?i)radeon|\bamd\b|\brx\s' } | Select-Object -First 1
            if ($g) { $v.Vendor = "AMD" }
        }
        if (-not $g) {
            $g = $cards | Where-Object { $_.Name -match '(?i)intel|arc|iris|uhd' } | Select-Object -First 1
            if ($g) { $v.Vendor = "Intel" }
        }
        if (-not $g) { $g = $cards | Select-Object -First 1 }
        if ($g) { $v.Name = $g.Name.Trim(); $v.Driver = $g.DriverVersion }
    } catch { }
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { $v.HasSmi = $true }
    $script:GPUVENDOR = $v
    return $v
}

# 厂商中立的 GPU 占用：Windows 自带的 GPU 引擎性能计数器，N/A/I 卡都能读
function Get-GpuUtilGeneric {
    try {
        $eng = Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop
        $d3 = @($eng | Where-Object { $_.Name -like "*engtype_3D*" })
        if ($d3.Count -eq 0) { $d3 = $eng }
        $s = ($d3 | Measure-Object -Property UtilizationPercentage -Sum).Sum
        if ($null -eq $s) { return $null }
        return [math]::Min([math]::Round($s,0), 100)
    } catch { return $null }
}

# 统一的显卡实时数据。字段测不到就留空，由界面显示"不可用"而不是编一个数
function Get-GpuLive {
    $vd = Get-GpuVendor
    if ($vd.HasSmi) {
        $o = & nvidia-smi --query-gpu=temperature.gpu,power.draw,power.max_limit,clocks.sm,clocks.max.sm,utilization.gpu --format=csv,noheader,nounits 2>$null
        if ($o) {
            $p = @(($o | Select-Object -First 1) -split ',') | ForEach-Object { $_.Trim() }
            if ($p.Count -ge 6) {
                return @{ Temp=$p[0]; Watt=$p[1]; WattMax=$p[2]; Clk=$p[3]; ClkMax=$p[4]; Util=$p[5]; Src="nvidia-smi" }
            }
        }
    }
    $u = Get-GpuUtilGeneric
    if ($null -eq $u) { return $null }
    return @{ Temp=""; Watt=""; WattMax=""; Clk=""; ClkMax=""; Util=[string]$u; Src="perfcounter" }
}

# CPU 拓扑：区分 Intel 混合架构 / AMD 多 CCD / 普通对称多核
# 总占用会掩盖单线程瓶颈：32 线程的机器上跑满一个核，总占用才 3%。
# 判断游戏瓶颈必须看单核峰值。
# 笔记本 / 台式机 判定，很多取舍要按这个分开
$script:MACHKIND = $null
function Get-MachineKind {
    if ($script:MACHKIND) { return $script:MACHKIND }
    $r = @{ IsLaptop=$false; Reason="" }
    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        $ch  = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes)
        if ($bat.Count -gt 0) { $r.IsLaptop = $true; $r.Reason = "检出电池" }
        elseif (@($ch | Where-Object { $_ -in 8,9,10,11,12,14,18,21,30,31,32 }).Count -gt 0) {
            $r.IsLaptop = $true; $r.Reason = "机箱类型为便携设备"
        } else { $r.Reason = "无电池且机箱为桌面类型" }
    } catch { }
    $script:MACHKIND = $r
    return $r
}
# 当前是插电还是电池。笔记本上这个直接决定功耗墙，影响极大
function Get-PowerSource {
    try {
        $b = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $b) { return "AC" }
        if ($b.BatteryStatus -eq 2) { return "AC" }
        return "DC"
    } catch { return "AC" }
}
function Get-CpuCoreMax {
    try {
        $c = @(Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -ErrorAction Stop |
               Where-Object { $_.Name -ne "_Total" })
        if ($c.Count -eq 0) { return $null }
        $vals = @($c | ForEach-Object { [int]$_.PercentProcessorTime })
        $tot = ($c | Where-Object { $_.Name -eq "_Total" })
        return @{
            Max = ($vals | Measure-Object -Maximum).Maximum
            Avg = [math]::Round((($vals | Measure-Object -Average).Average),0)
            Busy = @($vals | Where-Object { $_ -ge 80 }).Count
            Cores = $vals.Count
        }
    } catch { return $null }
}
function Get-CpuTopo {
    $t = @{ Vendor="未知"; Name=""; Cores=0; Threads=0; Kind="对称"; PCores=0; PThreads=0; ECores=0; Mask=0; Note="" }
    try {
        $c = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $t.Name = $c.Name.Trim()
        $t.Cores = [int]$c.NumberOfCores
        $t.Threads = [int]$c.NumberOfLogicalProcessors
        if ($c.Manufacturer -match '(?i)intel') { $t.Vendor = "Intel" }
        elseif ($c.Manufacturer -match '(?i)amd|advanced micro') { $t.Vendor = "AMD" }
    } catch { return $t }

    if ($t.Threads -le 0 -or $t.Cores -le 0) { return $t }
    $mAll = [int64]0
    for ($i=0; $i -lt $t.Threads; $i++) { $mAll = $mAll -bor ([int64]1 -shl $i) }
    $t.Mask = $mAll

    if ($t.Vendor -eq "Intel") {
        # 混合架构：P 核带超线程排在前，E 核单线程在后
        # P核数 = 逻辑数 - 物理数；若算出的 P 线程数已等于全部逻辑数，说明是纯 P 核
        $p = $t.Threads - $t.Cores
        $pt = $p * 2
        if ($p -gt 0 -and $pt -lt $t.Threads) {
            $t.Kind = "Intel 混合架构"
            $t.PCores = $p; $t.PThreads = $pt; $t.ECores = $t.Cores - $p
            $m = [int64]0
            for ($i=0; $i -lt $pt; $i++) { $m = $m -bor ([int64]1 -shl $i) }
            $t.Mask = $m
            $t.Note = "可绑定到 P 核"
            return $t
        }
        $t.Note = "全大核，无需绑定"
        return $t
    }
    if ($t.Vendor -eq "AMD") {
        # AMD 无大小核。X3D 双 CCD 型号绑到 3D 缓存那颗 CCD 才有意义，
        # 但从 PowerShell 无法可靠判断哪颗 CCD 带缓存，因此不猜、不动。
        if ($t.Name -match '(?i)X3D') {
            $t.Kind = "AMD X3D"
            $t.Note = "X3D 型号建议用 AMD 官方 Game Bar 或 Process Lasso 绑到 3D 缓存 CCD，本工具无法可靠识别是哪颗，不做处理"
        } else {
            $t.Kind = "AMD 对称多核"
            $t.Note = "无大小核之分，绑核没有意义"
        }
        return $t
    }
    $t.Note = "非 Intel/AMD，未做拓扑判断"
    return $t
}
# 兼容旧调用
function Get-PCoreInfo {
    $t = Get-CpuTopo
    return @{ Hybrid=($t.Kind -eq "Intel 混合架构"); PCores=$t.PCores; PThreads=$t.PThreads;
              ECores=$t.ECores; Threads=$t.Threads; Mask=$t.Mask; Note=$t.Note; Kind=$t.Kind; Vendor=$t.Vendor }
}

function Find-ApexDir {
    $cands = @()
    $libs = @()
    $steam = $null
    try { $steam = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    if (-not $steam) { try { $steam = (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch { } }
    if ($steam) {
        $steam = $steam -replace '/','\'
        $libs += $steam
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s*"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\','\')
            }
        }
    }
    foreach ($l in $libs) { if ($l) { $cands += (Join-Path $l "steamapps\common\Apex Legends") } }
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $d.Root) { continue }
        $cands += (Join-Path $d.Root "EA Games\Apex Legends")
        $cands += (Join-Path $d.Root "Origin Games\Apex Legends")
        $cands += (Join-Path $d.Root "Program Files\EA Games\Apex Legends")
        $cands += (Join-Path $d.Root "Program Files (x86)\Origin Games\Apex Legends")
    }
    foreach ($c in $cands) {
        if ($c -and (Test-Path $c)) {
            foreach ($n in $APEXNAMES) { if (Test-Path (Join-Path $c $n)) { return $c } }
        }
    }
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}
function Get-ApexExes($dir){
    $r = @()
    if (-not $dir) { return $r }
    foreach ($n in $APEXNAMES) {
        $p = Join-Path $dir $n
        if (Test-Path $p) { $r += $p }
    }
    return $r
}
$K_MM   = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
$K_MMG  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
$K_MOUSE= "HKCU:\Control Panel\Mouse"
$K_TCPIF= "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"

# 游戏进程优先级(MMCSS)。Windows 默认偏保守，游戏线程拿到的时间片和IO优先级都不高。
# Type 区分 DWord/String，写错类型会被系统忽略。
# MMCSS 按本机情况自适应，不写死。
#  SystemResponsiveness 是留给"非多媒体"任务的百分比，默认 20。
#    调太低会饿死后台和音频服务，所以按核心数决定激进程度。
#  SFIO Priority 提到 High 在 SSD 上是净收益，机械盘上会加剧寻道，所以看系统盘类型。
$script:MMCACHE = $null
function Get-MmPlan {
    if ($script:MMCACHE) { return $script:MMCACHE }
    $logi = 8
    try { $logi = [int](Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).NumberOfLogicalProcessors } catch { }
    $sr = 10
    if ($logi -le 4)  { $sr = 14 }   # 核心少：后台留多一点，否则会卡顿
    if ($logi -ge 16) { $sr = 5 }    # 核心多：可以更偏向游戏
    $sfio = "High"
    try {
        $part = Get-Partition -DriveLetter C -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$($part.DiskNumber)" } | Select-Object -First 1
        if ($pd -and $pd.MediaType -eq 'HDD') { $sfio = "Normal" }
    } catch { }
    $script:MMCACHE = @(
        @{ K="MM_SR";    Path=$K_MM;  Name="SystemResponsiveness"; V=$sr;    T="DWord";  N="后台占用上限" },
        @{ K="MM_GPU";   Path=$K_MMG; Name="GPU Priority";         V=8;      T="DWord";  N="游戏 GPU 优先级" },
        @{ K="MM_PRI";   Path=$K_MMG; Name="Priority";             V=6;      T="DWord";  N="游戏进程优先级" },
        @{ K="MM_SCHED"; Path=$K_MMG; Name="Scheduling Category";  V="High"; T="String"; N="游戏调度等级" },
        @{ K="MM_SFIO";  Path=$K_MMG; Name="SFIO Priority";        V=$sfio;  T="String"; N="游戏读写优先级" }
    )
    return $script:MMCACHE
}
# 内存与系统缓存实况
function Get-MemInfo {
    $h = @{ TotalMB=0; AvailMB=0; StandbyMB=0; UsedPct=0 }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $h.TotalMB = [int]([double]$os.TotalVisibleMemorySize/1024)
        $h.AvailMB = [int]([double]$os.FreePhysicalMemory/1024)
        if ($h.TotalMB -gt 0) { $h.UsedPct = [int]((($h.TotalMB-$h.AvailMB)/$h.TotalMB)*100) }
    } catch { }
    try {
        $m = Get-CimInstance Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
        $sb = [double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCacheReserveBytes + [double]$m.StandbyCacheCoreBytes
        $h.StandbyMB = [int]($sb/1MB)
    } catch { }
    return $h
}
# 鼠标"提高指针精确度"(加速)，FPS 里应当关闭，保证同样距离对应同样转角
function Get-MousePlan {
    return @(
        @{ K="MS_SPEED"; Name="MouseSpeed";      V="0"; N="指针加速" },
        @{ K="MS_T1";    Name="MouseThreshold1"; V="0"; N="加速阈值1" },
        @{ K="MS_T2";    Name="MouseThreshold2"; V="0"; N="加速阈值2" }
    )
}

# P 核逻辑处理器掩码。Intel 混合架构下 P 核带超线程排在前面，E 核单线程排在后面。
# P核数 = 逻辑数 - 物理数，占用逻辑编号 0 .. 2*P-1


# 虚拟显示适配器会参与桌面合成，游戏时是纯开销
function Get-VirtualDisplays {
    $r = @()
    try {
        foreach ($v in (Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
            if ($v.Name -match '(?i)virtual|idd|remote|dummy|parsec|sunshine') { $r += $v.Name }
        }
    } catch { }
    return $r
}

# MMCSS 多媒体任务配置完整性。
# Tasks 下的任务名不是装饰：音频引擎和 Media Foundation 建立播放线程时要调
# AvSetMmThreadCharacteristics("Audio") / ("Playback") 向多媒体类调度器注册。
# 任务名缺失 -> 返回 ERROR_INVALID_TASK_NAME(1550) -> 整条媒体管线起不来，
# 表现为全系统音视频都放不了(WMP/MF 报 0xC00D11B1)，且不分编码格式，连 WAV 都放不了。
# 本工具只写 Tasks\Games，但既然动了这个分支，就该顺带保证其余 8 项完好。
$MMTASKS = @(
  @{ N="Audio";                 BG="True";  Pri=6; Sched="Medium"; SFIO="Normal" },
  @{ N="Capture";               BG="False"; Pri=2; Sched="Medium"; SFIO="Normal" },
  @{ N="DisplayPostProcessing"; BG="False"; Pri=2; Sched="Medium"; SFIO="Normal" },
  @{ N="Distribution";          BG="False"; Pri=2; Sched="Medium"; SFIO="Normal" },
  @{ N="Low Latency";           BG="False"; Pri=2; Sched="Medium"; SFIO="Normal" },
  @{ N="Playback";              BG="True";  Pri=2; Sched="Medium"; SFIO="Normal" },
  @{ N="Pro Audio";             BG="True";  Pri=1; Sched="High";   SFIO="Normal" },
  @{ N="Window Manager";        BG="False"; Pri=6; Sched="High";   SFIO="Normal" }
)
# 以 API 实际能否注册为准，而不是看键在不在 —— 键在但内容坏了照样会失败
function Test-MmTaskName($name) {
    try {
        $i = [uint32]0
        $h = [MmcssNative]::AvSetMmThreadCharacteristicsW($name, [ref]$i)
        if ($h -eq [IntPtr]::Zero) { return $false }
        [void][MmcssNative]::AvRevertMmThreadCharacteristics($h)
        return $true
    } catch { return $true }   # 探测本身出错就别误报成"损坏"
}
function Get-MmTasksMissing {
    $miss = @()
    foreach ($t in $MMTASKS) { if (-not (Test-MmTaskName $t.N)) { $miss += $t.N } }
    return $miss
}
function Repair-MmTasks {
    $fixed = @()
    foreach ($t in $MMTASKS) {
        if (Test-MmTaskName $t.N) { continue }
        $p = Join-Path "$K_MM\Tasks" $t.N
        try {
            if (-not (Test-Path $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
            New-ItemProperty -Path $p -Name "Affinity"            -Value 0        -PropertyType DWord  -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $p -Name "Background Only"     -Value $t.BG    -PropertyType String -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $p -Name "Clock Rate"          -Value 10000    -PropertyType DWord  -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $p -Name "GPU Priority"        -Value 8        -PropertyType DWord  -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $p -Name "Priority"            -Value $t.Pri   -PropertyType DWord  -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $p -Name "Scheduling Category" -Value $t.Sched -PropertyType String -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $p -Name "SFIO Priority"       -Value $t.SFIO  -PropertyType String -Force -ErrorAction Stop | Out-Null
            $fixed += $t.N
        } catch { }
    }
    if ($fixed.Count -gt 0) {
        # MMCSS 服务启动时缓存任务表，补完键必须重启它才认。
        # Audiosrv / AudioEndpointBuilder 依赖 MMCSS，直接 Restart -Force 会把它们停掉且不拉起来，
        # 所以自己先停后起；拉起放在 finally，保证中途异常也不会把用户音频留在停止状态。
        $wasAudio = $false; $wasEpb = $false
        try {
            $wasAudio = ((Get-Service Audiosrv -ErrorAction SilentlyContinue).Status -eq "Running")
            $wasEpb   = ((Get-Service AudioEndpointBuilder -ErrorAction SilentlyContinue).Status -eq "Running")
            Stop-Service Audiosrv -Force -ErrorAction SilentlyContinue
            Stop-Service AudioEndpointBuilder -Force -ErrorAction SilentlyContinue
            Restart-Service MMCSS -Force -ErrorAction SilentlyContinue
        } finally {
            if ($wasEpb)   { Start-Service AudioEndpointBuilder -ErrorAction SilentlyContinue }
            if ($wasAudio) { Start-Service Audiosrv -ErrorAction SilentlyContinue }
        }
    }
    return $fixed
}
function Test-MmccsOk {
    foreach ($m in (Get-MmPlan)) {
        $cur = RegGet $m.Path $m.Name
        if ("$cur" -ne "$($m.V)") { return $false }
    }
    return $true
}
# 以系统实际生效值为准，注册表只是持久化副本
function Test-MouseOk {
    try {
        $p = New-Object int[] 3
        $ok = [MouseNative]::SystemParametersInfo(0x0003, 0, $p, 0)
        if ($ok) { return (($p[0] -eq 0) -and ($p[1] -eq 0) -and ($p[2] -eq 0)) }
    } catch { }
    foreach ($m in (Get-MousePlan)) {
        if ("$(RegGet $K_MOUSE $m.Name)" -ne "$($m.V)") { return $false }
    }
    return $true
}
# 找出有默认网关的网卡接口 GUID，用于关闭 小包合并小包
function Get-ActiveNetIfs {
    $r = @()
    try {
        foreach ($cfg in (Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction Stop)) {
            if ($cfg.DefaultIPGateway -and $cfg.SettingID) { $r += $cfg.SettingID }
        }
    } catch { }
    return $r
}
function Test-NagleOff {
    $ifs = Get-ActiveNetIfs
    if ($ifs.Count -eq 0) { return $null }
    foreach ($g in $ifs) {
        $p = Join-Path $K_TCPIF $g
        if ((RegGet $p "TcpAckFrequency") -ne 1) { return $false }
        if ((RegGet $p "TCPNoDelay") -ne 1) { return $false }
    }
    return $true
}

# 有官方控制接口的程序，优先用它自己的方式，而不是关掉。
# 壁纸引擎实测: -control pause 后进程 PID 不变，等于完全没有关闭过，
# 自然也不会有"异常关闭"的记录。
$SOFTCTRL = @{
    "wallpaper64" = @{ Pause="-control pause"; Resume="-control play"; Label="壁纸引擎" }
    "wallpaper32" = @{ Pause="-control pause"; Resume="-control play"; Label="壁纸引擎" }
}

# 分三级关闭：官方接口 -> 发 WM_CLOSE 等它自己退 -> 实在不退才强制
# 返回 pause / graceful / forced / failed
function Close-AppNicely($procName, $waitMs){
    $ps = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if ($ps.Count -eq 0) { return "gone" }

    # 一级：官方控制接口
    if ($SOFTCTRL.ContainsKey($procName)) {
        $exe = $null
        try { $exe = $ps[0].MainModule.FileName } catch { }
        if ($exe -and (Test-Path $exe)) {
            try {
                Start-Process -FilePath $exe -ArgumentList $SOFTCTRL[$procName].Pause -WindowStyle Hidden -ErrorAction Stop
                Start-Sleep -Milliseconds 600
                return "pause"
            } catch { }
        }
    }

    # 二级：给所有顶层窗口发 WM_CLOSE，让程序走自己的退出流程
    foreach ($p in $ps) {
        try {
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() }
            else { [void][WinClose]::CloseByPid([uint32]$p.Id) }
        } catch { }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $waitMs) {
        if (@(Get-Process -Name $procName -ErrorAction SilentlyContinue).Count -eq 0) { return "graceful" }
        Start-Sleep -Milliseconds 200
    }

    # 三级：还在就强制结束
    Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    if (@(Get-Process -Name $procName -ErrorAction SilentlyContinue).Count -eq 0) { return "forced" }
    return "failed"
}

function Get-BgProcs {
    $all = @{}
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if (-not $all.ContainsKey($p.ProcessName)) { $all[$p.ProcessName] = @{ Count=0; Mem=0 } }
        $all[$p.ProcessName].Count++
        $all[$p.ProcessName].Mem += $p.WorkingSet64
    }
    $found = @()
    foreach ($g in $KILLGROUPS) {
        foreach ($n in $g.names) {
            # 语音 / 直播软件直接跳过，不进清单，也就不可能被误杀
            if ($PROTECTED -contains $n) { continue }
            if ($all.ContainsKey($n)) {
                $found += @{ Name=$n; Cat=$g.cat; Risky=$g.risky; Count=$all[$n].Count; MB=[math]::Round($all[$n].Mem/1MB) }
            }
        }
    }
    return $found
}

# 统一设置一个交流电下的电源项：先取消隐藏，再写值
function Set-PowerAc($scheme,$sub,$setting,$value){
    powercfg -attributes $sub $setting -ATTRIB_HIDE 2>$null | Out-Null
    powercfg -setacvalueindex $scheme $sub $setting $value 2>$null | Out-Null
}
# 还原专用：只写值，不动隐藏属性。
# 优化时取消隐藏是为了让用户能在 Windows 电源选项里自己核对，
# 还原时如果再调一次 attributes 反而是又一次改动，所以分开。
function Set-PowerAcRaw($scheme,$sub,$setting,$value){
    powercfg -setacvalueindex $scheme $sub $setting $value 2>$null | Out-Null
}
# 本工具会写入的全部电源项，按 备份键名 / 子组 / 设置 / 目标值 排列
# 卓越性能是 Win10 1803+ 自带的隐藏模板。官方唤起方式就是从它复制一份。
# 但它可能被 OEM 移除、或被清理工具删掉。好在 -duplicatescheme 支持指定目标 GUID，
# 所以模板没了也能用高性能重建回来，让任何机器都能拿到卓越性能。
function Ensure-UltimateTemplate {
    $o = (powercfg -duplicatescheme $ULTGUID 2>&1) -join " "
    $m = [regex]::Match($o,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success -and $m.Value -ne $ULTGUID) {
        powercfg -delete $m.Value 2>$null | Out-Null   # 只是探测，副本不留
        return "ok"
    }
    # 模板缺失：用高性能重建一个同 GUID 的隐藏模板
    powercfg -duplicatescheme $HIGHGUID $ULTGUID 2>$null | Out-Null
    powercfg -changename $ULTGUID "卓越性能" "为高端系统提供极致性能" 2>$null | Out-Null
    $o2 = (powercfg -duplicatescheme $ULTGUID 2>&1) -join " "
    $m2 = [regex]::Match($o2,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m2.Success -and $m2.Value -ne $ULTGUID) {
        powercfg -delete $m2.Value 2>$null | Out-Null
        return "rebuilt"
    }
    return "failed"
}

function Get-PowerPlan {
    # 频率下限锁 100%：所有机型一律应用，优先保证目标帧数。
    # 代价是空载持续高频发热，笔记本上会压缩散热余量；
    # 这个取舍不在这里回避，而是交给"瓶颈实测"用实际温度数据来暴露。
    return @(
        @{ K="PMIN";  Sub=$SUB_PROC;  Set=$SET_PMIN;  V=100; N="CPU 频率下限" },
        @{ K="PMAX";  Sub=$SUB_PROC;  Set=$SET_PMAX;  V=100; N="CPU 频率上限" },
        @{ K="ASPM";  Sub=$SUB_PCIE;  Set=$SET_ASPM;  V=0;   N="显卡通道省电" },
        @{ K="USBS";  Sub=$SUB_USB;   Set=$SET_USBS;  V=0;   N="USB 选择性暂停" },
        @{ K="DIDLE"; Sub=$SUB_DISK;  Set=$SET_DIDLE; V=0;   N="硬盘休眠" },
        @{ K="VIDLE"; Sub=$SUB_VIDEO; Set=$SET_VIDLE; V=0;   N="显示器休眠" },
        @{ K="STDBY"; Sub=$SUB_SLEEP; Set=$SET_STDBY; V=0;   N="系统待机" },
        @{ K="GFX";   Sub=$SUB_GFX;   Set=$SET_GFX;   V=3;   N="可切换显卡" },
        # 以下是"卓越性能"区别于"高性能"的核心项。显式写入，
        # 这样即使模板缺失、或 OEM 改过模板内容，最终效果也一致。
        # 取值范围已从注册表定义中逐项核对过。
        @{ K="CPARK"; Sub=$SUB_PROC;  Set=$SET_CPARK; V=100; N="核心停放" },
        @{ K="BOOST"; Sub=$SUB_PROC;  Set=$SET_BOOST; V=2;   N="性能提升模式" },
        @{ K="PERFINC"; Sub=$SUB_PROC; Set=$SET_PERFINC; V=2; N="性能上升策略" },
        @{ K="AUTON"; Sub=$SUB_PROC;  Set=$SET_AUTON; V=1;   N="处理器自主模式" },
        @{ K="LATHINT"; Sub=$SUB_PROC; Set=$SET_LATHINT; V=99; N="延迟敏感度响应" }
        # 刻意不设"禁用空闲状态": 那会彻底关掉 C-state，发热和功耗代价极大，
        # 而卓越性能本身并不包含这一项，属于常见误传。
    )
}
# 读取某个电源设置在本机允许的最大值。
# 枚举型会列出"可能的设置索引"，区间型会给"最大可能的设置"。
# 不同机器范围不同（例如 Intel Graphics Power Plan 只有 0/1/2，写 3 会被拒绝），
# 所以目标值必须按本机上限夹紧，不能硬编码。
# 取值上限优先从注册表的设置定义里读：
#   处理器子组 95 项设置中有 93 项默认隐藏，powercfg /query 看不到它们，
#   而取消隐藏又需要管理员权限，把"能不能读范围"和"有没有权限"绑在一起是错的。
#   注册表定义是只读的、不受隐藏影响，作为主路径更可靠。
function Get-SettingMaxFromReg($sub,$set){
    $k = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\$sub\$set"
    if (-not (Test-Path $k)) { return $null }
    try {
        $p = Get-ItemProperty $k -ErrorAction Stop
        if ($null -ne $p.ValueMax) { return [int64]$p.ValueMax }
    } catch { }
    # 枚举型：子键名是数字索引，取最大值
    $idx = @()
    foreach ($s in (Get-ChildItem $k -ErrorAction SilentlyContinue)) {
        if ($s.PSChildName -match '^\d+$') { $idx += [int64]$s.PSChildName }
    }
    if ($idx.Count -gt 0) { return ($idx | Measure-Object -Maximum).Maximum }
    return $null
}
function Get-SettingMax($scheme,$sub,$set){
    $r = Get-SettingMaxFromReg $sub $set
    if ($null -ne $r) { return $r }
    # 注册表里没有定义，再退回 powercfg 查询（需要该项可见）
    powercfg -attributes $sub $set -ATTRIB_HIDE 2>$null | Out-Null
    $o = powercfg /query $scheme $sub $set 2>$null
    if (-not $o) { return $null }
    $vals = @()
    foreach ($l in $o) {
        if ($l -match '(?i)(可能的设置索引|Possible Setting Index)\s*[:：]\s*([0-9A-Fa-fx]+)') {
            try {
                $s = $matches[2]
                if ($s -match '^0[xX]') { $vals += [int64][Convert]::ToUInt32($s,16) } else { $vals += [int64]$s }
            } catch { }
        }
        elseif ($l -match '(?i)(最大可能的设置|Maximum Possible Setting)\s*[:：]\s*0x([0-9A-Fa-f]+)') {
            try { $vals += [int64][Convert]::ToUInt32($matches[2],16) } catch { }
        }
    }
    if ($vals.Count -eq 0) { return $null }
    return ($vals | Measure-Object -Maximum).Maximum
}
# 把这些项写进指定方案并逐条回读，返回每一项的明细
function Apply-PowerPlan($scheme){
    $res = @()
    foreach ($p in (Get-PowerPlan)) {
        if ($p.ContainsKey("SkipOn") -and $p.SkipOn) {
            $res += @{ N=$p.N; State="skip"; Detail=$p.SkipWhy }
            continue
        }
        $max = Get-SettingMax $scheme $p.Sub $p.Set
        if ($null -eq $max) {
            $res += @{ N=$p.N; State="skip"; Detail="本机没有这一项" }
            continue
        }
        $t = $p.V
        if ($t -gt $max) { $t = [int]$max }
        Set-PowerAc $scheme $p.Sub $p.Set $t
        $rv = Get-AcIndexG $scheme $p.Sub $p.Set
        if ($rv -eq $t) {
            if ($t -ne $p.V) { $res += @{ N=$p.N; State="ok"; Detail=("= " + $t + "（本机最高档，目标 " + $p.V + " 超范围）") } }
            else { $res += @{ N=$p.N; State="ok"; Detail=("= " + $t) } }
        } else {
            $res += @{ N=$p.N; State="bad"; Detail=("写入 " + $t + " 后回读为 " + $rv) }
        }
    }
    powercfg -setactive $scheme 2>$null | Out-Null
    return $res
}
# 某个方案里这些项的当前值，用于在改动用户自有方案前留底
function Read-PowerPlan($scheme){
    $h = @{}
    foreach ($p in (Get-PowerPlan)) {
        $v = Get-AcIndexG $scheme $p.Sub $p.Set
        if ($null -eq $v) { $h["ORIG_"+$p.K] = "NOTSET" } else { $h["ORIG_"+$p.K] = [string]$v }
    }
    return $h
}
function Get-AcIndexG($scheme,$sub,$setting){
    $o = powercfg /query $scheme $sub $setting 2>$null
    $line = $o | Where-Object { $_ -match '(?i)(当前交流|Current AC)' } | Select-Object -First 1
    if ($line -and $line -match '0x([0-9a-fA-F]+)') { return [Convert]::ToInt32($matches[1],16) }
    return $null
}
# 分层采集：越贵的东西查得越少，避免 800ms 一轮把 CPU 吃掉
#   每轮   : nvidia-smi 显卡实时（用户最想看到的活数据）
#   每 2 轮: 注册表 + 进程扫描（中等开销）
#   每 5 轮: powercfg / WMI / 备份文件（进程spawn + WMI，最贵）
# $tick=0 时全部采集，用于强制刷新
function Collect-Status($apexDir, $prev, $tick){
    $d = @{}
    if ($prev) { foreach ($k in $prev.Keys) { $d[$k] = $prev[$k] } }
    $full = ($tick -eq 0)
    $mid  = $full -or ($tick % 2 -eq 0)
    $slow = $full -or ($tick % 5 -eq 0)

    $d.Gpu = Get-GpuLive
    if (-not $d.ContainsKey("GpuName")) { $vd0 = Get-GpuVendor; $d.GpuName = $vd0.Vendor + " " + $vd0.Name }
    if ($mid) { $d.Mem = Get-MemInfo }

    if ($mid) {
        $d.Dvr  = RegGet $K_GCS "GameDVR_Enabled"
        $d.Hags = RegGet $K_GD  "HwSchMode"
        $exes = Get-ApexExes $apexDir
        $d.ApexCount = $exes.Count
        $done = 0
        foreach ($e in $exes) { if (RegHas $K_GPU $e) { $done++ } }
        $d.ApexDone = $done
        $bg = Get-BgProcs
        $d.BgCount = $bg.Count
        $d.BgMB = 0
        foreach ($b in $bg) { $d.BgMB += $b.MB }
    }

    if ($slow) {
        $d.Vbs = Get-VbsRunning
        $d.HasBackup = Test-Path $BKFILE
        $d.VbsPendingOff = Test-Path $VBSFILE
        # 备份里记录的"原本 VBS 是否开着"，标记文件丢失后仍能还原
        $d.BkVbsWas = -1
        if ($d.HasBackup) {
            try {
                foreach ($bl in [System.IO.File]::ReadAllLines($BKFILE,[System.Text.Encoding]::UTF8)) {
                    if ($bl -match '^VBSRUNNING=(\d+)') { $d.BkVbsWas = [int]$matches[1] }
                }
            } catch { }
        }
        $d.Mem    = Get-MemInfo
        $d.IsLaptop = (Get-MachineKind).IsLaptop
        $d.PwrSrc   = Get-PowerSource
        $d.Mmcss  = Test-MmccsOk
        $d.MmMiss = @(Get-MmTasksMissing)
        $d.Mouse  = Test-MouseOk
        $d.Nagle  = Test-NagleOff
        $d.VDisp  = @(Get-VirtualDisplays)
        $d.Scheme = Get-SchemeName
        $sg = Get-SchemeGuid
        if ($sg) {
            $d.Pmin = Get-AcIndexG $sg $SUB_PROC $SET_PMIN
            $d.Aspm = Get-AcIndexG $sg $SUB_PCIE $SET_ASPM
        } else {
            $d.Pmin = Get-AcIndex "SUB_PROCESSOR" "PROCTHROTTLEMIN"
            $d.Aspm = Get-AcIndex "SUB_PCIEXPRESS" "ASPM"
        }
    }
    $d.Stamp = Get-Date
    return $d
}
# fps_max 建议值。依据只有两条硬事实，不猜硬件性能：
#   1) 高于屏幕刷新率的帧画面上看不到
#   2) Apex 引擎硬上限就是 300
# 所以上限 = min(刷新率, 300)。能不能跑到是另一回事，
# 跑不到时这个上限根本不会生效，不会有副作用。
function Get-FpsCapAdvice {
    $hz = 0
    try {
        $m = Get-CimInstance Win32_VideoController -ErrorAction Stop |
             Where-Object { $_.CurrentRefreshRate -and $_.CurrentRefreshRate -gt 0 } |
             Sort-Object CurrentRefreshRate -Descending | Select-Object -First 1
        if ($m) { $hz = [int]$m.CurrentRefreshRate }
    } catch { }
    $engine = 300
    if ($hz -le 0) {
        return @{ Cap=$engine; Hz=0; Basis="未读到刷新率，按引擎上限 300" }
    }
    if ($hz -ge $engine) {
        return @{ Cap=$engine; Hz=$hz; Basis=("屏幕 " + $hz + "Hz 已达/超过引擎上限，取 300") }
    }
    return @{ Cap=$hz; Hz=$hz; Basis=("与屏幕 " + $hz + "Hz 刷新率一致") }
}
function Get-SysInfo {
    $i = @{ Cpu="未知 CPU"; Gpu="未知显卡"; Ram=""; Disp="" }
    try { $i.Cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() } catch { }
    try {
        $vcs = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch '(?i)virtual|basic|remote|idd|meta' })
        $g = $vcs | Where-Object { $_.Name -match '(?i)nvidia|radeon|geforce|arc' } | Select-Object -First 1
        if (-not $g) { $g = $vcs | Select-Object -First 1 }
        if ($g) { $i.Gpu = $g.Name.Trim() }
        $m = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
        if ($m) { $i.Disp = "$($m.CurrentHorizontalResolution)x$($m.CurrentVerticalResolution) @$($m.CurrentRefreshRate)Hz" }
    } catch { }
    try { $i.Ram = "" + [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB) + "GB" } catch { }
    return $i
}
'@

. ([scriptblock]::Create($SharedFns))

# ---------- 3. 配色与字体 ----------
function C($r,$g,$b) { return [System.Drawing.Color]::FromArgb($r,$g,$b) }
$C_BG      = C 14 18 23
$C_CARD    = C 23 30 38
$C_CARD2   = C 30 39 49
$C_HOVER   = C 38 49 61
$C_LINE    = C 40 52 64
$C_TEXT    = C 228 236 243
$C_DIM     = C 132 149 166
$C_FAINT   = C 92 107 122
$C_OFF     = C 70 82 95
$C_OK      = C 74 214 154
$C_WARN    = C 240 172 74
$C_CRIT    = C 255 106 122
$C_ACCENT  = C 45 205 200

$famUI = "Segoe UI"
foreach ($f in @("Microsoft YaHei UI","Microsoft YaHei","PingFang SC","Segoe UI")) {
    try { $tf = New-Object System.Drawing.FontFamily($f); $famUI = $f; $tf.Dispose(); break } catch { }
}
$famMono = "Consolas"
foreach ($f in @("Cascadia Mono","Consolas","Courier New")) {
    try { $tf = New-Object System.Drawing.FontFamily($f); $famMono = $f; $tf.Dispose(); break } catch { }
}
$F_H1   = New-Object System.Drawing.Font($famUI,16,[System.Drawing.FontStyle]::Bold)
$F_H2   = New-Object System.Drawing.Font($famUI,10,[System.Drawing.FontStyle]::Bold)
$F_UI   = New-Object System.Drawing.Font($famUI,9.5)
$F_SM   = New-Object System.Drawing.Font($famUI,8)
$F_BTN  = New-Object System.Drawing.Font($famUI,10,[System.Drawing.FontStyle]::Bold)
$F_NUM  = New-Object System.Drawing.Font($famMono,19,[System.Drawing.FontStyle]::Bold)
$F_MONO = New-Object System.Drawing.Font($famMono,9.5)
$F_MSM  = New-Object System.Drawing.Font($famMono,8.5)
$F_DOT  = New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold)

# ---------- 4. 主窗口 ----------
Boot-Log "开始读取硬件信息"
Splash-Say "正在读取硬件信息..."
$SYS = Get-SysInfo
Boot-Log "开始查找 Apex 目录"
Splash-Say "正在查找 Apex 安装目录..."
$APEXDIR = Find-ApexDir
Boot-Log "开始构建界面"
Splash-Say "正在构建界面..."

$form = New-Object System.Windows.Forms.Form
$form.Text = "Apex 帧数优化工具"
$form.ClientSize = (Sz 1060 772)
Boot-Log ("创建窗口: 缩放=" + [int]($SCALE*100) + "%  客户区=" + $form.ClientSize.ToString())
$form.StartPosition = "CenterScreen"
$form.BackColor = $C_BG
$form.ForeColor = $C_TEXT
$form.Font = $F_UI
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
foreach ($cand in @((Join-Path $here "icon.png"), (Join-Path $here "app.ico"))) {
    if (Test-Path $cand) {
        try {
            if ($cand -match '\.ico$') { $form.Icon = New-Object System.Drawing.Icon($cand) }
            else {
                $src = New-Object System.Drawing.Bitmap($cand)
                $big = New-Object System.Drawing.Bitmap(256,256)
                $gg = [System.Drawing.Graphics]::FromImage($big)
                $gg.InterpolationMode = "HighQualityBicubic"
                $gg.Clear([System.Drawing.Color]::Transparent)
                $gg.DrawImage($src,0,0,256,256)
                $gg.Dispose(); $src.Dispose()
                $form.Icon = [System.Drawing.Icon]::FromHandle($big.GetHicon())
            }
            break
        } catch { }
    }
}

function New-Label($text,$font,$color,$x,$y,$w,$h,$parent){
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Font = $font; $l.ForeColor = $color
    $l.Location = (Pt $x $y); $l.Size = (Sz $w $h)
    $l.BackColor = [System.Drawing.Color]::Transparent
    # 硬件名称、状态描述都是变长的，不同机器差别很大。
    # 固定宽度 + 自动省略号，超长截断成 …，绝不溢出到相邻控件上。
    $l.AutoSize = $false
    $l.AutoEllipsis = $true
    $parent.Controls.Add($l)
    return $l
}
function New-Card($x,$y,$w,$h,$parent){
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = (Pt $x $y); $p.Size = (Sz $w $h); $p.BackColor = $C_CARD
    $parent.Controls.Add($p)
    return $p
}

# ===== 顶部 =====
$hdr = New-Object System.Windows.Forms.Panel
$hdr.Location = (Pt 0 0); $hdr.Size = (Sz 1060 68); $hdr.BackColor = $C_CARD
$form.Controls.Add($hdr)
$rail = New-Object System.Windows.Forms.Panel
$rail.Location = (Pt 0 0); $rail.Size = (Sz 4 68); $rail.BackColor = $C_ACCENT
$hdr.Controls.Add($rail)
New-Label "Apex 帧数优化工具" $F_H1 $C_TEXT 20 12 380 32 $hdr | Out-Null
New-Label ("{0}  ·  {1}  ·  {2}  {3}" -f $SYS.Cpu,$SYS.Gpu,$SYS.Ram,$SYS.Disp) $F_MSM $C_FAINT 22 43 762 18 $hdr | Out-Null
$lblAuthor = New-Label "XIAOMING6680 制作" (New-Object System.Drawing.Font($famMono,10,[System.Drawing.FontStyle]::Bold)) $C_ACCENT 800 24 240 20 $hdr
$lblAuthor.TextAlign = "MiddleRight"

# ===== 左侧按钮 =====
# 按钮分四级，视觉权重对应使用频率与后果轻重：
#   primary 主操作 / normal 常规 / caution 有代价 / revert 恢复 / link 次要
$btnLayout = @(
  @{ t="group"; n="配置优化" },
  @{ t="primary"; k="opt";  n="一键优化";        d="电源 · 调度 · 录制 · 显卡指定" },
  @{ t="caution"; k="vbs";  n="关闭虚拟化安全"; d="约提升 5~10% 帧率 · 影响虚拟机" },
  @{ t="group"; n="每局开始前" },
  @{ t="normal";  k="prep"; n="游戏前准备";      d="释放系统缓存 · 结束占用后台" },
  @{ t="group"; n="性能诊断" },
  @{ t="normal";  k="bench";n="瓶颈实测";        d="采样 60 秒 · 定位性能瓶颈" },
  @{ t="group"; n="恢复" },
  @{ t="revert";  k="rest"; n="还原全部设置";    d="逐项写回原始配置并校验" },
  @{ t="link"; k="dir"; n="指定 Apex 安装目录" },
  @{ t="link"; k="bk";  n="查看原始配置备份" }
)
$buttons = @{}
$btnSubs = @{}
$by = 84
foreach ($bd in $btnLayout) {
    if ($bd.t -eq "group") {
        $gf = New-Object System.Drawing.Font($famUI,8.5,[System.Drawing.FontStyle]::Bold)
        $gl = New-Label $bd.n $gf $C_DIM 20 $by 240 16 $form
        $ln = New-Object System.Windows.Forms.Panel
        $ln.Location = (Pt 20 ($by+19)); $ln.Size = (Sz 246 1); $ln.BackColor = $C_LINE
        $form.Controls.Add($ln)
        $by += 30
        continue
    }
    $bh = 40
    if ($bd.t -eq "primary") { $bh = 48 }
    if ($bd.t -eq "link")    { $bh = 30 }

    $b = New-Object System.Windows.Forms.Button
    $b.Text = "   " + $bd.n
    $b.Location = (Pt 20 $by); $b.Size = (Sz 246 $bh)
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 1
    $b.TextAlign = "MiddleLeft"
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    $b.Font = $F_BTN

    switch ($bd.t) {
        "primary" {
            $b.Font = New-Object System.Drawing.Font($famUI,11,[System.Drawing.FontStyle]::Bold)
            $b.BackColor = $C_ACCENT; $b.ForeColor = $C_BG
            $b.FlatAppearance.BorderColor = $C_ACCENT
            $b.FlatAppearance.MouseOverBackColor = (C 90 225 220)
        }
        "normal" {
            $b.BackColor = $C_CARD2; $b.ForeColor = $C_TEXT
            $b.FlatAppearance.BorderColor = $C_LINE
            $b.FlatAppearance.MouseOverBackColor = $C_HOVER
        }
        "caution" {
            $b.BackColor = $C_CARD; $b.ForeColor = $C_WARN
            $b.FlatAppearance.BorderColor = (C 92 70 34)
            $b.FlatAppearance.MouseOverBackColor = $C_CARD2
        }
        "revert" {
            $b.BackColor = $C_CARD; $b.ForeColor = $C_DIM
            $b.FlatAppearance.BorderColor = $C_LINE
            $b.FlatAppearance.MouseOverBackColor = $C_CARD2
        }
        "link" {
            $b.Font = $F_UI
            $b.Text = "   " + $bd.n
            $b.BackColor = $C_BG; $b.ForeColor = $C_DIM
            $b.FlatAppearance.BorderSize = 1
            $b.FlatAppearance.BorderColor = $C_LINE
            $b.FlatAppearance.MouseOverBackColor = $C_CARD2
        }
    }
    $form.Controls.Add($b)
    $buttons[$bd.k] = $b
    if ($bd.t -eq "link") { $by += 34 }
    else {
        $btnSubs[$bd.k] = (New-Label $bd.d $F_SM $C_FAINT 24 ($by+$bh+3) 242 16 $form)
        $by += $bh + 24
    }
}

# ===== 汇总三宫格 =====
$sumDefs = @(@("ok","正常",$C_OK), @("warn","建议优化",$C_WARN), @("bad","需处理",$C_CRIT))
$sumNum = @{}
$sx = 290
foreach ($sd in $sumDefs) {
    $c = New-Card $sx 88 216 62 $form
    $sumNum[$sd[0]] = (New-Label "-" $F_NUM $sd[2] 16 8 60 34 $c)
    New-Label $sd[1] $F_SM $C_DIM 18 40 120 16 $c | Out-Null
    $sx += 226
}

# ===== 状态卡 =====
# 状态行以后还可能增减。卡片高度写死过一次，加了"供电方式"这行之后
# 最后一行的底边就顶到卡片外面去了。改成由行数推导高度，下面的控件
# 也跟着推导位置，这样再加行也不会切底。
$ROWTOP  = 44    # 第一行相对卡片顶部
$ROWSTEP = 25    # 行距
$ROWH    = 20    # 单行文字高度
$CARDPAD = 10    # 卡片底部留白
$GAP     = 12    # 卡片之间的间距
$CARDSY  = 162

$rowDefs = @(
  @("scheme","电源方案"), @("pmin","CPU 频率下限"), @("aspm","显卡通道省电"),
  @("mmcss","游戏进程优先级"), @("vbs","虚拟化安全防护"), @("dvr","Xbox 后台录制"),
  @("hags","硬件加速 GPU 计划"), @("mouse","鼠标指针加速"), @("nagle","网络小包合并"),
  @("apex","Apex 独显指定"), @("vdisp","虚拟显示器"), @("bg","后台常驻程序"),
  @("pwr","供电方式"), @("mem","内存 / 系统缓存"), @("backup","原始状态备份")
)
$CARDSH = $ROWTOP + $ROWSTEP * ($rowDefs.Count - 1) + $ROWH + $CARDPAD
$cardS = New-Card 290 $CARDSY 750 $CARDSH $form
New-Label "实时状态" $F_H2 $C_TEXT 18 12 200 20 $cardS | Out-Null
$lblStamp = New-Label "" $F_MSM $C_FAINT 500 14 232 18 $cardS
$lblStamp.TextAlign = "MiddleRight"

$rows = @{}
$ry = $ROWTOP
$rowIdx = 0
foreach ($rd in $rowDefs) {
    $dot = New-Label ([string][char]0x25CF) $F_DOT $C_FAINT 18 ($ry-2) 18 22 $cardS
    New-Label $rd[1] $F_UI $C_DIM 40 $ry 170 20 $cardS | Out-Null
    $val = New-Label "读取中" $F_MONO $C_TEXT 214 $ry 512 20 $cardS
    $rows[$rd[0]] = @{ Dot=$dot; Val=$val }
    $rowIdx++
    # 最后一行不画分隔线：它会紧贴卡片下边缘，看着像卡片被切了一刀
    if ($rowIdx -lt $rowDefs.Count) {
        $sep = New-Object System.Windows.Forms.Panel
        $sep.Location = (Pt 18 ($ry + $ROWH + 2)); $sep.Size = (Sz 714 1); $sep.BackColor = $C_LINE
        $cardS.Controls.Add($sep)
    }
    $ry += $ROWSTEP
}

# ===== 显卡实时卡 =====
$GPUY = $CARDSY + $CARDSH + $GAP
$cardG = New-Card 290 $GPUY 750 80 $form
New-Label "显卡实时" $F_H2 $C_TEXT 18 10 120 20 $cardG | Out-Null
$lblGpuTxt = New-Label "等待显卡数据" $F_MSM $C_FAINT 140 12 596 18 $cardG
function New-Bar($label,$x,$y,$w,$parent){
    New-Label $label $F_SM $C_DIM $x $y 60 16 $parent | Out-Null
    $tr = New-Object System.Windows.Forms.Panel
    $tr.Location = (Pt ($x+62) ($y+2)); $tr.Size = (Sz $w 12); $tr.BackColor = $C_CARD2
    $parent.Controls.Add($tr)
    $fl = New-Object System.Windows.Forms.Panel
    $fl.Location = (Pt 0 0); $fl.Size = (Sz 0 12); $fl.BackColor = $C_ACCENT
    $tr.Controls.Add($fl)
    $vl = New-Label "-" $F_MSM $C_TEXT ($x+66+$w) $y 78 16 $parent
    return @{ Track=$tr; Fill=$fl; Val=$vl; W=$w }
}
$barUtil = New-Bar "负载" 18 42 200 $cardG
$barTemp = New-Bar "温度" 400 42 190 $cardG

# ===== 左下: 手动项 =====
$FPSADV = Get-FpsCapAdvice
$cardT = New-Card 20 ($GPUY + 4) 246 158 $form
New-Label "需手动完成的配置" $F_H2 $C_WARN 14 12 220 20 $cardT | Out-Null
$ty = 38
$todoLines = if ((Get-MachineKind).IsLaptop) {
    @("1  杀毒软件信任区添加 Apex 目录",
      "2  BIOS 开独显直连 + 性能模式",
      "3  打游戏务必插电源",
      "4  Steam 启动项（可直接复制）")
} else {
    @("1  杀毒软件信任区添加 Apex 目录",
      "2  显卡面板 电源=最高性能优先",
      "3  确认显卡驱动为较新版本",
      "4  Steam 启动项（可直接复制）")
}
foreach ($line in $todoLines) {
    New-Label $line $F_MSM $C_TEXT 14 $ty 228 15 $cardT | Out-Null
    $ty += 16
}
# 启动项做成只读输入框，可以选中复制；旁边再给一个一键复制
$tbLaunch = New-Object System.Windows.Forms.TextBox
$tbLaunch.Text = "-novid +fps_max " + $FPSADV.Cap
$tbLaunch.ReadOnly = $true
$tbLaunch.BorderStyle = "FixedSingle"
$tbLaunch.BackColor = $C_CARD2
$tbLaunch.ForeColor = $C_ACCENT
$tbLaunch.Font = $F_MSM
$tbLaunch.Location = (Pt 14 ($ty+4)); $tbLaunch.Size = (Sz 168 22)
$cardT.Controls.Add($tbLaunch)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "复制"
$btnCopy.Font = $F_SM
$btnCopy.Location = (Pt 188 ($ty+4)); $btnCopy.Size = (Sz 54 22)
$btnCopy.FlatStyle = "Flat"
$btnCopy.BackColor = $C_CARD2; $btnCopy.ForeColor = $C_TEXT
$btnCopy.FlatAppearance.BorderColor = $C_LINE
$btnCopy.FlatAppearance.MouseOverBackColor = $C_HOVER
$btnCopy.Cursor = [System.Windows.Forms.Cursors]::Hand
$cardT.Controls.Add($btnCopy)

$copyTimer = New-Object System.Windows.Forms.Timer
$copyTimer.Interval = 1400
$copyTimer.Add_Tick({ $copyTimer.Stop(); $btnCopy.Text = "复制"; $btnCopy.ForeColor = $C_TEXT })
$btnCopy.Add_Click({
    try {
        [System.Windows.Forms.Clipboard]::SetText($tbLaunch.Text)
        $btnCopy.Text = "已复制"; $btnCopy.ForeColor = $C_OK
        Log ("启动项已复制: " + $tbLaunch.Text) "ok"
    } catch {
        $btnCopy.Text = "失败"; $btnCopy.ForeColor = $C_CRIT
    }
    $copyTimer.Start()
})
New-Label ("上限依据 " + $FPSADV.Hz + "Hz 屏幕") $F_SM $C_FAINT 14 ($ty+30) 228 14 $cardT | Out-Null

# ===== 右下: 日志 =====
$LOGY = $GPUY + 80 + $GAP
$cardL = New-Card 290 $LOGY 750 70 $form
# 窗口高度也由最后一张卡片推导，以后状态行增减，窗口会自己跟上
$form.ClientSize = (Sz 1060 ($LOGY + 70 + $GAP))
$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = (Pt 8 6); $logBox.Size = (Sz 734 58)
$logBox.BackColor = $C_CARD; $logBox.ForeColor = $C_TEXT
$logBox.Font = $F_MSM; $logBox.ReadOnly = $true; $logBox.BorderStyle = "None"
$cardL.Controls.Add($logBox)

function Log($msg,$kind){
    $col = $C_TEXT
    if ($kind -eq "ok")   { $col = $C_OK }
    if ($kind -eq "warn") { $col = $C_WARN }
    if ($kind -eq "err")  { $col = $C_CRIT }
    if ($kind -eq "dim")  { $col = $C_FAINT }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor = $col
    $logBox.AppendText((Get-Date -Format "HH:mm:ss") + "  " + $msg + [Environment]::NewLine)
    $logBox.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------- 5. 状态渲染 ----------
# 只有内容真的变了才写回控件，避免 300ms 一轮的无谓重绘和闪烁
function Set-Row($key,$text,$state){
    if (-not $rows.ContainsKey($key)) { return }
    $r = $rows[$key]
    if ($r.Val.Text -ne $text) { $r.Val.Text = $text }
    $c = $C_FAINT
    if ($state -eq "ok")   { $c = $C_OK }
    if ($state -eq "warn") { $c = $C_WARN }
    if ($state -eq "bad")  { $c = $C_CRIT }
    if ($r.Dot.ForeColor -ne $c) { $r.Dot.ForeColor = $c }
    return $state
}
function Set-Text($ctl,$text){ if ($ctl.Text -ne $text) { $ctl.Text = $text } }

# VBS 按钮四态。重启后 VBS 真的关掉了，仍须能点"还原"，
# 所以判定依据是"我们是否动过"，而不是"VBS 当前是否在跑"。
$script:lastVbsState = ""
$script:lastRestState = ""
function Sync-VbsButton($d){
    $b = $buttons["vbs"]
    # 我们改过 = 有标记文件，或备份记录原本开着而现在没在跑
    $weTurnedOff = $false
    if ($d.VbsPendingOff) { $weTurnedOff = $true }
    elseif ($d.HasBackup -and ($d.BkVbsWas -eq 1) -and (-not $d.Vbs)) { $weTurnedOff = $true }

    # 状态没变就不动控件
    $st = "off"
    if ($weTurnedOff) { $st = "restore" } elseif ($d.Vbs) { $st = "disable" }
    $rst = [string]$d.HasBackup
    if ($st -eq $script:lastVbsState -and $rst -eq $script:lastRestState) { return }
    $script:lastVbsState = $st
    $script:lastRestState = $rst

    if ($weTurnedOff) {
        $b.Enabled = $true
        $b.Text = "   还原虚拟化安全"
        $b.BackColor = $C_CARD; $b.ForeColor = $C_OK
        $b.FlatAppearance.BorderColor = $C_OK
        $b.FlatAppearance.MouseOverBackColor = $C_CARD2
        $btnSubs["vbs"].Text = "已设为关闭 · 重启生效 · 点此还原"
        $btnSubs["vbs"].ForeColor = $C_FAINT
    } elseif ($d.Vbs) {
        $b.Enabled = $true
        $b.Text = "   关闭虚拟化安全"
        # 保持 caution 层级的琥珀配色，不要退回普通灰
        $b.BackColor = $C_CARD; $b.ForeColor = $C_WARN
        $b.FlatAppearance.BorderColor = (C 92 70 34)
        $b.FlatAppearance.MouseOverBackColor = $C_CARD2
        $btnSubs["vbs"].Text = "约提升 5~10% 帧率 · 影响虚拟机"
        $btnSubs["vbs"].ForeColor = $C_FAINT
    } else {
        $b.Enabled = $false
        $b.Text = "   虚拟化安全未开启"
        $b.BackColor = $C_BG; $b.ForeColor = $C_OFF
        $b.FlatAppearance.BorderColor = $C_LINE
        $btnSubs["vbs"].Text = "本机未启用，无需处理"
        $btnSubs["vbs"].ForeColor = $C_OFF
    }

    $buttons["rest"].Enabled = $d.HasBackup
    if ($d.HasBackup) {
        # 维持 revert 层级：低调，不与主操作抢视觉权重
        $buttons["rest"].ForeColor = $C_DIM
        $buttons["rest"].BackColor = $C_CARD
        $buttons["rest"].FlatAppearance.BorderColor = $C_LINE
        $btnSubs["rest"].Text = "逐项写回原始配置并校验"
        $btnSubs["rest"].ForeColor = $C_FAINT
    } else {
        $buttons["rest"].ForeColor = $C_OFF
        $buttons["rest"].BackColor = $C_BG
        $buttons["rest"].FlatAppearance.BorderColor = $C_LINE
        $btnSubs["rest"].Text = "尚无备份，暂不可用"
        $btnSubs["rest"].ForeColor = $C_OFF
    }
}

function Render-Status($d){
    if (-not $d) { return }
    # 分层采集下，慢速项可能还没填过，等第一次完整采集完再画
    if (-not $d.ContainsKey("HasBackup")) { return }
    $n = @{ ok=0; warn=0; bad=0 }
    function Tally($s){ if ($s -and $n.ContainsKey([string]$s)) { $n[[string]$s]++ } }

    if ($d.ContainsKey("Scheme")) { Tally (Set-Row "scheme" $d.Scheme "ok") }
    if ($d.ContainsKey("Pmin")) {
        if ($null -eq $d.Pmin) { Tally (Set-Row "pmin" "读取失败" "warn") }
        elseif ($d.Pmin -ge 100) {
            # 已按目标锁定，属于预期状态；笔记本附带说明代价，但不当作问题
            if ($d.IsLaptop) { Tally (Set-Row "pmin" "100 %   已锁定不降频 · 空载温度会偏高" "ok") }
            else { Tally (Set-Row "pmin" "100 %   已锁定不降频" "ok") }
        }
        else { Tally (Set-Row "pmin" ("" + $d.Pmin + " %   空闲会降频，未锁定") "warn") }
    }
    if ($d.ContainsKey("Aspm")) {
        if ($null -eq $d.Aspm) { Tally (Set-Row "aspm" "读取失败" "warn") }
        elseif ($d.Aspm -eq 0) { Tally (Set-Row "aspm" "已关闭节能" "ok") }
        else { Tally (Set-Row "aspm" ("节能中  值 " + $d.Aspm) "warn") }
    }
    if ($d.VbsPendingOff) { Tally (Set-Row "vbs" "已设为关闭 —— 需要重启电脑才真正生效" "warn") }
    elseif ($d.Vbs) { Tally (Set-Row "vbs" "运行中   损失约 5~10% 帧" "bad") }
    else { Tally (Set-Row "vbs" "未开启" "ok") }

    if ($d.Dvr -eq 0) { Tally (Set-Row "dvr" "已关闭" "ok") }
    else { Tally (Set-Row "dvr" "开启中   会造成帧生成抖动" "warn") }

    if ($d.Hags -eq 2) { Tally (Set-Row "hags" "已开启" "ok") }
    elseif ($null -eq $d.Hags) { Tally (Set-Row "hags" "未设置" "warn") }
    else { Tally (Set-Row "hags" ("已关闭  值 " + $d.Hags) "warn") }

    if ($d.ApexCount -eq 0) { Tally (Set-Row "apex" "未找到 Apex，可手动指定目录" "warn") }
    elseif ($d.ApexDone -eq $d.ApexCount) { Tally (Set-Row "apex" ("已指定独显   " + $d.ApexCount + " 个文件") "ok") }
    elseif ($d.ApexDone -gt 0) { Tally (Set-Row "apex" ("部分已指定   " + $d.ApexDone + "/" + $d.ApexCount) "warn") }
    else { Tally (Set-Row "apex" ("未指定   检出 " + $d.ApexCount + " 个可执行文件") "warn") }

    if ($d.BgCount -eq 0) { Tally (Set-Row "bg" "无可清理项" "ok") }
    else { Tally (Set-Row "bg" ("" + $d.BgCount + " 项运行中   合计 " + $d.BgMB + " MB") "warn") }

    if ($d.HasBackup) { Tally (Set-Row "backup" "已存在   可随时还原" "ok") }
    else { Tally (Set-Row "backup" "尚未备份   首次操作时自动创建" "warn") }

    if ($d.IsLaptop) {
        if ($d.PwrSrc -eq "DC") {
            Tally (Set-Row "pwr" "电池供电   功耗墙大幅降低，帧数会明显偏低" "bad")
        } else {
            Tally (Set-Row "pwr" "已接通电源" "ok")
        }
    } else {
        Tally (Set-Row "pwr" "台式机   无供电差异" "ok")
    }
    $mi = $d.Mem
    if ($mi -and $mi.TotalMB -gt 0) {
        $txt = "" + $mi.AvailMB + " MB 可用 / 缓存 " + $mi.StandbyMB + " MB   已用 " + $mi.UsedPct + "%"
        if ($mi.UsedPct -ge 90) { Tally (Set-Row "mem" $txt "bad") }
        elseif ($mi.StandbyMB -ge 4096 -or $mi.UsedPct -ge 80) { Tally (Set-Row "mem" $txt "warn") }
        else { Tally (Set-Row "mem" $txt "ok") }
    } else { Tally (Set-Row "mem" "读取中" "warn") }

    # 任务表缺失比"优先级没提上去"严重得多：那会让整个系统放不了音视频，优先报它
    if ($d.ContainsKey("MmMiss") -and $d.MmMiss.Count -gt 0) {
        Tally (Set-Row "mmcss" ("多媒体任务配置缺失 " + $d.MmMiss.Count + " 项   全系统音视频无法播放 · 点一键优化自动修复") "bad")
    }
    elseif ($d.Mmcss) { Tally (Set-Row "mmcss" "已提升" "ok") }
    else { Tally (Set-Row "mmcss" "系统默认   游戏进程优先级偏低" "warn") }

    if ($d.Mouse) { Tally (Set-Row "mouse" "已关闭   同距离=同转角" "ok") }
    else { Tally (Set-Row "mouse" "开启中   会影响枪法一致性" "warn") }

    if ($null -eq $d.Nagle) { Tally (Set-Row "nagle" "未检出活动网卡" "warn") }
    elseif ($d.Nagle) { Tally (Set-Row "nagle" "已关闭" "ok") }
    else { Tally (Set-Row "nagle" "开启中   小包会被合并，延迟略高" "warn") }

    $vdn = 0
    if ($d.VDisp) { $vdn = @($d.VDisp).Count }
    if ($vdn -eq 0) { Tally (Set-Row "vdisp" "无" "ok") }
    else { Tally (Set-Row "vdisp" ("检出 " + $vdn + " 个   建议在设备管理器停用") "warn") }

    Set-Text $sumNum["ok"]   ([string]$n.ok)
    Set-Text $sumNum["warn"] ([string]$n.warn)
    Set-Text $sumNum["bad"]  ([string]$n.bad)

    Sync-VbsButton $d

    $g = $d.Gpu
    if ($g -and $g.Src -eq "perfcounter") {
        # 非 N 卡：Windows 计数器只有占用率，温度/功耗/频率读不到，如实说明
        Set-Text $lblGpuTxt ("" + $d.GpuName + "   ·   仅占用率可读，温度/功耗需厂商工具")
        $u = 0.0
        [double]::TryParse($g.Util,[ref]$u) | Out-Null
        $wu = [int]((S $barUtil.W) * [math]::Min($u,100) / 100)
        if ($barUtil.Fill.Width -ne $wu) { $barUtil.Fill.Width = $wu }
        Set-Text $barUtil.Val ("" + $g.Util + " %")
        if ($barTemp.Fill.Width -ne 0) { $barTemp.Fill.Width = 0 }
        Set-Text $barTemp.Val "不可用"
    } elseif ($g) {
        Set-Text $lblGpuTxt ("{0} MHz / {1}   ·   {2} W / {3} W" -f $g.Clk,$g.ClkMax,$g.Watt,$g.WattMax)
        $u = 0.0; $tp = 0.0
        [double]::TryParse($g.Util,[ref]$u) | Out-Null
        [double]::TryParse($g.Temp,[ref]$tp) | Out-Null
        $wu = [int]((S $barUtil.W) * [math]::Min($u,100) / 100)
        if ($barUtil.Fill.Width -ne $wu) { $barUtil.Fill.Width = $wu }
        Set-Text $barUtil.Val ("" + $g.Util + " %")
        $wt = [int]((S $barTemp.W) * [math]::Min($tp,100) / 100)
        if ($barTemp.Fill.Width -ne $wt) { $barTemp.Fill.Width = $wt }
        Set-Text $barTemp.Val ("" + $g.Temp + " C")
        $tc = $C_ACCENT
        if ($tp -ge 85) { $tc = $C_CRIT } elseif ($tp -ge 75) { $tc = $C_WARN }
        if ($barTemp.Fill.BackColor -ne $tc) { $barTemp.Fill.BackColor = $tc }
    } else {
        Set-Text $lblGpuTxt ("" + $d.GpuName + "   ·   读不到显卡实时数据")
        Set-Text $barUtil.Val "不可用"
        Set-Text $barTemp.Val "不可用"
    }
    if ($d.Stamp) {
        $sec = [int]((Get-Date) - $d.Stamp).TotalSeconds
        Set-Text $lblStamp ("自动刷新中 · " + $sec + " 秒前")
    }
}

# ---------- 6. 后台刷新线程 ----------
$sync = [hashtable]::Synchronized(@{})
$sync.Stop = $false
$sync.ApexDir = $APEXDIR
$sync.Data = $null
$sync.Busy = $false
$sync.ForceFull = $false

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = "MTA"
$rs.ThreadOptions = "ReuseThread"
$rs.Open()
$rs.SessionStateProxy.SetVariable("sync", $sync)
$worker = [powershell]::Create()
$worker.Runspace = $rs
$loop = @'
$i = 0     # 第一轮必须是完整采集，否则界面会拿到只有显卡数据的空壳
$prev = $null
while (-not $sync.Stop) {
    if (-not $sync.Busy) {
        try {
            # 主线程执行完操作会置位，强制这一轮做完整采集，
            # 否则轻量轮次会拿线程内缓存的旧值把刚更新的结果覆盖掉
            if ($sync.ForceFull) { $i = 0; $sync.ForceFull = $false }
            $prev = Collect-Status $sync.ApexDir $prev $i
            $sync.Data = $prev
        } catch { }
    }
    $i++
    if ($i -gt 100000) { $i = 1 }
    Start-Sleep -Milliseconds 800
}
'@
[void]$worker.AddScript($SharedFns + "`n" + $loop)
$hWorker = $worker.BeginInvoke()

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({ if ($sync.Data) { Render-Status $sync.Data } })

# 操作完成后立刻同步刷新，并让后台线程下一轮也做完整采集
function Force-Refresh {
    $sync.Data = Collect-Status $sync.ApexDir $sync.Data 0
    $sync.ForceFull = $true
    Render-Status $sync.Data
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------- 7. 备份 / 读取 ----------
function Save-Backup {
    if (Test-Path $BKFILE) { Log "备份已存在，跳过（绝不覆盖原始备份）" "dim"; return }
    if (-not (Test-Path $BKDIR)) { New-Item -ItemType Directory -Path $BKDIR -Force | Out-Null }
    $sch = Get-SchemeGuid
    if (-not $sch) { $sch = "381b4222-f694-41f0-9685-ff5bb260df2e" }
    $ultExist = 0
    if ((Get-SchemeList) -match [regex]::Escape($ULTGUID)) { $ultExist = 1 }
    $vbsNow = 0
    if (Get-VbsRunning) { $vbsNow = 1 }
    $pairs = [ordered]@{
        POWERSCHEME = $sch
        ULTEXISTED  = $ultExist
        VBSRUNNING  = $vbsNow
        HYPERVISOR  = (Get-Hypervisor)
        GAMEDVR     = (RegGet $K_GCS  "GameDVR_Enabled")
        ALLOWDVR    = (RegGet $K_POL  "AllowGameDVR")
        NEXUS       = (RegGet $K_GB   "UseNexusForGameBarEnabled")
        AUTOGAME    = (RegGet $K_GB   "AutoGameModeEnabled")
        ALLOWAUTO   = (RegGet $K_GB   "AllowAutoGameMode")
        HWSCH       = (RegGet $K_GD   "HwSchMode")
        VBS         = (RegGet $K_DG   "EnableVirtualizationBasedSecurity")
        HVCI        = (RegGet $K_HVCI "Enabled")
        CGUARD      = (RegGet $K_CG   "Enabled")
    }
    foreach ($m in (Get-MmPlan))    { $pairs[$m.K] = (RegGet $m.Path  $m.Name) }
    foreach ($m in (Get-MousePlan)) { $pairs[$m.K] = (RegGet $K_MOUSE $m.Name) }
    # 注意: PowerShell 里逗号优先级高于 +，第二项必须整体加括号，
    # 否则 @("a","b" + $x) 会被解析成 @("a","b") + $x 变成三个元素
    $lines = @("# Apex优化工具 原始状态备份", ("# 生成时间 " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")))
    foreach ($k in $pairs.Keys) {
        $v = $pairs[$k]
        if ($null -eq $v) { $v = "NOTSET" }
        $lines += ("{0}={1}" -f $k,$v)
    }
    [System.IO.File]::WriteAllLines($BKFILE, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    powercfg -export (Join-Path $BKDIR "orig_scheme.pow") $sch 2>$null | Out-Null
    Log "已备份原始状态" "ok"
}
# 工具升级会新增被修改的项。旧备份里没有这些键，如果直接还原，
# 这些项会被当成"原本不存在"而删除 —— 这是实测抓到过的真实故障。
# 所以在第一次动它们之前，必须把当前值补录进备份。
function Ensure-BackupKeys {
    if (-not (Test-Path $BKFILE)) { return 0 }
    $bk = Read-Backup
    $add = @()
    foreach ($m in (Get-MmPlan)) {
        if (-not $bk.ContainsKey($m.K)) {
            $v = RegGet $m.Path $m.Name
            if ($null -eq $v) { $v = "NOTSET" }
            $add += ($m.K + "=" + $v)
        }
    }
    foreach ($m in (Get-MousePlan)) {
        if (-not $bk.ContainsKey($m.K)) {
            $v = RegGet $K_MOUSE $m.Name
            if ($null -eq $v) { $v = "NOTSET" }
            $add += ($m.K + "=" + $v)
        }
    }
    if (-not $bk.ContainsKey("VBSRUNNING")) {
        $vn = 0
        if (Get-VbsRunning) { $vn = 1 }
        $add += ("VBSRUNNING=" + $vn)
    }
    if ($add.Count -gt 0) {
        [System.IO.File]::AppendAllLines($BKFILE, [string[]]$add, (New-Object System.Text.UTF8Encoding($false)))
        return $add.Count
    }
    return 0
}
function Read-Backup {
    $h = @{}
    if (-not (Test-Path $BKFILE)) { return $h }
    foreach ($l in ([System.IO.File]::ReadAllLines($BKFILE,[System.Text.Encoding]::UTF8))) {
        if ($l -match '^\s*#') { continue }
        $kv = $l -split '=',2
        if ($kv.Count -eq 2) { $h[$kv[0].Trim()] = $kv[1].Trim() }
    }
    return $h
}
$RESTMAP = @(
    @($K_GCS ,"GameDVR_Enabled"                  ,"GAMEDVR"  ,"Xbox 后台录制"),
    @($K_POL ,"AllowGameDVR"                     ,"ALLOWDVR" ,"GameDVR 策略"),
    @($K_GB  ,"UseNexusForGameBarEnabled"        ,"NEXUS"    ,"游戏栏 Nexus"),
    @($K_GB  ,"AutoGameModeEnabled"              ,"AUTOGAME" ,"游戏模式"),
    @($K_GB  ,"AllowAutoGameMode"                ,"ALLOWAUTO","游戏模式策略"),
    @($K_GD  ,"HwSchMode"                        ,"HWSCH"    ,"硬件加速GPU计划"),
    @($K_DG  ,"EnableVirtualizationBasedSecurity","VBS"      ,"虚拟化安全开关"),
    @($K_HVCI,"Enabled"                          ,"HVCI"     ,"内存完整性"),
    @($K_CG  ,"Enabled"                          ,"CGUARD"   ,"凭据保护")
)
function Write-BackedValue($key,$name,$val){
    if ($null -eq $val -or $val -eq "NOTSET" -or $val -eq "") {
        Remove-ItemProperty -Path $key -Name $name -Force -ErrorAction SilentlyContinue
    } else {
        Ensure-Key $key
        $iv = 0
        $vs = [string]$val
        if ($vs -match '^0[xX]([0-9a-fA-F]+)$') { $iv = [Convert]::ToInt32($matches[1],16) }
        elseif (-not [int]::TryParse($vs,[ref]$iv)) { $iv = 0 }
        Set-ItemProperty -Path $key -Name $name -Value $iv -Type DWord -Force -ErrorAction SilentlyContinue
    }
}

# ---------- 7.4 进度框 ----------
# 耗时操作必须给反馈，否则窗口不刷新会被当成卡死
$script:PROG = $null
function Start-Progress($title,$total){
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title
    $f.ClientSize = (Sz 420 116)
    $f.StartPosition = "CenterParent"
    $f.BackColor = $C_BG; $f.ForeColor = $C_TEXT; $f.Font = $F_UI
    $f.FormBorderStyle = "FixedDialog"
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ControlBox = $false
    try { if ($form.Icon) { $f.Icon = $form.Icon } } catch { }
    $lbl = New-Label "准备中..." $F_UI $C_TEXT 20 18 380 22 $f
    $sub = New-Label "" $F_MSM $C_FAINT 20 44 380 18 $f
    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Location = (Pt 20 72); $pb.Size = (Sz 380 14)
    $pb.Maximum = [math]::Max($total,1); $pb.Style = "Continuous"
    $f.Controls.Add($pb)
    $form.Enabled = $false
    $f.Show($form)
    $script:PROG = @{ Form=$f; Label=$lbl; Sub=$sub; Bar=$pb; Step=0; Total=$total }
    [System.Windows.Forms.Application]::DoEvents()
}
function Step-Progress($text){
    if (-not $script:PROG) { return }
    $script:PROG.Step++
    $script:PROG.Label.Text = $text
    $script:PROG.Sub.Text = "第 " + $script:PROG.Step + " / " + $script:PROG.Total + " 步"
    $script:PROG.Bar.Value = [math]::Min($script:PROG.Step, $script:PROG.Bar.Maximum)
    [System.Windows.Forms.Application]::DoEvents()
}
function Stop-Progress {
    if (-not $script:PROG) { return }
    try { $script:PROG.Form.Close(); $script:PROG.Form.Dispose() } catch { }
    $script:PROG = $null
    $form.Enabled = $true
    $form.Activate()
    [System.Windows.Forms.Application]::DoEvents()
}

# ---------- 7.5 结果确认窗口 ----------
function Show-Result($title,$headline,$state,$rows,$note){
    $shown = [math]::Min($rows.Count,13)
    $listTop = 66
    $listH = $shown*24 + 12
    $noteY = $listTop + $listH + 14
    $noteH = 0
    if ($note) { $noteH = 40 }
    $btnY = $noteY + $noteH + 10
    $H = $btnY + 36 + 16

    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title
    $d.ClientSize = (Sz 572 $H)
    $d.StartPosition = "CenterParent"
    $d.BackColor = $C_BG; $d.ForeColor = $C_TEXT; $d.Font = $F_UI
    $d.FormBorderStyle = "FixedDialog"; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    try { if ($form.Icon) { $d.Icon = $form.Icon } } catch { }

    $hc = $C_OK
    if ($state -eq "warn") { $hc = $C_WARN }
    if ($state -eq "bad")  { $hc = $C_CRIT }
    New-Label $headline $F_H1 $hc 24 18 516 34 $d | Out-Null

    $list = New-Object System.Windows.Forms.Panel
    $list.Location = (Pt 24 $listTop); $list.Size = (Sz 524 $listH)
    $list.BackColor = $C_CARD; $list.AutoScroll = $true
    $d.Controls.Add($list)
    $y = 6
    foreach ($r in $rows) {
        $c = $C_OK
        if ($r.State -eq "warn") { $c = $C_WARN }
        if ($r.State -eq "bad")  { $c = $C_CRIT }
        if ($r.State -eq "dim")  { $c = $C_FAINT }
        New-Label ([string][char]0x25CF) $F_DOT $c 8 ($y-3) 16 20 $list | Out-Null
        New-Label ([string]$r.Item) $F_UI $C_TEXT 28 $y 186 20 $list | Out-Null
        New-Label ([string]$r.Detail) $F_MSM $C_DIM 218 ($y+2) 284 18 $list | Out-Null
        $y += 24
    }
    if ($note) { New-Label $note $F_SM $C_WARN 24 $noteY 524 38 $d | Out-Null }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "知道了"; $ok.Font = $F_BTN
    $ok.Size = (Sz 112 36); $ok.Location = (Pt 436 $btnY)
    $ok.FlatStyle = "Flat"; $ok.BackColor = $C_ACCENT; $ok.ForeColor = $C_BG
    $ok.FlatAppearance.BorderSize = 0
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $d.Controls.Add($ok); $d.AcceptButton = $ok
    [void]$d.ShowDialog($form)
}

# 还原后逐条重读当前值，与备份比对
function Verify-Restore($bk){
    $rows = @()
    $cur = [string](Get-SchemeGuid)
    $want = [string]$bk["POWERSCHEME"]
    if ($cur -eq $want) { $rows += @{Item="电源方案"; State="ok"; Detail=("已切回 " + (Get-SchemeName))} }
    else { $rows += @{Item="电源方案"; State="bad"; Detail="未切回备份记录的方案"} }

    Step-Progress "正在写回注册表原值..."
    foreach ($m in $RESTMAP) {
        if (-not $bk.ContainsKey($m[2])) { $rows += @{Item=$m[3]; State="dim"; Detail="备份未记录，未改动"}; continue }
        $now = RegGet $m[0] $m[1]
        $nowS = "NOTSET"
        if ($null -ne $now) { $nowS = [string]$now }
        $wantS = [string]$bk[$m[2]]
        if ([string]::IsNullOrEmpty($wantS)) { $wantS = "NOTSET" }
        if ($nowS -eq $wantS) { $rows += @{Item=$m[3]; State="ok"; Detail=("= " + $nowS)} }
        else { $rows += @{Item=$m[3]; State="bad"; Detail=("现在 " + $nowS + "  应为 " + $wantS)} }
    }

    foreach ($m in (Get-MmPlan)) {
        if (-not $bk.ContainsKey($m.K)) { $rows += @{Item=$m.N; State="dim"; Detail="备份未记录，未改动"}; continue }
        $now = RegGet $m.Path $m.Name
        $nowS = "NOTSET"; if ($null -ne $now) { $nowS = [string]$now }
        $wantS = [string]$bk[$m.K]; if ([string]::IsNullOrEmpty($wantS)) { $wantS = "NOTSET" }
        if ($nowS -eq $wantS) { $rows += @{Item=$m.N; State="ok"; Detail=("= " + $nowS)} }
        else { $rows += @{Item=$m.N; State="bad"; Detail=("现在 " + $nowS + "  应为 " + $wantS)} }
    }
    $hv = Get-Hypervisor
    $hvW = [string]$bk["HYPERVISOR"]
    if ([string]::IsNullOrEmpty($hvW)) { $hvW = "NOTSET" }
    if ($hv -eq $hvW) { $rows += @{Item="Hyper-V 启动类型"; State="ok"; Detail=("= " + $hv)} }
    else { $rows += @{Item="Hyper-V 启动类型"; State="bad"; Detail=("现在 " + $hv + "  应为 " + $hvW)} }

    $left = 0
    foreach ($nm in $APEXNAMES) {
        if ($sync.ApexDir -and (RegHas $K_GPU (Join-Path $sync.ApexDir $nm))) { $left++ }
    }
    if ($left -eq 0) { $rows += @{Item="Apex 显卡首选项"; State="ok"; Detail="已清除"} }
    else { $rows += @{Item="Apex 显卡首选项"; State="bad"; Detail=("仍残留 " + $left + " 条")} }

    foreach ($m in (Get-MousePlan)) {
        if (-not $bk.ContainsKey($m.K)) { $rows += @{Item=("鼠标"+$m.N); State="dim"; Detail="备份未记录，未改动"}; continue }
        $now = RegGet $K_MOUSE $m.Name
        $nowS = "NOTSET"; if ($null -ne $now) { $nowS = [string]$now }
        $wantS = [string]$bk[$m.K]; if ([string]::IsNullOrEmpty($wantS)) { $wantS = "NOTSET" }
        if ($nowS -eq $wantS) { $rows += @{Item=("鼠标"+$m.N); State="ok"; Detail=("= " + $nowS)} }
        else { $rows += @{Item=("鼠标"+$m.N); State="bad"; Detail=("现在 " + $nowS + "  应为 " + $wantS)} }
    }
    if ($bk.ContainsKey("NAGLE_IFS") -and $bk["NAGLE_IFS"]) {
        $left = 0
        foreach ($g in ($bk["NAGLE_IFS"] -split ',')) {
            if (-not $g) { continue }
            $ip = Join-Path $K_TCPIF $g.Trim()
            if ($null -ne (RegGet $ip "TcpAckFrequency") -or $null -ne (RegGet $ip "TCPNoDelay")) { $left++ }
        }
        if ($left -eq 0) { $rows += @{Item="网络小包设置"; State="ok"; Detail="已还原"} }
        else { $rows += @{Item="网络小包设置"; State="bad"; Detail=("仍残留 " + $left + " 个网卡")} }
    }
    if (Test-Path $OURFILE) { $rows += @{Item="本工具建的电源方案"; State="warn"; Detail="记录仍在，可能未删净"} }
    else { $rows += @{Item="本工具建的电源方案"; State="ok"; Detail="已删除"} }
    return $rows
}

# ---------- 8. 动作 ----------
function Do-Optimize {
    $sync.Busy = $true
    Start-Progress "一键优化" 8
    Step-Progress "正在备份原始状态..."
    Log "开始一键优化" "ok"
    Save-Backup
    $addN = Ensure-BackupKeys
    if ($addN -gt 0) { Log ("备份补录了 " + $addN + " 个此前版本未记录的项") "ok" }

    $mine = $null
    if (Test-Path $OURFILE) {
        $prevG = (Get-Content -LiteralPath $OURFILE -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($prevG -and ((Get-SchemeList) -match [regex]::Escape($prevG))) { $mine = $prevG }
    }
    if (-not $mine) {
        Step-Progress "正在确认卓越性能模板可用..."
        $tplState = Ensure-UltimateTemplate
        if ($tplState -eq "rebuilt") { Log "系统缺少卓越性能模板，已重建" "warn" }
        elseif ($tplState -eq "failed") { Log "卓越性能模板不可用，将以高性能为基础显式配置" "warn" }
        else { Log "卓越性能模板可用" "ok" }
        foreach ($base in @($ULTGUID, $HIGHGUID)) {
            $outp = (powercfg -duplicatescheme $base 2>$null) -join " "
            $m = [regex]::Match($outp,'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
            if ($m.Success) { $mine = $m.Value; break }
        }
        if ($mine) {
            powercfg -changename $mine "Apex 优化方案 (本工具创建, 可安全删除)" 2>$null | Out-Null
            if (-not (Test-Path $BKDIR)) { New-Item -ItemType Directory -Path $BKDIR -Force | Out-Null }
            Set-Content -LiteralPath $OURFILE -Value $mine
        }
    }
    Step-Progress "正在创建专属电源方案..."
    $powerOk = $false; $powerWhere = ""; $reverted = $false; $powerRows = @()
    if ($mine) {
        $powerRows = Apply-PowerPlan $mine

        Step-Progress "正在确认电源设置是否被覆盖（约 1 秒）..."
        # 厂商控制中心常会把电源方案切回它自己的，等一下看方案还在不在
        Start-Sleep -Milliseconds 1200
        $act = Get-SchemeGuid
        if ($act -ne $mine) {
            $reverted = $true
            Log "方案被切回了（多半是厂商控制中心），改为写入当前生效的方案" "warn"
            # 改动用户自有方案前，先把它这几项的原值补进备份，保证能还原
            $bkNow = Read-Backup
            if (-not $bkNow.ContainsKey("ORIG_PMIN")) {
                $orig = Read-PowerPlan $act
                $extra = @("ORIGTARGET=" + $act)
                foreach ($k in ($orig.Keys | Sort-Object)) { $extra += ($k + "=" + $orig[$k]) }
                [System.IO.File]::AppendAllLines($BKFILE, [string[]]$extra, (New-Object System.Text.UTF8Encoding($false)))
                Log "已把该方案的原值补录进备份" "ok"
            }
            $powerRows = Apply-PowerPlan $act
        }
        $powerWhere = Get-SchemeName
        $badRows = @($powerRows | Where-Object { $_.State -eq "bad" })
        $skipRows = @($powerRows | Where-Object { $_.State -eq "skip" })
        $powerOk = ($badRows.Count -eq 0)
        foreach ($r in $powerRows) {
            if ($r.State -eq "ok") { Log ($r.N + "  " + $r.Detail) "ok" }
            elseif ($r.State -eq "skip") { Log ($r.N + "  " + $r.Detail) "dim" }
            else { Log ($r.N + "  " + $r.Detail) "err" }
        }
        if ($skipRows.Count -gt 0) { Log ("有 " + $skipRows.Count + " 个电源项本机不存在，已跳过") "dim" }
        if ($powerOk) { Log ("电源项已生效于「" + $powerWhere + "」") "ok" }
    } else {
        Log "无法创建电源方案，已跳过电源相关优化" "err"
    }

    Ensure-Key $K_POL
    Ensure-Key $K_GB
    Step-Progress "正在关闭后台录制、开启游戏模式..."
    Set-ItemProperty -Path $K_GCS -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $K_POL -Name "AllowGameDVR" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $K_GB  -Name "UseNexusForGameBarEnabled" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $K_GB  -Name "AutoGameModeEnabled" -Value 1 -Type DWord -Force
    Set-ItemProperty -Path $K_GB  -Name "AllowAutoGameMode" -Value 1 -Type DWord -Force
    Log "已关闭 Xbox 后台录制，开启游戏模式" "ok"

    Set-ItemProperty -Path $K_GD -Name "HwSchMode" -Value 2 -Type DWord -Force
    Log "已开启硬件加速 GPU 计划（需重启）" "ok"

    Step-Progress "正在提升游戏进程优先级优先级..."
    # 游戏进程优先级 MMCSS
    $mmRows = @()
    # 先保证任务表完整再写 Games。缺任务名会让全系统音视频都放不了，
    # 严重程度远高于这里要调的游戏优先级，所以放在最前面
    $mmFixed = @(Repair-MmTasks)
    if ($mmFixed.Count -gt 0) {
        $mmRows += @{N="多媒体任务配置"; State="ok"; Detail=("已修复 " + $mmFixed.Count + " 项: " + ($mmFixed -join ", "))}
        Log ("检出并修复了缺失的多媒体任务配置 " + $mmFixed.Count + " 项，音视频播放已恢复") "ok"
    }
    Ensure-Key $K_MMG
    foreach ($m in (Get-MmPlan)) {
        try {
            Set-ItemProperty -Path $m.Path -Name $m.Name -Value $m.V -Type $m.T -Force -ErrorAction Stop
            $cur = RegGet $m.Path $m.Name
            if ("$cur" -eq "$($m.V)") { $mmRows += @{N=$m.N; State="ok"; Detail="= $cur"} }
            else { $mmRows += @{N=$m.N; State="bad"; Detail="回读为 $cur"} }
        } catch { $mmRows += @{N=$m.N; State="bad"; Detail="写入被拒"} }
    }
    if (@($mmRows | Where-Object { $_.State -eq "bad" }).Count -eq 0) { Log "游戏进程优先级已提升(MMCSS)" "ok" }
    else { Log "游戏进程优先级有项未写入" "warn" }

    Step-Progress "正在关闭鼠标指针加速..."
    # 关闭鼠标指针加速
    $msOk = $true
    foreach ($m in (Get-MousePlan)) {
        try { Set-ItemProperty -Path $K_MOUSE -Name $m.Name -Value $m.V -Type String -Force -ErrorAction Stop } catch { $msOk = $false }
    }
    # 关键：还要通过系统 API 落实，否则 Windows 可能用内存里的旧值把注册表盖回去
    try { if (-not [MouseNative]::SetMouse(0,0,0)) { $msOk = $false } } catch { $msOk = $false }
    $msLive = $null
    try { $msLive = [MouseNative]::GetMouse() } catch { }
    if ($msLive -and ($msLive[0] -ne 0 -or $msLive[1] -ne 0 -or $msLive[2] -ne 0)) { $msOk = $false }
    if ($msOk) { Log "已关闭鼠标指针加速并经系统 API 确认" "ok" } else { Log "鼠标加速关闭失败或未生效" "warn" }

    Step-Progress "正在优化网络延迟设置..."
    # 关闭小包合并（只在原本没设过的接口上动，还原时直接删除）
    $nagleIfs = @()
    foreach ($g in (Get-ActiveNetIfs)) {
        $ipath = Join-Path $K_TCPIF $g
        if (-not (Test-Path $ipath)) { continue }
        if ((RegGet $ipath "TcpAckFrequency") -ne $null -or (RegGet $ipath "TCPNoDelay") -ne $null) { continue }
        try {
            Set-ItemProperty -Path $ipath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction Stop
            Set-ItemProperty -Path $ipath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction Stop
            $nagleIfs += $g
        } catch { }
    }
    if ($nagleIfs.Count -gt 0) {
        $bkNow2 = Read-Backup
        if (-not $bkNow2.ContainsKey("NAGLE_IFS")) {
            [System.IO.File]::AppendAllLines($BKFILE, [string[]]@("NAGLE_IFS=" + ($nagleIfs -join ",")), (New-Object System.Text.UTF8Encoding($false)))
        }
        Log ("已关闭小包合并，共 " + $nagleIfs.Count + " 个网卡（降网络延迟，不影响帧数）") "ok"
    }

    Ensure-Key $K_GPU
    $exes = Get-ApexExes $sync.ApexDir
    foreach ($e in $exes) {
        Set-ItemProperty -Path $K_GPU -Name $e -Value "GpuPreference=2;AutoHDREnable=0;" -Type String -Force
        Log ("已为 " + (Split-Path $e -Leaf) + " 指定独显") "ok"
    }
    Step-Progress "正在复查各项是否真的生效..."
    $sync.Busy = $false
    Force-Refresh
    Stop-Progress

    $d = $sync.Data
    $res = @()
    if ($mine) { $res += @{Item="专属电源方案"; State="ok"; Detail=(Get-SchemeName)} }
    else { $res += @{Item="专属电源方案"; State="bad"; Detail="创建失败，电源项已跳过"} }
    # 电源项逐条列出，本机不支持的标灰而不算失败
    foreach ($r in $powerRows) {
        $st = $r.State
        if ($st -eq "skip") { $st = "dim" }
        $res += @{Item=$r.N; State=$st; Detail=$r.Detail}
    }
    if ($reverted) {
        $res += @{Item="电源方案归属"; State="warn"; Detail=("被切回，已写入「" + $powerWhere + "」")}
    } elseif ($powerWhere) {
        $res += @{Item="电源方案归属"; State="ok"; Detail=$powerWhere}
    }
    if ($d.Dvr -eq 0) { $res += @{Item="Xbox 后台录制"; State="ok"; Detail="已关闭"} }
    else { $res += @{Item="Xbox 后台录制"; State="warn"; Detail="仍为开启"} }
    if ($d.Hags -eq 2) { $res += @{Item="硬件加速 GPU 计划"; State="ok"; Detail="已开启，重启后生效"} }
    else { $res += @{Item="硬件加速 GPU 计划"; State="warn"; Detail="写入未生效"} }
    if ($d.ApexCount -eq 0) { $res += @{Item="Apex 独显指定"; State="warn"; Detail="未找到 Apex，已跳过"} }
    elseif ($d.ApexDone -eq $d.ApexCount) { $res += @{Item="Apex 独显指定"; State="ok"; Detail=("" + $d.ApexCount + " 个文件已设置")} }
    else { $res += @{Item="Apex 独显指定"; State="warn"; Detail=("仅 " + $d.ApexDone + "/" + $d.ApexCount)} }
    foreach ($r in $mmRows) { $res += @{Item=$r.N; State=$r.State; Detail=$r.Detail} }
    $msShow = "已关闭"
    if ($msLive) { $msShow = "系统实际生效值 " + ($msLive -join ",") }
    if ($msOk) { $res += @{Item="鼠标指针加速"; State="ok"; Detail=$msShow} }
    else { $res += @{Item="鼠标指针加速"; State="bad"; Detail=("未生效  " + $msShow)} }
    if ($nagleIfs.Count -gt 0) { $res += @{Item="网络小包合并"; State="ok"; Detail=("已关闭 " + $nagleIfs.Count + " 个网卡")} }
    $vd = @(Get-VirtualDisplays)
    if ($vd.Count -gt 0) { $res += @{Item="虚拟显示器"; State="warn"; Detail=("检出 " + $vd.Count + " 个，建议在设备管理器停用")} }
    $res += @{Item="原始状态备份"; State="ok"; Detail="已保存，可随时还原"}

    $bad = @($res | Where-Object { $_.State -eq "bad" }).Count
    $wrn = @($res | Where-Object { $_.State -eq "warn" }).Count
    $st = "ok"; $hl = "优化完成"
    if ($wrn -gt 0) { $st = "warn"; $hl = "优化完成，有 $wrn 项需留意" }
    if ($bad -gt 0) { $st = "bad";  $hl = "优化未完全成功" }
    $optNote = "部分项需重启后生效。"
    if ($d.IsLaptop) {
        $optNote += "笔记本要点: 独显直连(MUX) + 厂商性能模式 的影响比本工具所有优化加起来都大。"
        if ($d.PwrSrc -eq "DC") {
            $res += @{Item="供电方式"; State="bad"; Detail="当前电池供电"}
            $optNote = "【当前是电池供电】笔记本用电池时 CPU 和显卡的功耗墙会大幅降低，" +
                       "帧数可能比插电低 30% 以上，本次优化的效果会被这一条吃掉大半。请插上电源再打游戏。  " + $optNote
        }
    } else {
        $optNote += "仍需手动: 杀软排除 · 显卡控制面板单独设置 Apex。"
    }
    Show-Result "一键优化" $hl $st $res $optNote
}

# BitLocker / 设备加密 预检。
# 本工具唯一可能让人开不了机的一步就是 bcdedit：它改的是启动配置，
# 而启动配置受 TPM 度量保护，开了设备加密的机器下次开机可能索要 48 位恢复密钥。
# 微软账户登录的 OEM 笔记本默认就开着设备加密，用户自己往往不知道。
# 拿不出密钥 = 系统进不去，所以这一项必须在确认框里单独、显著地警告。
function Get-BitLockerOn {
    $r = @{ On = $false; Vols = @(); Known = $true }
    try {
        $vs = Get-CimInstance -Namespace "root\CIMV2\Security\MicrosoftVolumeEncryption" `
              -ClassName Win32_EncryptableVolume -ErrorAction Stop
        foreach ($v in $vs) {
            # ProtectionStatus: 0=关闭 1=开启 2=未知
            if ($v.ProtectionStatus -eq 1) {
                $r.On = $true
                $dl = $v.DriveLetter
                if ([string]::IsNullOrEmpty($dl)) { $dl = "(无盘符卷)" }
                $r.Vols += $dl
            }
        }
    } catch { $r.Known = $false }
    return $r
}
function Do-VbsOff {
    $extra = ""
    # 检测真正会受影响、且大众用户常装的软件
    $hit = @()
    foreach ($e in @(
        @{N="MuMu 模拟器";  P=@("MuMuPlayer","MuMuVMMHeadless","NemuPlayer")},
        @{N="雷电模拟器";    P=@("dnplayer","LdVBoxHeadless","dnmultiplayer")},
        @{N="夜神模拟器";    P=@("Nox","NoxVMHandle")},
        @{N="BlueStacks";  P=@("HD-Player","BstkSVC")},
        @{N="逍遥模拟器";    P=@("MEmu","MEmuHeadless")},
        @{N="VMware";      P=@("vmware","vmware-vmx")},
        @{N="VirtualBox";  P=@("VirtualBox","VBoxSVC")}
    )) {
        foreach ($pn in $e.P) {
            if (Get-Process -Name $pn -ErrorAction SilentlyContinue) { $hit += $e.N; break }
        }
    }
    foreach ($h in ($hit | Select-Object -Unique)) { $extra += ("`n  · 检测到 " + $h + " 正在运行，关闭后将无法使用") }
    # 开了设备加密的机器，风险等级和"模拟器用不了"完全不是一回事，单独拎出来放最前面
    $bl = Get-BitLockerOn
    $blWarn = ""
    $defBtn = [System.Windows.Forms.MessageBoxDefaultButton]::Button1
    if ($bl.On) {
        $blWarn = "`n`n[!] 重要 —— 检测到设备加密(BitLocker)已开启: " + (($bl.Vols | Sort-Object -Unique) -join " ") +
                  "`n本操作会修改启动配置，下次开机可能要求输入 48 位恢复密钥。`n" +
                  "拿不出密钥就进不了系统。请先确认能取到密钥再继续:`n" +
                  "  · 微软账户: https://aka.ms/myrecoverykey`n" +
                  "  · 或管理员命令行: manage-bde -protectors -get C:`n" +
                  "如果不确定，就别关这一项 —— 只值 5~10% 帧数，不值得冒开不了机的风险。"
        $defBtn = [System.Windows.Forms.MessageBoxDefaultButton]::Button2
    } elseif (-not $bl.Known) {
        $blWarn = "`n`n提示: 无法确定设备加密状态。若系统盘开了 BitLocker，`n" +
                  "本操作可能导致下次开机索要恢复密钥，建议先到 https://aka.ms/myrecoverykey 备份密钥。"
    }
    $msg = "关闭虚拟化安全可提升约 5~10% 帧数。`n`n代价：`n  · 安卓模拟器、虚拟机这类软件将无法运行`n  · 系统安全性略微降低" + $extra + $blWarn + "`n`n不玩模拟器的话，这项基本没有副作用。`n随时可以用同一个按钮还原。`n`n确定要关闭吗？"
    $r = [System.Windows.Forms.MessageBox]::Show($msg,"关闭虚拟化安全",
         [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning,$defBtn)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { Log "已取消" "dim"; return }
    $sync.Busy = $true
    Start-Progress "关闭虚拟化安全" 3
    Step-Progress "正在备份原始状态..."
    Save-Backup
    [void](Ensure-BackupKeys)
    Step-Progress "正在写入虚拟化设置..."
    Ensure-Key $K_HVCI
    Ensure-Key $K_CG
    Set-ItemProperty -Path $K_DG   -Name "EnableVirtualizationBasedSecurity" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $K_HVCI -Name "Enabled" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path $K_CG   -Name "Enabled" -Value 0 -Type DWord -Force
    bcdedit /set hypervisorlaunchtype off | Out-Null
    if (-not (Test-Path $BKDIR)) { New-Item -ItemType Directory -Path $BKDIR -Force | Out-Null }
    Set-Content -LiteralPath $VBSFILE -Value (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Log "虚拟化安全已设为关闭，重启后生效" "warn"
    Step-Progress "正在复查..."
    $sync.Busy = $false
    Force-Refresh
    Stop-Progress

    $res = @()
    $res += @{Item="EnableVirtualizationBasedSecurity"; State="ok"; Detail=("= " + (RegGet $K_DG "EnableVirtualizationBasedSecurity"))}
    $res += @{Item="内存完整性 HVCI"; State="ok"; Detail=("= " + (RegGet $K_HVCI "Enabled"))}
    $res += @{Item="凭据保护"; State="ok"; Detail=("= " + (RegGet $K_CG "Enabled"))}
    $res += @{Item="虚拟化启动项"; State="ok"; Detail=("= " + (Get-Hypervisor))}
    $res += @{Item="原值备份"; State="ok"; Detail="已保存，按钮已变为还原"}
    Show-Result "关闭虚拟化安全" "设置已写入，但还没生效 —— 必须重启电脑" "warn" $res "必须重启电脑才真正生效。重启后安卓模拟器、虚拟机将无法运行；想恢复，再点一次同一个按钮即可。"
}

function Do-VbsRestore {
    $bk = Read-Backup
    if ($bk.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "备份文件已丢失，无法确定 VBS 的原始值。`n`n$BKFILE`n`n可以在 Windows 安全中心 -> 设备安全性 -> 内核隔离 里手动打开内存完整性，`n或在管理员命令行执行:`n  bcdedit /set hypervisorlaunchtype auto",
            "找不到备份",[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        Log "备份丢失，无法还原 VBS" "err"
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("将把 VBS 相关设置写回原始值，安卓模拟器和虚拟机会恢复可用。`n`n需要重启电脑才生效。`n确定还原吗？","还原虚拟化安全",
         [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { Log "已取消" "dim"; return }
    $sync.Busy = $true
    Write-BackedValue $K_DG   "EnableVirtualizationBasedSecurity" $bk["VBS"]
    Write-BackedValue $K_HVCI "Enabled" $bk["HVCI"]
    Write-BackedValue $K_CG   "Enabled" $bk["CGUARD"]
    $hv = [string]$bk["HYPERVISOR"]
    if ([string]::IsNullOrEmpty($hv) -or $hv -eq "NOTSET") {
        bcdedit /deletevalue hypervisorlaunchtype 2>$null | Out-Null
    } else {
        bcdedit /set hypervisorlaunchtype $hv 2>$null | Out-Null
    }
    Step-Progress "正在还原网络与虚拟化设置..."
    if (Test-Path $VBSFILE) { [System.IO.File]::Delete($VBSFILE) }
    Log "虚拟化安全已还原为原始设置，重启后生效" "ok"
    $sync.Busy = $false
    Force-Refresh

    $res = @()
    foreach ($m in @($RESTMAP[6],$RESTMAP[7],$RESTMAP[8])) {
        $now = RegGet $m[0] $m[1]
        $nowS = "NOTSET"; if ($null -ne $now) { $nowS = [string]$now }
        $wantS = [string]$bk[$m[2]]; if ([string]::IsNullOrEmpty($wantS)) { $wantS = "NOTSET" }
        if ($nowS -eq $wantS) { $res += @{Item=$m[3]; State="ok"; Detail=("= " + $nowS)} }
        else { $res += @{Item=$m[3]; State="bad"; Detail=("现在 " + $nowS + "  应为 " + $wantS)} }
    }
    $nowHv = Get-Hypervisor
    $wantHv = [string]$bk["HYPERVISOR"]; if ([string]::IsNullOrEmpty($wantHv)) { $wantHv = "NOTSET" }
    if ($nowHv -eq $wantHv) { $res += @{Item="Hyper-V 启动类型"; State="ok"; Detail=("= " + $nowHv)} }
    else { $res += @{Item="Hyper-V 启动类型"; State="bad"; Detail=("现在 " + $nowHv + "  应为 " + $wantHv)} }

    $bad = @($res | Where-Object { $_.State -eq "bad" }).Count
    $st = "ok"; $hl = "虚拟化安全已还原 —— 必须重启电脑才生效"
    if ($bad -gt 0) { $st = "bad"; $hl = "VBS 还原后有 $bad 项不一致" }
    Show-Result "还原虚拟化安全" $hl $st $res "需要重启电脑才真正生效。重启后安卓模拟器、虚拟机恢复可用。"
}

function Do-CleanCore {
    Step-Progress "正在扫描后台程序..."
    $found = Get-BgProcs
    if ($found.Count -eq 0) { Stop-Progress; return @() }
    Stop-Progress
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "开黑前清理后台"
    $dlg.ClientSize = (Sz 460 440)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = $C_BG; $dlg.ForeColor = $C_TEXT; $dlg.Font = $F_UI
    $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    try { if ($form.Icon) { $dlg.Icon = $form.Icon } } catch { }
    New-Label "勾选要结束的程序（不卸载，下次开机照常）" $F_UI $C_TEXT 16 14 420 20 $dlg | Out-Null
    New-Label "先请程序自己正常退出，3 秒不响应才强制结束。浏览器/聊天/云盘默认不勾选。" $F_SM $C_FAINT 16 34 430 32 $dlg | Out-Null
    New-Label ("已保护: Discord · OOPZ · YY · KOOK · TeamSpeak · Mumble · 腾讯会议 · Zoom · OBS 等") $F_SM $C_OK 16 52 430 16 $dlg | Out-Null
    $clb = New-Object System.Windows.Forms.CheckedListBox
    $clb.Location = (Pt 16 70); $clb.Size = (Sz 428 300)
    $clb.BackColor = $C_CARD; $clb.ForeColor = $C_TEXT
    $clb.Font = $F_MSM; $clb.BorderStyle = "None"; $clb.CheckOnClick = $true
    $clb.IntegralHeight = $false
    $dlg.Controls.Add($clb)
    $sorted = @($found | Sort-Object -Property @{Expression={$_.MB}} -Descending)
    foreach ($f in $sorted) {
        $tag = ""
        if ($SOFTCTRL.ContainsKey($f.Name)) { $tag = "  [暂停而非关闭]" }
        [void]$clb.Items.Add(("[{0}] {1}   x{2}   {3} MB{4}" -f $f.Cat,$f.Name,$f.Count,$f.MB,$tag), ($f.Risky -eq 0))
    }
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "结束勾选项"; $ok.Font = $F_BTN
    $ok.Location = (Pt 256 384); $ok.Size = (Sz 120 36)
    $ok.FlatStyle = "Flat"; $ok.BackColor = $C_ACCENT; $ok.ForeColor = $C_BG
    $ok.FlatAppearance.BorderSize = 0
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($ok)
    $ca = New-Object System.Windows.Forms.Button
    $ca.Text = "取消"; $ca.Font = $F_BTN
    $ca.Location = (Pt 384 384); $ca.Size = (Sz 60 36)
    $ca.FlatStyle = "Flat"; $ca.BackColor = $C_CARD2; $ca.ForeColor = $C_TEXT
    $ca.FlatAppearance.BorderColor = $C_LINE
    $ca.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($ca)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $ca
    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { Log "后台清理已取消（内存整理已完成）" "dim"; return $null }

    $res = @(); $freed = 0
    $checked = @()
    for ($i=0; $i -lt $clb.Items.Count; $i++) { if ($clb.GetItemChecked($i)) { $checked += $sorted[$i] } }
    if ($checked.Count -gt 0) { Start-Progress "正在关闭后台程序" $checked.Count }
    foreach ($it in $checked) {
        $nm = $it.Name
        Step-Progress ("正在关闭 " + $nm + " ...")
        $how = Close-AppNicely $nm 3000
        switch ($how) {
            "pause" {
                $res += @{Item=$nm; State="ok"; Detail="已暂停（未关闭，不会报异常退出）"}
                Log ($nm + " 已通过官方接口暂停") "ok"
            }
            "graceful" {
                $res += @{Item=$nm; State="ok"; Detail=("正常退出  释放 " + $it.MB + " MB")}
                $freed += $it.MB
                Log ($nm + " 已正常退出") "ok"
            }
            "forced" {
                $res += @{Item=$nm; State="warn"; Detail=("未响应，已强制结束  释放 " + $it.MB + " MB")}
                $freed += $it.MB
                Log ($nm + " 无响应，已强制结束") "warn"
            }
            "gone" { $res += @{Item=$nm; State="dim"; Detail="已经不在运行"} }
            default {
                $res += @{Item=$nm; State="bad"; Detail="关闭失败，进程仍存活"}
                Log ($nm + " 关闭失败") "err"
            }
        }
    }
    if ($checked.Count -gt 0) { Stop-Progress }
    if ($res.Count -eq 0) { return @(@{Item="后台进程"; State="dim"; Detail="未勾选任何项"}) }
    $res += @{Item="合计释放"; State="ok"; Detail=("约 " + $freed + " MB")}
    return $res
}

function Do-Restore {
    if (-not (Test-Path $BKFILE)) {
        [System.Windows.Forms.MessageBox]::Show("找不到备份文件：`n$BKFILE`n`n还没运行过优化，没有可还原的内容。","无备份",
            [System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $bk = Read-Backup
    $pv = ($bk.GetEnumerator() | Sort-Object Name | ForEach-Object { "  " + $_.Key + " = " + $_.Value }) -join "`n"
    $r = [System.Windows.Forms.MessageBox]::Show("将把下列原始值逐条写回，包括虚拟化安全。`nNOTSET 表示该项原本不存在，会被删除。`n`n$pv`n`n完成后会自动校验并给出结果。确定还原吗？","还原全部设置",
         [System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { Log "已取消" "dim"; return }

    $sync.Busy = $true
    Start-Progress "还原全部设置" 5
    Step-Progress "正在切回原电源方案..."
    Log "开始还原" "ok"
    if ($bk["POWERSCHEME"]) {
        powercfg -setactive $bk["POWERSCHEME"] 2>$null | Out-Null
        if ((Get-SchemeGuid) -ne $bk["POWERSCHEME"]) {
            $pow = Join-Path $BKDIR "orig_scheme.pow"
            if (Test-Path $pow) {
                powercfg -import $pow $bk["POWERSCHEME"] 2>$null | Out-Null
                powercfg -setactive $bk["POWERSCHEME"] 2>$null | Out-Null
            }
        }
        Log ("已切回原电源方案: " + (Get-SchemeName)) "ok"
    }
    # 如果当初被厂商切回去、设置写进了用户自有方案，把那几项也还原
    if ($bk.ContainsKey("ORIGTARGET") -and $bk["ORIGTARGET"]) {
        $tgt = $bk["ORIGTARGET"]
        foreach ($p in (Get-PowerPlan)) {
            $ov = [string]$bk["ORIG_" + $p.K]
            if ([string]::IsNullOrEmpty($ov) -or $ov -eq "NOTSET") { continue }
            $iv = 0
            if ([int]::TryParse($ov,[ref]$iv)) { Set-PowerAcRaw $tgt $p.Sub $p.Set $iv }
        }
        powercfg -setactive $tgt 2>$null | Out-Null
        Log "已把写进你自有方案的电源项还原回原值" "ok"
    }
    $mine = $null
    if (Test-Path $OURFILE) { $mine = (Get-Content -LiteralPath $OURFILE -ErrorAction SilentlyContinue | Select-Object -First 1) }
    if ($mine) {
        if ((Get-SchemeGuid) -eq $mine) { powercfg -setactive $bk["POWERSCHEME"] 2>$null | Out-Null }
        powercfg -delete $mine 2>$null | Out-Null
        [System.IO.File]::Delete($OURFILE)
        Log "已删除本工具创建的专属电源方案" "ok"
    }
    Step-Progress "正在写回注册表原值..."
    foreach ($m in $RESTMAP) {
        if (-not $bk.ContainsKey($m[2])) {
            Log ("备份中无 " + $m[3] + " 的原值，保持现状不动") "warn"
            continue
        }
        Write-BackedValue $m[0] $m[1] $bk[$m[2]]
    }
    foreach ($m in (Get-MmPlan)) {
        # 备份里压根没这个键 = 当初没记录过原值，不能猜，保持现状不动
        if (-not $bk.ContainsKey($m.K)) {
            Log ("备份中无 " + $m.N + " 的原值，保持现状不动") "warn"
            continue
        }
        $ov = [string]$bk[$m.K]
        if ([string]::IsNullOrEmpty($ov) -or $ov -eq "NOTSET") {
            Remove-ItemProperty -Path $m.Path -Name $m.Name -Force -ErrorAction SilentlyContinue
        } else {
            if ($m.T -eq "DWord") {
                $iv = 0
                if ([int]::TryParse($ov,[ref]$iv)) { Set-ItemProperty -Path $m.Path -Name $m.Name -Value $iv -Type DWord -Force -ErrorAction SilentlyContinue }
            } else {
                Set-ItemProperty -Path $m.Path -Name $m.Name -Value $ov -Type String -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Step-Progress "正在还原鼠标与调度设置..."
    $msVals = @()
    $msAllKnown = $true
    foreach ($m in (Get-MousePlan)) {
        if (-not $bk.ContainsKey($m.K)) {
            Log ("备份中无 " + $m.N + " 的原值，保持现状不动") "warn"
            $msAllKnown = $false
            continue
        }
        $ov = [string]$bk[$m.K]
        if ([string]::IsNullOrEmpty($ov) -or $ov -eq "NOTSET") {
            Remove-ItemProperty -Path $K_MOUSE -Name $m.Name -Force -ErrorAction SilentlyContinue
            $msAllKnown = $false
        } else {
            Set-ItemProperty -Path $K_MOUSE -Name $m.Name -Value $ov -Type String -Force -ErrorAction SilentlyContinue
            $iv = 0
            [void][int]::TryParse($ov,[ref]$iv)
            $msVals += $iv
        }
    }
    # 三个原值都明确时，再用系统 API 把内存值也改回去；
    # 否则只动注册表，不去猜系统该用什么值
    if ($msAllKnown -and $msVals.Count -eq 3) {
        try { [void][MouseNative]::SetMouse($msVals[0],$msVals[1],$msVals[2]); Log "鼠标参数已经系统 API 还原" "ok" } catch { }
    }
    if ($bk.ContainsKey("NAGLE_IFS") -and $bk["NAGLE_IFS"]) {
        foreach ($g in ($bk["NAGLE_IFS"] -split ',')) {
            if (-not $g) { continue }
            $ipath = Join-Path $K_TCPIF $g.Trim()
            Remove-ItemProperty -Path $ipath -Name "TcpAckFrequency" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $ipath -Name "TCPNoDelay" -Force -ErrorAction SilentlyContinue
        }
        Log "已还原网络小包设置" "ok"
    }
    Log "注册表原值已逐条写回（含 VBS / MMCSS / 鼠标）" "ok"
    $hv = [string]$bk["HYPERVISOR"]
    if ([string]::IsNullOrEmpty($hv) -or $hv -eq "NOTSET") {
        bcdedit /deletevalue hypervisorlaunchtype 2>$null | Out-Null
        Log "已恢复虚拟化启动项（模拟器/虚拟机可用）" "ok"
    } else {
        bcdedit /set hypervisorlaunchtype $hv 2>$null | Out-Null
        Log ("hypervisorlaunchtype 写回 " + $hv) "ok"
    }
    Step-Progress "正在还原网络与虚拟化设置..."
    if (Test-Path $VBSFILE) { [System.IO.File]::Delete($VBSFILE) }
    foreach ($nm in $APEXNAMES) {
        if ($sync.ApexDir) { Remove-ItemProperty -Path $K_GPU -Name (Join-Path $sync.ApexDir $nm) -Force -ErrorAction SilentlyContinue }
    }
    Log "已移除 Apex 显卡首选项" "ok"
    Step-Progress "正在逐条校验还原结果..."
    $sync.Busy = $false
    Force-Refresh
    $res = Verify-Restore $bk
    Stop-Progress
    $bad = @($res | Where-Object { $_.State -eq "bad" }).Count
    $wrn = @($res | Where-Object { $_.State -eq "warn" }).Count
    if ($bad -eq 0 -and $wrn -eq 0) {
        Show-Result "还原全部设置" "已完全还原到初始状态" "ok" $res "全部 $($res.Count) 项与备份逐条比对一致。重启电脑后，模拟器和虚拟机恢复可用。"
    } elseif ($bad -eq 0) {
        Show-Result "还原全部设置" "已还原，$wrn 项需留意" "warn" $res "重启后生效。标黄的项请看右侧说明。"
    } else {
        Show-Result "还原全部设置" "还原后有 $bad 项与备份不一致" "bad" $res "标红的项没能还原成功，可以再点一次还原，或手动改回右侧显示的值。"
    }
}

# 把游戏进程钉在 P 核上并提高优先级。Windows 的线程调度器有时会把
# 游戏主线程放到 E 核，Apex 这种吃单核的老引擎掉帧很明显。
function Do-BindCore {
    $topo = Get-CpuTopo
    if ($topo.Kind -ne "Intel 混合架构") {
        Show-Result "绑定 P 核" ("本机是 " + $topo.Kind + "，不做绑核") "dim" `
            @(@{Item="处理器"; State="dim"; Detail=$topo.Name},
              @{Item="拓扑"; State="dim"; Detail=("" + $topo.Cores + " 核 / " + $topo.Threads + " 线程")},
              @{Item="判定"; State="dim"; Detail=$topo.Note}) `
            "只有 Intel 12 代及以后的大小核架构，绑到 P 核才有意义。本机不属于这种情况，强行绑核反而可能限制可用核心，所以不做处理。"
        return
    }
    $info = Get-PCoreInfo
    $procs = @()
    foreach ($nm in @("r5apex_dx12","r5apex")) {
        $procs += @(Get-Process -Name $nm -ErrorAction SilentlyContinue)
    }
    if ($procs.Count -eq 0) {
        Show-Result "绑定 P 核" "没有检测到正在运行的 Apex" "warn" `
            @(@{Item="CPU 拓扑"; State="ok"; Detail=("" + $info.PCores + " 个 P 核 / " + $info.ECores + " 个 E 核")},
              @{Item="游戏进程"; State="warn"; Detail="未运行"}) `
            "请先把游戏启动到大厅或对局中，再回来点这个按钮。设置在游戏关闭后失效，每局开始重新点一次即可。"
        return
    }
    $res = @()
    $res += @{Item="CPU 拓扑"; State="ok"; Detail=("" + $info.PCores + " P核(" + $info.PThreads + "线程) + " + $info.ECores + " E核")}
    foreach ($p in $procs) {
        $nm = $p.ProcessName
        try {
            $p.ProcessorAffinity = [IntPtr][int64]$info.Mask
            $okA = $true
        } catch { $okA = $false }
        try {
            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High
            $okP = $true
        } catch { $okP = $false }
        if ($okA) { $res += @{Item=($nm + " 亲和性"); State="ok"; Detail=("已钉到逻辑核 0-" + ($info.PThreads-1))} ; Log ($nm + " 已绑定 P 核") "ok" }
        else { $res += @{Item=($nm + " 亲和性"); State="bad"; Detail="被拒绝（反作弊或权限）"} ; Log ($nm + " 绑核被拒") "err" }
        if ($okP) { $res += @{Item=($nm + " 优先级"); State="ok"; Detail="高"} }
        else { $res += @{Item=($nm + " 优先级"); State="bad"; Detail="设置失败"} }
    }
    $bad = @($res | Where-Object { $_.State -eq "bad" }).Count
    if ($bad -eq 0) {
        Show-Result "绑定 P 核" "已绑定，本局有效" "ok" $res "游戏进程重启后需要重新点一次。这只是操作系统层面的调度设置，不涉及任何内存改写。"
    } else {
        $res += @{Item="原因"; State="dim"; Detail="Apex 由 EasyAntiCheat 保护，外部进程无法改它"}
        Show-Result "绑定 P 核" "反作弊不允许外部修改，属正常现象" "warn" $res `
            "这是 EAC 的正常保护行为，不是工具出错，也和封号无关。任务管理器同样会被拒绝。建议就此作罢：Windows 11 的任务分配机制对 12 代以后的大小核本来就有专门优化，绝大多数情况下会自己把游戏放在 P 核上。真想确认，用瓶颈实测看单核峰值即可。"
    }
}

# 跑一局采样，量出到底是 CPU 瓶颈、GPU 瓶颈还是撞温度墙
function Do-Bench {
    $procs = @()
    foreach ($nm in @("r5apex_dx12","r5apex")) { $procs += @(Get-Process -Name $nm -ErrorAction SilentlyContinue) }
    if ($procs.Count -eq 0) {
        Show-Result "瓶颈实测" "没有检测到正在运行的 Apex" "warn" `
            @(@{Item="游戏进程"; State="warn"; Detail="未运行"}) `
            "先进一局（训练场也行），再回来点这个按钮，采样 60 秒。"
        return
    }
    $vdz = Get-GpuVendor
    if (-not (Get-GpuLive)) {
        Show-Result "瓶颈实测" "读不到显卡实时数据，无法采样" "bad" `
            @(@{Item="显卡"; State="dim"; Detail=($vdz.Vendor + " " + $vdz.Name)},
              @{Item="GPU 引擎计数器"; State="bad"; Detail="不可用"}) `
            "Windows 的 GPU 性能计数器和厂商工具都读不到数据，无法判断瓶颈。"
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "瓶颈实测中"
    $dlg.ClientSize = (Sz 420 150)
    $dlg.StartPosition = "CenterParent"
    $dlg.BackColor = $C_BG; $dlg.ForeColor = $C_TEXT; $dlg.Font = $F_UI
    $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox=$false; $dlg.MinimizeBox=$false
    try { if ($form.Icon) { $dlg.Icon = $form.Icon } } catch { }
    New-Label "正在采样，请回到游戏里正常打一局" $F_H2 $C_TEXT 20 18 380 24 $dlg | Out-Null
    $lblP = New-Label "0 / 60 秒" $F_MONO $C_ACCENT 20 48 380 20 $dlg
    $pb = New-Object System.Windows.Forms.ProgressBar
    $pb.Location = (Pt 20 76); $pb.Size = (Sz 380 14); $pb.Maximum = 60; $pb.Style = "Continuous"
    $dlg.Controls.Add($pb)
    $btnStop = New-Object System.Windows.Forms.Button
    $btnStop.Text = "提前结束"; $btnStop.Font = $F_BTN
    $btnStop.Location = (Pt 300 104); $btnStop.Size = (Sz 100 32)
    $btnStop.FlatStyle = "Flat"; $btnStop.BackColor = $C_CARD2; $btnStop.ForeColor = $C_TEXT
    $btnStop.FlatAppearance.BorderColor = $C_LINE
    $dlg.Controls.Add($btnStop)

    $script:benchStop = $false
    $btnStop.Add_Click({ $script:benchStop = $true })
    $samples = New-Object System.Collections.ArrayList
    $bt = New-Object System.Windows.Forms.Timer
    $bt.Interval = 1000
    $sec = 0
    $bt.Add_Tick({
        $script:benchSec++
        $g = Get-GpuLive
        $cpu = 0
        try { $cpu = [int](Get-CimInstance Win32_Processor | Select-Object -First 1).LoadPercentage } catch { }
        $cm = Get-CpuCoreMax
        $coreMax = 0; $coreBusy = 0
        if ($cm) { $coreMax = $cm.Max; $coreBusy = $cm.Busy }
        if ($g) {
            $gu=0.0; $gc=0.0; $gw=0.0; $gt=0.0
            [double]::TryParse("$($g.Util)",[ref]$gu) | Out-Null
            [double]::TryParse("$($g.Clk)", [ref]$gc) | Out-Null
            [double]::TryParse("$($g.Watt)",[ref]$gw) | Out-Null
            [double]::TryParse("$($g.Temp)",[ref]$gt) | Out-Null
            [void]$script:benchData.Add(@{ U=$gu; C=$gc; W=$gw; T=$gt; Cpu=$cpu; CMax=$coreMax; CBusy=$coreBusy })
        }
        $lblP.Text = "" + $script:benchSec + "/60 秒   GPU " + $(if($g){$g.Util}else{"-"}) + "%   CPU总 " + $cpu + "%   单核峰值 " + $coreMax + "%"
        $pb.Value = [math]::Min($script:benchSec,60)
        if ($script:benchSec -ge 60 -or $script:benchStop) { $bt.Stop(); $dlg.Close() }
    })
    $script:benchSec = 0
    $script:benchData = New-Object System.Collections.ArrayList
    $dlg.Add_Shown({ $bt.Start() })
    [void]$dlg.ShowDialog($form)
    $bt.Stop()

    $data = @($script:benchData)
    if ($data.Count -lt 5) {
        Show-Result "瓶颈实测" "采样太少，无法判断" "warn" @(@{Item="有效样本"; State="warn"; Detail=("" + $data.Count + " 个")}) "至少需要 5 秒采样。"
        return
    }
    $hasTemp = @($data | Where-Object { $_.T -gt 0 }).Count -gt 0
    $avgU = [math]::Round(($data | ForEach-Object { $_.U } | Measure-Object -Average).Average,1)
    $maxT = [math]::Round(($data | ForEach-Object { $_.T } | Measure-Object -Maximum).Maximum,0)
    $avgW = [math]::Round(($data | ForEach-Object { $_.W } | Measure-Object -Average).Average,1)
    $maxC = [math]::Round(($data | ForEach-Object { $_.C } | Measure-Object -Maximum).Maximum,0)
    $avgC = [math]::Round(($data | ForEach-Object { $_.C } | Measure-Object -Average).Average,0)
    $avgCpu= [math]::Round(($data | ForEach-Object { $_.Cpu } | Measure-Object -Average).Average,0)
    $avgCMax = 0; $maxCMax = 0; $avgBusy = 0
    if ($data[0].ContainsKey("CMax")) {
        $avgCMax = [math]::Round(($data | ForEach-Object { $_.CMax } | Measure-Object -Average).Average,0)
        $maxCMax = [math]::Round(($data | ForEach-Object { $_.CMax } | Measure-Object -Maximum).Maximum,0)
        $avgBusy = [math]::Round(($data | ForEach-Object { $_.CBusy } | Measure-Object -Average).Average,1)
    }

    $res = @()
    $res += @{Item="有效样本"; State="ok"; Detail=("" + $data.Count + " 秒")}
    $res += @{Item="GPU 平均占用"; State="ok"; Detail=("" + $avgU + " %")}
    $res += @{Item="GPU 平均/峰值频率"; State="ok"; Detail=("" + $avgC + " / " + $maxC + " MHz")}
    $res += @{Item="GPU 平均功耗"; State="ok"; Detail=("" + $avgW + " W")}
    if ($hasTemp) { $res += @{Item="GPU 最高温度"; State=$(if($maxT -ge 87){"bad"}elseif($maxT -ge 80){"warn"}else{"ok"}); Detail=("" + $maxT + " C")} }
    else { $res += @{Item="GPU 最高温度"; State="dim"; Detail="本机读不到，未纳入判断"} }
    $res += @{Item="CPU 总占用"; State="dim"; Detail=("" + $avgCpu + " %   （多核机器上这个数天然就低）")}
    $res += @{Item="CPU 单核峰值"; State=$(if($avgCMax -ge 85){"warn"}else{"ok"}); Detail=("平均 " + $avgCMax + " %   最高 " + $maxCMax + " %")}
    $res += @{Item="满载核心数"; State="dim"; Detail=("平均 " + $avgBusy + " 个核心占用超 80%")}

    $verdict = "接近平衡"; $vstate = "ok"; $note = ""
    if ($avgU -ge 95) {
        $verdict = "显卡瓶颈"; $vstate = "warn"
        $note = "GPU 几乎满载。想提帧只能降画质或开 DLSS，关后台基本没用。"
    } elseif ($avgU -le 85 -and $avgCMax -ge 85) {
        $verdict = "CPU 单线程瓶颈"; $vstate = "warn"
        $note = "GPU 有空转，同时有核心长期接近满载 —— 这是典型的单线程瓶颈。" +
                "注意 CPU 总占用只有 " + $avgCpu + "%，这不代表 CPU 闲着：" +
                "你有 " + $(if($data[0].ContainsKey("CMax")){"多个"}else{"若干"}) + "逻辑核心，" +
                "跑满一个核在总占用上本来就只体现为很小的数字。" +
                "有效手段是提高单核频率（散热、降压、性能模式），降画质没用。"
    } elseif ($avgU -le 85) {
        $verdict = "未跑满，但不是 CPU 拖累"; $vstate = "ok"
        $note = "GPU 没满载，同时也没有核心接近满载（单核峰值 " + $avgCMax + "%）。" +
                "这种情况通常是帧数被引擎上限或 fps_max 锁住了，" +
                "或者当前场景本来就不吃资源。换个激烈场景再测一次更准。"
    } else {
        $note = "GPU 占用在中高区间，属于比较均衡的状态。"
    }
    $isLap = (Get-MachineKind).IsLaptop
    # 笔记本散热余量小，温度阈值下调，且结论里把散热排在第一位
    $tempWarn = 87
    if ($isLap) { $tempWarn = 83 }
    if ($hasTemp -and $maxT -ge $tempWarn) {
        $verdict = "撞温度墙"; $vstate = "bad"
        if ($isLap) {
            $note = "显卡最高 " + $maxT + "C。笔记本散热余量本来就小，温度一旦顶上来，" +
                    "CPU 和显卡都会降频，前面所有优化的效果都会被这一条抵消。" +
                    "优先做散热: 垫高机身、加散热底座、清灰换硅脂、确认厂商控制中心在性能档。"
        } else {
            $note = "显卡最高 " + $maxT + "C。先解决散热，其它优化在温度墙面前都会被抵消。"
        }
    }
    if ($isLap -and (Get-PowerSource) -eq "DC") {
        $note = "【本次采样时是电池供电】功耗墙已被大幅压低，这组数据不能代表插电时的真实水平，请插电后重测。  " + $note
        $vstate = "bad"
    }
    if (-not $hasTemp) { $note += "  注意：本机读不到显卡温度，无法判断是否撞温度墙。" }
    $res += @{Item="结论"; State=$vstate; Detail=$verdict}
    $fa = Get-FpsCapAdvice
    $res += @{Item="fps_max 建议上限"; State="dim"; Detail=("" + $fa.Cap + "   （" + $fa.Basis + "）")}
    if ($avgU -ge 95) {
        $note += "  另外：GPU 已满载，若帧数忽高忽低，把 fps_max 降到你能稳定守住的数值，帧生成时间会更平稳。"
    } elseif ($avgU -le 85 -and $avgCMax -lt 85) {
        $note += "  另外：两边都没满，先确认 fps_max 是不是设得比 " + $fa.Cap + " 还低，把它限住了。"
    }
    Show-Result "瓶颈实测" $verdict $vstate $res $note
}

# 游戏前准备 = 释放系统缓存 + 结束占用后台，合并成一次操作
function Do-Prep {
    # 内存整理在弹勾选框之前就执行完了。
    # 所以即使用户在进程那一步点了取消，也必须把已经做完的事报告出来，
    # 否则用户看不到任何反馈，会以为整个操作没生效。
    $memRes = Do-MemCore
    $procRes = Do-CleanCore
    $cancelled = ($null -eq $procRes)

    $res = @()
    $res += @{Item="── 内存 ──"; State="dim"; Detail=""}
    $res += $memRes
    $res += @{Item="── 后台进程 ──"; State="dim"; Detail=""}
    if ($cancelled) {
        $res += @{Item="后台清理"; State="dim"; Detail="已取消，未结束任何程序"}
    } elseif ($procRes.Count -eq 0) {
        $res += @{Item="后台清理"; State="ok"; Detail="没有检测到需要结束的程序"}
    } else {
        $res += $procRes
    }
    Force-Refresh

    $bad = @($res | Where-Object { $_.State -eq "bad" }).Count
    if ($bad -gt 0) {
        Show-Result "游戏前准备" "完成，$bad 项未成功" "warn" $res `
            "标红的项通常是权限不足或进程受保护，可以手动在任务管理器结束。"
    } elseif ($cancelled) {
        Show-Result "游戏前准备" "内存已整理，后台清理已取消" "ok" $res `
            "内存整理在弹出勾选框之前就已完成，这部分是生效的。后台程序一个都没有被结束。想清理的话再点一次即可。"
    } else {
        $extraNote = "被结束的程序下次开机照常启动，本工具不做任何禁用。这一步建议每次开局前执行。"
        if (@($res | Where-Object { "$($_.Detail)" -like "*已暂停*" }).Count -gt 0) {
            $extraNote += "  壁纸引擎是『暂停』不是关闭，进程还在，所以不会再出现异常退出的提示；想恢复动态壁纸，右键托盘图标选播放即可。"
        }
        Show-Result "游戏前准备" "准备完成" "ok" $res $extraNote
    }
}

function Do-MemCore {
    $before = Get-MemInfo
    if ($before.TotalMB -le 0) {
        return @(@{Item="内存信息"; State="bad"; Detail="系统查询失败"})
    }
    $res = @()
    Start-Progress "游戏前准备" 4
    Step-Progress "正在清理系统缓存..."
    $rc = -1
    try { $rc = [MemNative]::PurgeStandby() } catch { }
    if ($rc -eq 0) { Log "已清理系统缓存" "ok" } else { Log ("清理系统缓存失败，NTSTATUS=" + $rc) "err" }

    # 只有内存确实吃紧（已用 ≥85%）时才顺带清一次已用内存，
    # 平时不做，因为它会把在用的页刷出去，反而制造卡顿。
    $didWs = $false
    if ($before.UsedPct -ge 85) {
        try { [void][MemNative]::EmptyWorkingSets(); $didWs = $true; Log "内存吃紧，已额外回收已用内存" "warn" } catch { }
    }

    Step-Progress "正在等待系统回收完成..."
    Start-Sleep -Milliseconds 800
    $after = Get-MemInfo
    $freed = $after.AvailMB - $before.AvailMB
    $sbDrop = $before.StandbyMB - $after.StandbyMB

    $res += @{Item="系统缓存"; State=$(if($rc -eq 0){"ok"}else{"bad"}); Detail=$(if($rc -eq 0){"释放 " + $sbDrop + " MB"}else{"释放失败，权限不足"})}
    if ($didWs) { $res += @{Item="已用内存"; State="warn"; Detail="内存占用偏高，已一并释放"} }
    else { $res += @{Item="已用内存"; State="dim"; Detail="内存充足，按设计跳过"} }
    $res += @{Item="可用内存"; State="ok"; Detail=("" + $before.AvailMB + " MB  ->  " + $after.AvailMB + " MB")}
    return $res
}

function Do-PickDir {
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.Description = "选择 Apex Legends 安装目录（含 r5apex_dx12.exe 的文件夹）"
    if ($sync.ApexDir) { $fb.SelectedPath = $sync.ApexDir }
    if ($fb.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        $ex = Get-ApexExes $fb.SelectedPath
        if ($ex.Count -eq 0) {
            Log "该目录里没有 Apex 可执行文件，未采用" "err"
        } else {
            $sync.ApexDir = $fb.SelectedPath
            Log ("Apex 目录已设为 " + $fb.SelectedPath) "ok"
            Force-Refresh
        }
    }
}

$buttons["opt"].Add_Click({ Do-Optimize })
$buttons["vbs"].Add_Click({
    # 与 Sync-VbsButton 用同一套判定，避免按钮文字和实际动作对不上
    $d = $sync.Data
    $weTurnedOff = (Test-Path $VBSFILE)
    if ((-not $weTurnedOff) -and $d -and $d.HasBackup -and ($d.BkVbsWas -eq 1) -and (-not $d.Vbs)) { $weTurnedOff = $true }
    if ($weTurnedOff) { Do-VbsRestore } else { Do-VbsOff }
})
$buttons["bench"].Add_Click({ Do-Bench })
$buttons["prep"].Add_Click({ Do-Prep })
$buttons["rest"].Add_Click({ Do-Restore })
$buttons["dir"].Add_Click({ Do-PickDir })
$buttons["bk"].Add_Click({
    if (Test-Path $BKFILE) { Start-Process notepad.exe $BKFILE } else { Log "还没有备份文件" "warn" }
})

try {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    Boot-Log ("尺寸检查: 窗口=" + $form.Size.ToString() + " 工作区=" + $wa.ToString())
    if ($form.Height -gt $wa.Height -or $form.Width -gt $wa.Width) {
        Boot-Log "  超出工作区，改为可调整大小+滚动"
        $form.FormBorderStyle = "Sizable"
        $form.AutoScroll = $true
        $form.Size = New-Object System.Drawing.Size(
            [math]::Min($form.Width, $wa.Width), [math]::Min($form.Height, $wa.Height))
    }
} catch { }

$form.Add_Shown({
    Boot-Log "Shown 事件已触发"
    try {
        Boot-Log ("  窗口: Visible=" + $form.Visible + " State=" + $form.WindowState + " Handle=" + $form.Handle)
        Boot-Log ("  位置: " + $form.Location.ToString() + "  尺寸: " + $form.Size.ToString())
        $sc = [System.Windows.Forms.Screen]::FromControl($form)
        Boot-Log ("  所在屏幕: " + $sc.Bounds.ToString() + "  工作区: " + $sc.WorkingArea.ToString())
        Boot-Log ("  主屏工作区: " + [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.ToString())
    } catch { Boot-Log ("  状态读取失败: " + $_.Exception.Message) }
    # 强制把窗口摆到主屏中央并拉到前台，避免跑到屏幕外或被压在后面
    try {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $nx = $wa.X + [int](($wa.Width  - $form.Width ) / 2)
        $ny = $wa.Y + [int](($wa.Height - $form.Height) / 2)
        if ($nx -lt $wa.X) { $nx = $wa.X }
        if ($ny -lt $wa.Y) { $ny = $wa.Y }
        $form.Location = New-Object System.Drawing.Point($nx,$ny)
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        $form.ShowInTaskbar = $true
        $form.TopMost = $true
        $form.BringToFront()
        $form.Activate()
        [System.Windows.Forms.Application]::DoEvents()
        $form.TopMost = $false
        Boot-Log ("  已强制居中并激活 -> 新位置 " + $form.Location.ToString())
    } catch { Boot-Log ("  置前失败: " + $_.Exception.Message) }
    $timer.Start()
    Log "已就绪，状态每 1.5 秒自动刷新" "ok"
    Log ("DPI 缩放 " + [int]($SCALE*100) + "%") "dim"
    if ($APEXDIR) {
        $ex = Get-ApexExes $APEXDIR
        Log ("Apex: " + $APEXDIR) "dim"
        if ($ex.Count -gt 0) { Log ("检出 " + (($ex | ForEach-Object { Split-Path $_ -Leaf }) -join ", ")) "dim" }
    } else {
        Log "未自动找到 Apex，可用左侧按钮手动指定目录" "warn"
    }
    Force-Refresh
})
$form.Add_FormClosing({
    $timer.Stop()
    $sync.Stop = $true
    try { if ($script:APPMUTEX) { $script:APPMUTEX.ReleaseMutex(); $script:APPMUTEX.Dispose() } } catch { }
    try { $worker.Stop() } catch { }
    try { $rs.Close() } catch { }
})

# 关键：ShowDialog 不指定 owner 时会把"当前活动窗口"当父窗口。
# 启动提示窗是 TopMost 且处于活动状态，主窗口会成为它的子窗口；
# 一旦提示窗被关闭，父窗口销毁会连带销毁主窗口 —— 表现就是闪一下就没了。
# 所以必须在 ShowDialog 之前就把提示窗关干净。
try {
    if ($splash -and -not $splash.IsDisposed) {
        $splash.TopMost = $false
        $splash.Hide()
        $splash.Close()
        $splash.Dispose()
    }
    $splash = $null
    [System.Windows.Forms.Application]::DoEvents()
    Boot-Log "启动提示窗已关闭并释放"
} catch { Boot-Log ("关闭提示窗异常: " + $_.Exception.Message) }

Boot-Log "即将显示主窗口"
[void]$form.ShowDialog()
Boot-Log "主窗口已关闭"
