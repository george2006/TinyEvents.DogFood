#requires -Version 7.4
Set-StrictMode -Version Latest

function Invoke-BootstrapAws {
    param(
        [Parameter(Mandatory)][string[]]$Command,
        [AllowEmptyString()][string]$Profile,
        [string]$Region = 'eu-west-1',
        [object]$InputObject,
        [switch]$SensitiveInput,
        [switch]$AllowMissing,
        [switch]$RawOutput,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 120
    )

    $temporaryDirectory = $null
    $process = $null
    try {
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Command aws -ErrorAction Stop).Source)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.Environment['AWS_PAGER'] = ''
        $start.Environment['AWS_CLI_AUTO_PROMPT'] = 'off'
        $start.Environment['AWS_MAX_ATTEMPTS'] = '2'
        foreach ($argument in $Command) { $start.ArgumentList.Add($argument) }
        if ($Profile) {
            $start.ArgumentList.Add('--profile')
            $start.ArgumentList.Add($Profile)
        }
        foreach ($argument in @('--region', $Region, '--no-cli-pager')) { $start.ArgumentList.Add($argument) }
        # `aws configure get` does not accept the service API timeout/output flags.
        if ($Command[0] -ne 'configure') {
            foreach ($argument in @('--output', 'json', '--cli-connect-timeout', '10', '--cli-read-timeout', '30')) {
                $start.ArgumentList.Add($argument)
            }
        }
        if ($null -ne $InputObject) {
            $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "tinyevents-bootstrap-$([Guid]::NewGuid().ToString('N'))"
            if ($IsWindows) {
                $security = [Security.AccessControl.DirectorySecurity]::new()
                $security.SetAccessRuleProtection($true, $false)
                $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
                $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                    $sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $security.AddAccessRule($rule)
                [IO.FileSystemAclExtensions]::Create([IO.DirectoryInfo]::new($temporaryDirectory), $security) | Out-Null
            }
            else {
                [IO.Directory]::CreateDirectory($temporaryDirectory,
                    [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute) | Out-Null
            }
            $inputPath = Join-Path $temporaryDirectory 'request.json'
            $InputObject | ConvertTo-Json -Depth 50 -Compress | Set-Content -LiteralPath $inputPath -Encoding utf8NoBOM
            $start.ArgumentList.Add('--cli-input-json')
            $start.ArgumentList.Add("file://$inputPath")
        }
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "AWS $($Command[0]) $($Command[1]) exceeded its time budget."
        }
        $outputText = $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            if ($AllowMissing -and $Command[0] -eq 'configure' -and $process.ExitCode -eq 1 -and [string]::IsNullOrWhiteSpace($errorText)) { return $null }
            if ($AllowMissing -and $errorText -match '\(NoSuchEntity\)') { return $null }
            if ($SensitiveInput) { throw "AWS $($Command[0]) $($Command[1]) failed; sensitive diagnostics suppressed." }
            throw "AWS $($Command[0]) $($Command[1]) failed: $errorText"
        }
        # Never return a sensitive API's output, even if a wrapper echoes the request.
        if ($SensitiveInput) { return }
        if ($RawOutput) { return $outputText.Trim() }
        if (![string]::IsNullOrWhiteSpace($outputText)) { return ($outputText | ConvertFrom-Json) }
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
        if ($null -ne $temporaryDirectory -and (Test-Path -LiteralPath $temporaryDirectory)) {
            # Exact files created by this call; no recursive or wildcard deletion.
            $inputPath = Join-Path $temporaryDirectory 'request.json'
            if (Test-Path -LiteralPath $inputPath) { Remove-Item -LiteralPath $inputPath -Force }
            Remove-Item -LiteralPath $temporaryDirectory -Force
        }
    }
}
