function Invoke-Native {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-LoggedProcess {
    param(
        [string]$Assembly,
        [string[]]$Arguments,
        [string]$ArtifactDirectory,
        [string]$Name
    )

    $standardOutput = Join-Path $ArtifactDirectory "$Name.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$Name.stderr.log"
    $process = Start-Process `
        -FilePath "dotnet" `
        -ArgumentList (@($Assembly) + $Arguments) `
        -RedirectStandardOutput $standardOutput `
        -RedirectStandardError $standardError `
        -WindowStyle Hidden `
        -Wait `
        -PassThru

    if ($process.ExitCode -ne 0) {
        throw "Operational command '$Name' failed with exit code $($process.ExitCode)."
    }
}

function Start-LoggedDotNetProcess {
    param(
        [string]$Assembly,
        [string[]]$Arguments,
        [string]$ArtifactDirectory,
        [string]$Name
    )

    $standardOutput = Join-Path $ArtifactDirectory "$Name.stdout.log"
    $standardError = Join-Path $ArtifactDirectory "$Name.stderr.log"
    $quotedArguments = @($Assembly) + $Arguments |
        ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "dotnet"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = $quotedArguments -join " "

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    if (!$process.Start()) {
        throw "Process '$Name' could not be started."
    }

    return [pscustomobject]@{
        Name = $Name
        Process = $process
        OutputPath = $standardOutput
        ErrorPath = $standardError
        OutputTask = $process.StandardOutput.ReadToEndAsync()
        ErrorTask = $process.StandardError.ReadToEndAsync()
    }
}

function Complete-LoggedProcess {
    param(
        [pscustomobject]$ProcessHandle,
        [int]$TimeoutMilliseconds
    )

    $process = $ProcessHandle.Process

    if (!$process.WaitForExit($TimeoutMilliseconds)) {
        throw "Process '$($ProcessHandle.Name)' did not finish within $TimeoutMilliseconds milliseconds."
    }

    $process.WaitForExit()
    $process.Refresh()
    $standardOutput = $ProcessHandle.OutputTask.GetAwaiter().GetResult()
    $standardError = $ProcessHandle.ErrorTask.GetAwaiter().GetResult()
    $standardOutput | Set-Content $ProcessHandle.OutputPath
    $standardError | Set-Content $ProcessHandle.ErrorPath

    if ($process.ExitCode -ne 0) {
        throw "Process '$($ProcessHandle.Name)' failed with exit code $($process.ExitCode)."
    }
}
