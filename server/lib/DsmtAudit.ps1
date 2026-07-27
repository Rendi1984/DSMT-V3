<#
.SYNOPSIS
    DSMT - the audit log.
.DESCRIPTION
    Every write the console performs is appended here, successful or not,
    with the operator, the domain controller that served the change, the
    mandatory reason string and the result. Records are JSON, one object per
    line (JSONL), in data\audit-YYYY-MM.jsonl - append-only, trivially
    greppable, and safe to ship to a SIEM.

    These records are the real ones: they describe changes this console
    actually attempted against the directory. Nothing here is generated for
    display purposes.
.NOTES
    Author  : IT Team
#>

function Get-DsmtAuditPath {
    param([datetime] $When = (Get-Date))

    $cfg = Get-DsmtConfig
    return Join-Path $cfg.DataPath ('audit-' + $When.ToString('yyyy-MM') + '.jsonl')
}

function Write-DsmtAudit {
    <#
    .SYNOPSIS
        Appends one audit record.
    .PARAMETER Result
        Success | Partial | Failed | Denied
    .PARAMETER Category
        user | group | session - drives the audit view's filter chips.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Action,
        [Parameter(Mandatory = $true)][string] $Target,
        [Parameter(Mandatory = $true)][string] $Operator,
        [Parameter(Mandatory = $true)][string] $Reason,
        [Parameter(Mandatory = $true)][ValidateSet('Success', 'Partial', 'Failed', 'Denied')][string] $Result,
        [ValidateSet('user', 'group', 'session')][string] $Category = 'user',
        [string] $Controller = '',
        [string] $Detail = ''
    )

    $cfg = Get-DsmtConfig
    $now = Get-Date

    $record = [ordered]@{
        time       = $now.ToString('yyyy-MM-ddTHH:mm:ssK')
        action     = $Action
        target     = $Target
        operator   = $Operator
        dc         = $Controller
        reason     = $Reason
        result     = $Result
        category   = $Category
        detail     = $Detail
        version    = $cfg.Version
    }

    # SQL is the primary store when it is configured; the JSONL file is
    # written either way so an audit record is never lost to a SQL outage.
    Write-DsmtSqlAudit -TimeUtc $now.ToUniversalTime() -Action $Action -Target $Target `
                       -Operator $Operator -Reason $Reason -Result $Result -Category $Category `
                       -Controller $Controller -Detail $Detail | Out-Null

    $line = ConvertTo-Json -InputObject $record -Depth 4 -Compress
    $path = Get-DsmtAuditPath -When $now

    # Retry briefly: two operators can commit at the same moment and the
    # append must not be lost.
    $attempt = 0
    while ($attempt -lt 5) {
        try {
            Add-Content -LiteralPath $path -Value $line -Encoding UTF8 -ErrorAction Stop
            return
        } catch {
            $attempt++
            Start-Sleep -Milliseconds 80
        }
    }

    Write-DsmtLog -Level 'ERROR' -Message ('AUDIT WRITE FAILED, record follows: ' + $line)
}

function Get-DsmtAuditEntries {
    <#
    .SYNOPSIS
        Reads audit records back, newest first, with the same filters the
        audit view offers.
    .PARAMETER Filter
        All | Users | Groups | Passwords | Deletions
    #>
    param(
        [string] $Query = '',
        [string] $Filter = 'All',
        [int]    $Months = 6,
        [int]    $Limit = 500
    )

    # When SQL is configured it is the record of truth for the audit view.
    # The JSONL path below is used only when SQL is off or unreachable, and
    # the caller is told which store answered.
    $sql = Get-DsmtSqlState
    if ($sql.Enabled) {
        try {
            $fromSql = Get-DsmtSqlAudit -Query $Query -Filter $Filter -Limit $Limit
            $fromSql['source'] = 'sql'
            return $fromSql
        } catch {
            Write-DsmtLog -Level 'WARN' -Message ('Audit read from SQL failed, falling back to the file log: ' + $_.Exception.Message)
        }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    $now = Get-Date

    for ($i = 0; $i -lt $Months; $i++) {
        $path = Get-DsmtAuditPath -When $now.AddMonths(-$i)
        if (-not (Test-Path -LiteralPath $path)) { continue }

        $lines = @()
        try {
            $lines = Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-DsmtLog -Level 'WARN' -Message ('Could not read audit file ' + $path + ': ' + $_.Exception.Message)
            continue
        }

        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entries.Add((ConvertFrom-Json -InputObject $line -ErrorAction Stop))
            } catch {
                Write-DsmtLog -Level 'WARN' -Message ('Skipping malformed audit line in ' + $path)
            }
        }
    }

    $q = ''
    if (-not [string]::IsNullOrWhiteSpace($Query)) { $q = $Query.Trim().ToLower() }

    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        $keep = $true

        switch ($Filter) {
            'Users'      { if ($e.category -ne 'user')  { $keep = $false } }
            'Groups'     { if ($e.category -ne 'group') { $keep = $false } }
            'Passwords'  { if ($e.action -notmatch '(?i)password') { $keep = $false } }
            'Deletions'  { if ($e.action -notmatch '(?i)delet')    { $keep = $false } }
            default      { }
        }

        if ($keep -and $q) {
            $hay = ($e.action + ' ' + $e.target + ' ' + $e.operator + ' ' + $e.dc + ' ' + $e.reason + ' ' + $e.result + ' ' + $e.detail).ToLower()
            if ($hay -notlike ('*' + $q + '*')) { $keep = $false }
        }

        if ($keep) { $filtered.Add($e) }
    }

    $sorted = $filtered | Sort-Object -Property time -Descending
    $total  = @($sorted).Count
    $page   = @($sorted) | Select-Object -First $Limit

    return @{
        entries = @($page)
        total   = $total
        source  = 'file'
    }
}
