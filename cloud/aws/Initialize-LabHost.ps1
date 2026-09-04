[CmdletBinding()]
param(
    [string]$AwsProfile = "default"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot "Common.ps1")

$output = Get-LabTerraformOutput
$region = $output.aws_region.value
$bucket = $output.results_bucket.value
$instanceId = $output.instance_id.value
Assert-AwsIdentity $AwsProfile $region | Out-Null

$shell = @'
set -euo pipefail
root=/opt/tinyevents-lab
manifest="$root/source-manifest.json"
aws s3 cp "s3://__BUCKET__/sources/source-manifest.json" "$manifest" --only-show-errors
rm -rf "$root/sources/TinyEvents" "$root/sources/TinyEvents.Dogfood"
mkdir -p "$root/sources/TinyEvents" "$root/sources/TinyEvents.Dogfood"
for name in TinyEvents TinyEvents.Dogfood; do
  key="$(jq -r --arg name "$name" '.Repositories[] | select(.Name == $name) | .Key' "$manifest")"
  expected="$(jq -r --arg name "$name" '.Repositories[] | select(.Name == $name) | .Sha256' "$manifest")"
  archive="$root/$name.zip"
  aws s3 cp "s3://__BUCKET__/$key" "$archive" --only-show-errors
  actual="$(sha256sum "$archive" | awk '{print toupper($1)}')"
  test "$actual" = "$expected"
  unzip -q "$archive" -d "$root/sources/$name"
done
pwsh -NoLogo -NoProfile -File "$root/sources/TinyEvents.Dogfood/cloud/aws/host/Install-LabHost.ps1"
'@
$shell = $shell.Replace("__BUCKET__", $bucket)
$parametersPath = Join-Path ([System.IO.Path]::GetTempPath()) "tinyevents-ssm-$([Guid]::NewGuid().ToString('N')).json"

try {
    @{ commands = @($shell) } |
        ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $parametersPath

    $commandId = & aws ssm send-command `
        --profile $AwsProfile `
        --region $region `
        --instance-ids $instanceId `
        --document-name "AWS-RunShellScript" `
        --timeout-seconds 1800 `
        --parameters "file://$parametersPath" `
        --query "Command.CommandId" `
        --output text

    if ($LASTEXITCODE -ne 0) {
        throw "Could not start host initialization on '$instanceId'."
    }

    Write-Host "Host initialization command: $($commandId.Trim())"
    Write-Host "The command builds TinyEvents, starts PostgreSQL and monitoring, runs the smoke test, and uploads evidence."
}
finally {
    if (Test-Path -LiteralPath $parametersPath) {
        Remove-Item -LiteralPath $parametersPath -Force
    }
}

