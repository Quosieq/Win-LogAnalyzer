<#
.SYNOPSIS
Windows Log Analyzer - Scans log files for errors and provides decoded explanations.
#>

param(
    [string]$LogPath,
    [int]$ErrorCount = 100,
    [switch]$AutoExit,
    [switch]$AnalyzeAll
)

function CheckLog {
    param(
        [string]$Directory,
        [int]$Lines = 100,
        [switch]$BatchMode
    )

    # Load error codes from file
    $errorCodeFile = "$PSScriptRoot\ErrorLib\wu_errorcodes.txt"
    $errorCodeMap = @{}
    if (Test-Path $errorCodeFile) {
        Get-Content $errorCodeFile | ForEach-Object {
            if ($_ -match "([0-9A-Fa-f]{8})\s+(.*)") {
                $errorCodeMap["0x$($Matches[1])"] = $Matches[2].Trim()
            }
        }
    }

    $ReadDate = Get-Date -Format "yyyyMMdd_HHmmss"
    $logName = [System.IO.Path]::GetFileNameWithoutExtension($Directory)
    $outputFile = "$PSScriptRoot\LogsSummary\LogReaderSummary_${logName}_${ReadDate}.log"

    if (-not (Test-Path "$PSScriptRoot\LogsSummary")) {
        New-Item -ItemType Directory -Path "$PSScriptRoot\LogsSummary" -Force | Out-Null
    }

    try {
        $errorLines = Get-Content -Path $Directory -ErrorAction Stop | 
                      Where-Object { $_ -match "error|fail" -and $_ -notmatch "\.fail" } |
                      Select-Object -Last $Lines
    }
    catch {
        if (-not $BatchMode) {
            Write-Host "Error reading log file: $_" -ForegroundColor Red
        }
        return $false
    }

    $outputContent = @()
    $errorsFound = $false

    if ($null -eq $errorLines -or $errorLines.Count -eq 0) {
        $message = "No errors found in log: $logName"
        if (-not $BatchMode) {
            Write-Host $message -ForegroundColor Green
            $saveChoice = Read-Host "Would you like to save an empty summary anyway? (Y/N)"
            if ($saveChoice -in 'Y','y') {
                $outputContent += $message
                $outputContent -join "`r`n" | Out-File -FilePath $outputFile -Encoding utf8 -Force
                Write-Host "Empty summary saved to: $outputFile" -ForegroundColor Cyan
            }
        }
        return $false
    }
    else {
        $errorsFound = $true
        foreach ($line in $errorLines) {
            $cleanLine = $line.Trim()
            $outputContent += $cleanLine
            
            if ($cleanLine -match "(0x[0-9A-Fa-f]{6,8})") {
                $errorCode = $Matches[1]
                $decodedMsg = $null
                
                # First try the error code map
                if ($errorCodeMap.ContainsKey($errorCode)) {
                    $decodedMsg = "   Error Code: $errorCode `n   Message: $($errorCodeMap[$errorCode])"
                }
                # Fall back to Win32Exception
                else {
                    try {
                        $errorInt = [Convert]::ToInt32($errorCode.Replace("0x", ""), 16)
                        $errorMsg = [System.ComponentModel.Win32Exception]$errorInt
                        $decodedMsg = "   Error Code: $errorCode `n   Message: $($errorMsg.Message)"
                    }
                    catch {
                        $decodedMsg = "   [Could not decode error: $errorCode]"
                    }
                }
                
                $outputContent += $decodedMsg
                if (-not $BatchMode) {
                    Write-Host $cleanLine -ForegroundColor Yellow
                    Write-Host $decodedMsg -ForegroundColor Cyan
                }
            }
            elseif (-not $BatchMode) {
                Write-Host $cleanLine -ForegroundColor Yellow
            }
        }
    }

    if ($errorsFound) {
        $outputContent -join "`r`n" | Out-File -FilePath $outputFile -Encoding utf8 -Force
        if (-not $BatchMode) {
            Write-Host "`nSummary saved to: $outputFile" -ForegroundColor Cyan
        }
        return $true
    }
    return $false
}

# Main execution
if (-not $PSBoundParameters.ContainsKey('LogPath') -and -not $AnalyzeAll) {
    Write-Host "`n=== Windows Log Analyzer ===" -ForegroundColor Magenta
}

do {
    if (-not $PSBoundParameters.ContainsKey('LogPath') -and -not $AnalyzeAll) {
        do {
            $choice = Read-Host "Choose option:`n1. Scan SavedLogs directory`n2. Specify custom log path`n3. Analyze all logs in SavedLogs`n(1/2/3)"
        } while ($choice -notin '1','2','3')

        if ($choice -eq '3') {
            $AnalyzeAll = $true
            $choice = '1' # Fall through to analyze all
        }

        if ($choice -eq '1') {
            $logDir = "$PSScriptRoot\SavedLogs"
            if (-not (Test-Path -Path $logDir)) {
                Write-Host "SavedLogs directory not found!" -ForegroundColor Red
                if (-not $AnalyzeAll) { exit 1 }
                continue
            }

            $logs = @(Get-ChildItem -Path $logDir -File | Where-Object { 
                $_.Extension -in '.log','.txt' 
            })
            
            if ($logs.Count -eq 0) {
                Write-Host "No log files found in SavedLogs!" -ForegroundColor Red
                if (-not $AnalyzeAll) { exit 1 }
                continue
            }

            if (-not $AnalyzeAll) {
                Write-Host "`nAvailable logs:" -ForegroundColor Cyan
                $logs | ForEach-Object { Write-Host "  $($logs.IndexOf($_) + 1)) $($_.Name)" }

                do {
                    $selection = Read-Host "`nEnter log number (1-$($logs.Count))"
                } while (-not ($selection -match '^\d+$') -or [int]$selection -lt 1 -or [int]$selection -gt $logs.Count)

                $LogPath = $logs[[int]$selection-1].FullName
            }
            else {
                # Analyze all logs in batch mode
                Write-Host "`nAnalyzing all logs in SavedLogs..." -ForegroundColor Cyan
                $processedCount = 0
                $errorCountTotal = 0
                
                foreach ($log in $logs) {
                    Write-Host "`nProcessing: $($log.Name)" -ForegroundColor Yellow
                    $hasErrors = Check-Log -Directory $log.FullName -Lines $ErrorCount -BatchMode
                    if ($hasErrors) { $errorCountTotal++ }
                    $processedCount++
                }
                
                Write-Host "`nAnalysis complete!" -ForegroundColor Green
                Write-Host "Processed $processedCount logs, found errors in $errorCountTotal" -ForegroundColor Cyan
                $AnalyzeAll = $false
                continue
            }
        }
        else {
            do {
                $LogPath = Read-Host "`nEnter full path to log file"
                $LogPath = $LogPath.Trim('"',"'")
                if (-not (Test-Path -Path $LogPath -PathType Leaf)) {
                    Write-Host "Invalid path or file doesn't exist!" -ForegroundColor Red
                }
            } while (-not (Test-Path -Path $LogPath -PathType Leaf))

            $copyChoice = Read-Host "`nWould you like to copy this log to SavedLogs for future use? (Y/N)"
            if ($copyChoice -in 'Y','y') {
                $savedLogsDir = "$PSScriptRoot\SavedLogs"
                if (-not (Test-Path -Path $savedLogsDir)) {
                    New-Item -ItemType Directory -Path $savedLogsDir -Force | Out-Null
                }
                
                $destPath = Join-Path -Path $savedLogsDir -ChildPath (Split-Path -Leaf $LogPath)
                try {
                    Copy-Item -Path $LogPath -Destination $destPath -Force
                    Write-Host "Log copied to: $destPath" -ForegroundColor Green
                }
                catch {
                    Write-Host "Failed to copy log: $_" -ForegroundColor Red
                }
            }
        }
    }

    if (-not $AnalyzeAll) {
        if (-not $PSBoundParameters.ContainsKey('ErrorCount')) {
            do {
                $ErrorCount = Read-Host "`nNumber of lines to check for error (default: 100)"
                if ([string]::IsNullOrWhiteSpace($ErrorCount)) { $ErrorCount = 100 }
            } while (-not ($ErrorCount -match '^\d+$'))
        }

        Check-Log -Directory $LogPath -Lines $ErrorCount
    }

    if (-not $AutoExit -and -not $AnalyzeAll) {
        $anotherLog = Read-Host "`nWould you like to analyze another log? (Y/N)"
        if ($anotherLog -notin 'Y','y') {
            break
        }
        # Reset parameters for new analysis
        $LogPath = $null
        $ErrorCount = 100
    }
} while ($true)

if (-not $AutoExit) {
    Write-Host "`nDone! Press any key to exit..." -ForegroundColor Magenta
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Clear-Host
}