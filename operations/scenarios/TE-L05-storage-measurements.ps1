function Get-TEL05StorageObservation {
    param([string]$Assembly)

    $json = & dotnet $Assembly inspect-storage

    if ($LASTEXITCODE -ne 0) {
        throw "Storage observation command failed."
    }

    return $json | ConvertFrom-Json
}

function Save-TEL05StorageObservation {
    param(
        [pscustomobject]$Observation,
        [string]$ArtifactDirectory,
        [string]$Name
    )

    $Observation |
        ConvertTo-Json -Depth 4 |
        Set-Content (Join-Path $ArtifactDirectory "$Name.json")
}

function Invoke-TEL05PendingVariant {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int]$ContentCharacterCount,
        [string]$ArtifactDirectory
    )

    $variantDirectory = Join-Path `
        $ArtifactDirectory `
        "$ContentCharacterCount-content-characters"
    New-Item -ItemType Directory -Force -Path $variantDirectory | Out-Null

    Invoke-LoggedProcess $Assembly @("reset") $variantDirectory "reset"
    $empty = Get-TEL05StorageObservation $Assembly
    Save-TEL05StorageObservation $empty $variantDirectory "empty"

    Invoke-LoggedProcess `
        $Assembly `
        @(
            "publish-with-content",
            "TE-L05-pending",
            [string]$RowCount,
            [string]$ContentCharacterCount) `
        $variantDirectory `
        "publish"
    $populated = Get-TEL05StorageObservation $Assembly
    Save-TEL05StorageObservation $populated $variantDirectory "populated"

    $tableAllocatedBytes =
        $populated.TableAllocatedBytes -
        $empty.TableAllocatedBytes
    $indexAllocatedBytes =
        $populated.IndexAllocatedBytes -
        $empty.IndexAllocatedBytes
    $totalAllocatedBytes =
        $populated.TotalAllocatedBytes -
        $empty.TotalAllocatedBytes
    $physicalSizesAreConsistent =
        $populated.TotalAllocatedBytes -eq
        ($populated.TableAllocatedBytes + $populated.IndexAllocatedBytes)
    $passed =
        $empty.RowCount -eq 0 -and
        $populated.RowCount -eq $RowCount -and
        $populated.PayloadBytes -gt 0 -and
        $tableAllocatedBytes -gt 0 -and
        $indexAllocatedBytes -gt 0 -and
        $totalAllocatedBytes -gt 0 -and
        $totalAllocatedBytes -eq
        ($tableAllocatedBytes + $indexAllocatedBytes) -and
        $physicalSizesAreConsistent

    $result = [ordered]@{
        ContentCharacterCount = $ContentCharacterCount
        RowCount = $RowCount
        PayloadBytes = $populated.PayloadBytes
        TableAllocatedBytes = $tableAllocatedBytes
        IndexAllocatedBytes = $indexAllocatedBytes
        TotalAllocatedBytes = $totalAllocatedBytes
        PayloadBytesPerRow = [Math]::Round(
            $populated.PayloadBytes / $RowCount,
            2)
        TableAllocatedBytesPerRow = [Math]::Round(
            $tableAllocatedBytes / $RowCount,
            2)
        IndexAllocatedBytesPerRow = [Math]::Round(
            $indexAllocatedBytes / $RowCount,
            2)
        TotalAllocatedBytesPerRow = [Math]::Round(
            $totalAllocatedBytes / $RowCount,
            2)
        EmptyObservation = $empty
        PopulatedObservation = $populated
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 6 |
        Set-Content (Join-Path $variantDirectory "result.json")
    return [pscustomobject]$result
}

function Test-TEL05StorageGrowth {
    param([pscustomobject[]]$Variants)

    for ($index = 1; $index -lt $Variants.Count; $index++) {
        $previous = $Variants[$index - 1]
        $current = $Variants[$index]

        $contentIsLarger =
            $current.ContentCharacterCount -gt
            $previous.ContentCharacterCount
        $payloadDidNotGrow =
            $current.PayloadBytesPerRow -le
            $previous.PayloadBytesPerRow
        $physicalStorageDidNotGrow =
            $current.TotalAllocatedBytesPerRow -le
            $previous.TotalAllocatedBytesPerRow

        if ($contentIsLarger -and
            ($payloadDidNotGrow -or $physicalStorageDidNotGrow)) {
            return $false
        }
    }

    return $true
}

function Invoke-TEL05StorageMeasurements {
    param(
        [string]$Assembly,
        [int]$RowCount,
        [int[]]$ContentCharacterCounts,
        [string]$ArtifactDirectory
    )

    $scenarioDirectory = Join-Path $ArtifactDirectory "TE-L05"
    New-Item -ItemType Directory -Force -Path $scenarioDirectory | Out-Null

    $variants = @(
        foreach ($contentCharacterCount in $ContentCharacterCounts) {
            Invoke-TEL05PendingVariant `
                $Assembly `
                $RowCount `
                $contentCharacterCount `
                $scenarioDirectory
        })
    $storageGrowthIsMonotonic = Test-TEL05StorageGrowth $variants
    $passed =
        $variants.AcceptancePassed -notcontains $false -and
        $storageGrowthIsMonotonic
    $result = [ordered]@{
        Scenario = "TE-L05"
        Measurement = "Pending payload curve"
        Variants = $variants
        StorageGrowthIsMonotonic = $storageGrowthIsMonotonic
        AcceptancePassed = $passed
    }

    $result |
        ConvertTo-Json -Depth 8 |
        Set-Content (Join-Path $scenarioDirectory "result.json")
    return [pscustomobject]$result
}

if ($MyInvocation.InvocationName -ne ".") {
    $runner = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "Run-StorageMeasurements.ps1"
    & $runner
}
