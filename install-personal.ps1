[CmdletBinding()]
param(
    [switch]$LibraryOnly,
    [string]$PackagePath,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\SelectAsk'),
    [string]$DataDirectory = (Join-Path $env:LOCALAPPDATA 'SelectAsk'),
    [switch]$NoLaunch,
    [switch]$NoShortcuts,
    [string]$CredentialTarget
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + $env:PSModulePath

function Initialize-PersonalCredential {
    if ('SelectAskPersonalCredential' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class SelectAskPersonalCredential {
    public static string Read(string target) {
        IntPtr pointer;
        if (!CredRead(target, 1, 0, out pointer)) {
            int error = Marshal.GetLastWin32Error();
            if (error == 1168) return null;
            throw new Win32Exception(error);
        }
        try {
            Credential value = (Credential)Marshal.PtrToStructure(pointer, typeof(Credential));
            return Marshal.PtrToStringUni(value.Blob, checked((int)value.BlobSize / 2));
        } finally { CredFree(pointer); }
    }
    public static void Write(string target, string key) {
        if (String.IsNullOrEmpty(key)) {
            if (!CredDelete(target, 1, 0) && Marshal.GetLastWin32Error() != 1168)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return;
        }
        IntPtr pointer = Marshal.StringToCoTaskMemUni(key);
        try {
            Credential value = new Credential();
            value.Type = 1; value.TargetName = target; value.UserName = "SelectAsk API";
            value.Blob = pointer; value.BlobSize = checked((uint)key.Length * 2); value.Persist = 2;
            if (!CredWrite(ref value, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        } finally { Marshal.ZeroFreeCoTaskMemUnicode(pointer); }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint BlobSize; public IntPtr Blob;
        public uint Persist, AttributeCount; public IntPtr Attributes;
        public string TargetAlias, UserName;
    }
    [DllImport("advapi32.dll", EntryPoint="CredReadW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr pointer);
    [DllImport("advapi32.dll", EntryPoint="CredWriteW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredWrite(ref Credential value, uint flags);
    [DllImport("advapi32.dll", EntryPoint="CredDeleteW", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool CredDelete(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr pointer);
}
'@
}

function Write-PersonalSettings([string]$Path, [byte[]]$Bytes) {
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Invoke-PersonalInstall {
    $key = $env:SELECTASK_SETUP_KEY
    $providerText = $env:SELECTASK_SETUP_PROVIDER
    $model = $env:SELECTASK_SETUP_MODEL
    foreach ($name in @('SELECTASK_SETUP_KEY', 'SELECTASK_SETUP_PROVIDER', 'SELECTASK_SETUP_MODEL')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    $phase = 'validate'; $work = $null; $snapshotReady = $false; $configured = $false
    $oldKey = $null; $oldSettings = $null; $stopped = @(); $setupMutex = $null; $ownsMutex = $false
    try {
        if ($env:OS -ne 'Windows_NT') { throw 'Windows required.' }
        if ($key -notmatch '^[A-Za-z0-9._-]{16,512}$' -or $providerText -notmatch '^[012]$' -or $model -notmatch '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$') { throw 'Invalid setup input.' }
        $provider = [int]$providerText
        $providerName = @('DeepSeek', 'Gemini', 'OpenAI')[$provider]
        $target = 'SelectAsk/' + $providerName
        if ($CredentialTarget) {
            if (-not $NoLaunch -or $CredentialTarget -notmatch '^SelectAsk/SetupTest-[A-Za-z0-9-]+$') { throw 'Invalid isolated credential target.' }
            $target = $CredentialTarget
        }
        $install = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
        $data = [IO.Path]::GetFullPath($DataDirectory).TrimEnd('\')
        $defaultData = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'SelectAsk')).TrimEnd('\')
        if ($data -ne $defaultData -and (-not $NoLaunch -or -not $CredentialTarget)) { throw 'Isolated data needs isolated credential and NoLaunch.' }
        $setupMutex = [Threading.Mutex]::new($false, 'Local\SelectAsk.PersonalSetup')
        try { $ownsMutex = $setupMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'Another personal setup is running.' }
        $running = @()
        if (-not $NoLaunch) {
            $running = @(Get-Process -Name SelectAsk -ErrorAction SilentlyContinue)
            foreach ($process in $running) {
                if (-not $process.Path -or -not $process.Path.StartsWith(($install + '\versions\'), [StringComparison]::OrdinalIgnoreCase)) { throw 'Close the other SelectAsk copy first.' }
            }
        }
        Initialize-PersonalCredential
        $settingsPath = Join-Path $data 'settings.json'
        if (Test-Path -LiteralPath $settingsPath) {
            $oldSettings = [IO.File]::ReadAllBytes($settingsPath)
            $null = [Text.Encoding]::UTF8.GetString($oldSettings) | ConvertFrom-Json
        }
        $oldKey = [SelectAskPersonalCredential]::Read($target)
        $snapshotReady = $true
        $phase = 'download'
        $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        $work = Join-Path $temporaryRoot ('SelectAsk-Personal-' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($work)
        Write-Host ('WORK_DIRECTORY: ' + $work)
        $zip = Join-Path $work 'package.zip'
        if ($PackagePath) { Copy-Item -LiteralPath $PackagePath -Destination $zip }
        else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $client = New-Object Net.WebClient
            try { $client.DownloadFile('https://github.com/tuanit213/selectask-releases/releases/download/v1.0.0/SelectAsk-1.0.0-Windows.zip', $zip) }
            finally { $client.Dispose() }
        }
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne 'A07D3EAC789428D3379EE3E00E15D359E125A2571133AC3E5C9F40ABE945F650') { throw 'Package hash mismatch.' }
        Write-Host 'SHA256 OK'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $app = Join-Path $work 'app'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $app)
        $phase = 'install'
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $app 'scripts\install.ps1'), '-NoPrompt', '-NoLaunch', '-InstallDirectory', $install, '-DataDirectory', $data)
        if ($NoShortcuts) { $arguments += '-NoShortcuts' }
        & powershell.exe @arguments
        if ($LASTEXITCODE -ne 0) { throw 'Installer failed.' }
        $manifest = Get-Content -LiteralPath (Join-Path $install 'current.json') -Raw | ConvertFrom-Json
        if (-not $manifest.Executable.StartsWith(($install + '\versions\'), [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $manifest.Executable)) { throw 'Invalid installed executable.' }
        $phase = 'configure'
        foreach ($process in $running) {
            $stopped += $process.Path
            Stop-Process -Id $process.Id -ErrorAction Stop
            if (-not $process.WaitForExit(5000)) { throw 'App has not stopped.' }
        }
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        foreach ($field in @{ Provider = $provider; Model = $model; Demo = $false; Enabled = $true; Mode = 0 }.GetEnumerator()) {
            $settings | Add-Member -NotePropertyName $field.Key -NotePropertyValue $field.Value -Force
        }
        if (-not $settings.ProviderModels) { $settings | Add-Member -NotePropertyName ProviderModels -NotePropertyValue ([pscustomobject]@{}) -Force }
        $settings.ProviderModels | Add-Member -NotePropertyName $providerName -NotePropertyValue $model -Force
        [SelectAskPersonalCredential]::Write($target, $key)
        Write-PersonalSettings $settingsPath ([Text.Encoding]::UTF8.GetBytes(($settings | ConvertTo-Json -Depth 8)))
        if ([SelectAskPersonalCredential]::Read($target) -cne $key) { throw 'Credential verification failed.' }
        $verified = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        if ($verified.Demo -or -not $verified.Enabled -or $verified.Provider -ne $provider -or $verified.Model -cne $model) { throw 'Settings verification failed.' }
        $phase = 'launch'
        if (-not $NoLaunch) {
            $process = Start-Process -FilePath $manifest.Executable -ArgumentList '--background' -WorkingDirectory (Split-Path $manifest.Executable -Parent) -WindowStyle Hidden -PassThru
            Start-Sleep -Seconds 2
            $process.Refresh()
            if ($process.HasExited) { throw 'App exited on startup.' }
            Write-Host ('RUNNING_PID: ' + $process.Id)
        }
        $configured = $true
        Write-Host ('PERSONAL_INSTALL_OK; Provider=' + $providerName + '; Model=' + $model + '; Demo=False; Enabled=True')
    } catch {
        if ($snapshotReady -and -not $configured) {
            try {
                [SelectAskPersonalCredential]::Write($target, $oldKey)
                if ($null -ne $oldSettings) { Write-PersonalSettings $settingsPath $oldSettings }
                elseif (Test-Path -LiteralPath $settingsPath) { Remove-Item -LiteralPath $settingsPath -Force }
                foreach ($exe in $stopped) { Start-Process -FilePath $exe -ArgumentList '--background' -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Hidden }
                Write-Host 'CONFIGURATION_RESTORED'
            } catch { Write-Host 'CONFIGURATION_RESTORE_FAILED' }
        }
        # Never expose command input, credential values or raw exception records.
        throw ('PERSONAL_INSTALL_FAILED; phase=' + $phase)
    } finally {
        $key = $null; $oldKey = $null
        if ($work) {
            $resolved = [IO.Path]::GetFullPath($work)
            if ((Split-Path $resolved -Parent) -eq $temporaryRoot -and [IO.Path]::GetFileName($resolved) -match '^SelectAsk-Personal-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $resolved)) {
                Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        if ($ownsMutex) { $setupMutex.ReleaseMutex() }
        if ($setupMutex) { $setupMutex.Dispose() }
    }
}

if (-not $LibraryOnly) {
    try { Invoke-PersonalInstall }
    catch { Write-Host $_.Exception.Message; exit 1 }
}
