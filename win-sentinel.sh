#!/bin/bash

# Win Sentinel
# Bash wrapper + PowerShell sensors + optional OpenAI analysis.
# Run from PowerShell/Git Bash/ConEmu:
# bash win-sentinel.sh
#
# AI mode:
# export OPENAI_API_KEY="your_key_here"
# bash win-sentinel.sh --ai

REPORT_FILE="win-sentinel-report.txt"

run_ps() {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$1"
}

section() {
  echo
  echo "================================="
  echo "$1"
  echo "================================="
}

collect_report() {
  {
    echo "WIN SENTINEL SYSTEM REPORT"
    echo "Generated: $(date)"
    echo

    echo "[1] UPTIME"
    run_ps "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime"
    echo

    echo "[2] TOP CPU PROCESSES"
    run_ps "Get-Process | Sort-Object CPU -Descending | Select-Object -First 10 Id,ProcessName,CPU,@{Name='MemoryMB';Expression={[math]::Round(\$_.WorkingSet/1MB,2)}} | Format-Table -AutoSize"
    echo

    echo "[3] TOP MEMORY PROCESSES"
    run_ps "Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 10 Id,ProcessName,@{Name='MemoryMB';Expression={[math]::Round(\$_.WorkingSet/1MB,2)}},CPU | Format-Table -AutoSize"
    echo

    echo "[4] MEMORY USAGE"
    run_ps "\$os = Get-CimInstance Win32_OperatingSystem; [PSCustomObject]@{TotalRAMGB=[math]::Round(\$os.TotalVisibleMemorySize/1MB,2); FreeRAMGB=[math]::Round(\$os.FreePhysicalMemory/1MB,2); UsedRAMGB=[math]::Round((\$os.TotalVisibleMemorySize-\$os.FreePhysicalMemory)/1MB,2); PercentUsed=[math]::Round(((\$os.TotalVisibleMemorySize-\$os.FreePhysicalMemory)/\$os.TotalVisibleMemorySize)*100,2)} | Format-Table -AutoSize"
    echo

    echo "[5] DISK USAGE"
    run_ps "Get-CimInstance Win32_LogicalDisk -Filter \"DriveType=3\" | Select-Object DeviceID,@{Name='SizeGB';Expression={[math]::Round(\$_.Size/1GB,2)}},@{Name='FreeGB';Expression={[math]::Round(\$_.FreeSpace/1GB,2)}},@{Name='PercentFree';Expression={[math]::Round((\$_.FreeSpace/\$_.Size)*100,2)}} | Format-Table -AutoSize"
    echo

    echo "[6] STARTUP PROGRAMS"
    run_ps "Get-CimInstance Win32_StartupCommand | Select-Object Name,Location,Command | Format-Table -AutoSize"
    echo

    echo "[7] LISTENING NETWORK PORTS"
    run_ps "Get-NetTCPConnection -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Sort-Object LocalPort | Format-Table -AutoSize"
    echo

    echo "[8] STOPPED AUTOMATIC SERVICES"
    run_ps "Get-Service | Where-Object {\$_.StartType -eq 'Automatic' -and \$_.Status -ne 'Running'} | Select-Object Name,DisplayName,Status,StartType | Format-Table -AutoSize"
    echo

    echo "[9] RECENT SYSTEM ERRORS"
    run_ps "Get-WinEvent -LogName System -MaxEvents 20 | Where-Object {\$_.LevelDisplayName -eq 'Error'} | Select-Object TimeCreated,ProviderName,Message | Format-List"

  } | tee "$REPORT_FILE"
}

local_warnings() {
  section "LOCAL WARNING CHECKS"

  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
  $os = Get-CimInstance Win32_OperatingSystem
  $usedPercent = [math]::Round((($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100, 2)

  if ($usedPercent -gt 90) {
    Write-Output "WARNING: Memory usage is above 90%. This may cause paging, lag, and app slowdowns."
  } elseif ($usedPercent -gt 75) {
    Write-Output "NOTICE: Memory usage is above 75%. Worth watching."
  } else {
    Write-Output "Memory usage looks reasonable."
  }

  Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $freePercent = [math]::Round(($_.FreeSpace / $_.Size) * 100, 2)

    if ($freePercent -lt 10) {
      Write-Output ("WARNING: Drive " + $_.DeviceID + " has less than 10% free space.")
    } elseif ($freePercent -lt 20) {
      Write-Output ("NOTICE: Drive " + $_.DeviceID + " has less than 20% free space.")
    } else {
      Write-Output ("Drive " + $_.DeviceID + " free space looks okay.")
    }
  }
  '
}

ai_analysis() {
  section "OPENAI API ANALYSIS"

  if [ -z "$OPENAI_API_KEY" ]; then
    echo "OPENAI_API_KEY is not set."
    echo "Set it first inside Bash:"
    echo 'export OPENAI_API_KEY="your_key_here"'
    return
  fi

  if [ ! -f "$REPORT_FILE" ]; then
    echo "No report file found. Run this first:"
    echo "bash win-sentinel.sh --report"
    return
  fi

  cat > win-sentinel-ai.ps1 <<'EOF'

  param(
    [string]$apiKey
)

Write-Output "Sending report to OpenAI..."

# already passed in as parameter
$report = Get-Content "win-sentinel-report.txt" -Raw
if ($report.Length -gt 12000) {
  $report = $report.Substring(0, 12000)
}

$prompt = @"
You are a Windows operating systems tutor and performance analyst.

Analyze this Windows system report.

Return:
1. Plain-English summary
2. Likely slowdown causes
3. Process improvement suggestions
4. Startup programs to investigate
5. Memory, disk, service, and log concerns
6. OS concepts connected to each issue
7. Safe next commands
8. Things not to touch unless I understand them

Do not suggest disabling security tools.
Do not suggest deleting files blindly.
Do not suggest killing processes unless clearly justified.
Focus on safe, reversible improvements.

SYSTEM REPORT:
$report
"@

$body = @{
  model = "gpt-5-mini"
  input = $prompt
  max_output_tokens = 1200
  reasoning = @{
    effort = "low"
    }
} | ConvertTo-Json -Depth 5

$headers = @{
  Authorization = "Bearer $apiKey"
}

try {
  Write-Output "API key length: $($apiKey.Length)"
  Write-Output "Calling OpenAI API..."

  $response = Invoke-RestMethod `
    -Uri "https://api.openai.com/v1/responses" `
    -Method Post `
    -Headers $headers `
    -ContentType "application/json" `
    -Body $body `
    -TimeoutSec 30

  Write-Output "OpenAI response received."

  $text = $response.output | ForEach-Object {
    $_.content | ForEach-Object {
      if ($_.type -eq "output_text") {
        $_.text
      }
    }
  }

  if ($text) {
    Write-Output $text
  } else {
    Write-Output "No text extracted. Raw response:"
    $response | ConvertTo-Json -Depth 10
  }

}

catch {
  Write-Output "OpenAI API call failed."
  Write-Output $_.Exception.Message

  if ($_.ErrorDetails.Message) {
    Write-Output $_.ErrorDetails.Message
  }
}
EOF

  powershell.exe -NoProfile -ExecutionPolicy Bypass -File win-sentinel-ai.ps1 "$OPENAI_API_KEY"

  rm -f win-sentinel-ai.ps1
}

show_help() {
  echo "Win Sentinel"
  echo
  echo "Usage:"
  echo "  bash win-sentinel.sh"
  echo "  bash win-sentinel.sh --report"
  echo "  bash win-sentinel.sh --warnings"
  echo "  bash win-sentinel.sh --analyze"
  echo "  bash win-sentinel.sh --full-ai"
  echo
  echo "Options:"
  echo "  --report     Collect full Windows system report"
  echo "  --warnings   Run local warning checks"
  echo "  --analyze    Analyze existing report with OpenAI"
  echo "  --full-ai    Collect fresh report, run warnings, then analyze with OpenAI"
  echo "  --help       Show this help menu"
}

case "$1" in
  --report)
    collect_report
    ;;

  --warnings)
    local_warnings
    ;;

  --analyze)
    ai_analysis
    ;;

  --ai)
    ai_analysis
    ;;

  --full-ai)
    collect_report
    local_warnings
    ai_analysis
    ;;

  --help)
    show_help
    ;;

  *)
    collect_report
    local_warnings
    echo
    echo "Report saved to: $REPORT_FILE"
    echo "To analyze the existing report with OpenAI, run:"
    echo "bash win-sentinel.sh --analyze"
    echo
    echo "To collect a fresh report and analyze it, run:"
    echo "bash win-sentinel.sh --full-ai"
    ;;
esac
