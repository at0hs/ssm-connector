# NOTE: Windows PowerShell 5.1 の文字化け防止のため、このファイルは UTF-8 (BOM 付き) で保存すること。

#region State（純粋関数）
function Get-SsmcMenuFilteredIndex {
    param(
        [AllowEmptyCollection()][object[]]$Items = @(),
        [string]$Filter
    )
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ([string]::IsNullOrEmpty($Filter) -or $Items[$i].SearchText.IndexOf($Filter, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $i
        }
    }
}

function New-SsmcMenuState {
    return [pscustomobject]@{ Filter = ''; Cursor = 0; Top = 0; Action = 'None' }
}

function Update-SsmcMenuState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory)][string]$KeyName,
        [char]$KeyChar = [char]0,
        [Parameter(Mandatory)][int]$PageSize
    )
    $filter = $State.Filter
    $cursor = $State.Cursor
    $action = 'None'
    switch ($KeyName) {
        'UpArrow' { $cursor-- }
        'DownArrow' { $cursor++ }
        'PageUp' { $cursor -= $PageSize }
        'PageDown' { $cursor += $PageSize }
        'Home' { $cursor = 0 }
        'End' { $cursor = [int]::MaxValue }
        'Enter' { $action = 'Select' }
        'Escape' { $action = 'Cancel' }
        'Backspace' {
            if ($filter.Length -gt 0) {
                $filter = $filter.Substring(0, $filter.Length - 1)
                $cursor = 0
            }
        }
        default {
            if ($KeyChar -ne [char]0 -and -not [char]::IsControl($KeyChar)) {
                $filter += $KeyChar
                $cursor = 0
            }
        }
    }
    $count = @(Get-SsmcMenuFilteredIndex -Items $Items -Filter $filter).Count
    if ($count -eq 0) {
        $cursor = 0
        if ($action -eq 'Select') { $action = 'None' }
    } else {
        $cursor = [Math]::Max(0, [Math]::Min($cursor, $count - 1))
    }
    $top = $State.Top
    if ($cursor -lt $top) { $top = $cursor }
    if ($cursor -ge $top + $PageSize) { $top = $cursor - $PageSize + 1 }
    $top = [Math]::Max(0, [Math]::Min($top, [Math]::Max(0, $count - $PageSize)))
    return [pscustomobject]@{ Filter = $filter; Cursor = $cursor; Top = $top; Action = $action }
}

function Get-SsmcCharWidth {
    param([char]$Char)
    $code = [int]$Char
    # 東アジアの全角文字はコンソール上で 2 桁を占める
    if (($code -ge 0x1100 -and $code -le 0x115F) -or ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
        ($code -ge 0xAC00 -and $code -le 0xD7A3) -or ($code -ge 0xF900 -and $code -le 0xFAFF) -or
        ($code -ge 0xFE30 -and $code -le 0xFE4F) -or ($code -ge 0xFF00 -and $code -le 0xFF60) -or
        ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
        return 2
    }
    return 1
}

function Format-SsmcMenuText {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][int]$Width
    )
    $builder = [System.Text.StringBuilder]::new()
    $used = 0
    foreach ($char in $Text.ToCharArray()) {
        $charWidth = Get-SsmcCharWidth $char
        if ($used + $charWidth -gt $Width) { break }
        [void]$builder.Append($char)
        $used += $charWidth
    }
    return $builder.ToString() + (' ' * ($Width - $used))
}
#endregion

#region Render
function Test-SsmcInteractiveConsole {
    return ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected)
}

function Write-SsmcMenuLine {
    param(
        [int]$Row,
        [int]$Width,
        [AllowEmptyString()][string]$Text,
        [ConsoleColor]$Color = [Console]::ForegroundColor,
        [switch]$Inverse
    )
    [Console]::SetCursorPosition(0, $Row)
    $line = Format-SsmcMenuText -Text $Text -Width $Width
    if ($Inverse) {
        Write-Host $line -NoNewline -ForegroundColor ([Console]::BackgroundColor) -BackgroundColor ([Console]::ForegroundColor)
    } else {
        Write-Host $line -NoNewline -ForegroundColor $Color
    }
}

function Write-SsmcMenuFrame {
    param([int]$Origin, [string]$Title, [object[]]$Items, $State, [int]$PageSize)
    # 最終桁まで書くと折り返して表示が崩れるため 1 桁残す
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    $indexes = @(Get-SsmcMenuFilteredIndex -Items $Items -Filter $State.Filter)
    Write-SsmcMenuLine -Row $Origin -Width $width -Text "$Title  [↑↓:移動 Enter:決定 文字:絞り込み Esc:終了]" -Color Cyan
    Write-SsmcMenuLine -Row ($Origin + 1) -Width $width -Text " 絞り込み: $($State.Filter)_  ($($indexes.Count)/$($Items.Count) 件)"
    for ($row = 0; $row -lt $PageSize; $row++) {
        $position = $State.Top + $row
        $lineRow = $Origin + 2 + $row
        if ($position -ge $indexes.Count) {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text ''
            continue
        }
        $item = $Items[$indexes[$position]]
        if ($position -eq $State.Cursor) {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text " > $($item.Label)" -Inverse
        } elseif ($item.Dim) {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text "   $($item.Label)" -Color DarkGray
        } else {
            Write-SsmcMenuLine -Row $lineRow -Width $width -Text "   $($item.Label)"
        }
    }
}

function Show-SsmcMenu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items
    )
    if (-not (Test-SsmcInteractiveConsole)) { return (Show-SsmcNumberMenu -Title $Title -Items $Items) }
    $pageSize = [Math]::Max(1, [Math]::Min($Items.Count, [Console]::WindowHeight - 4))
    $lineCount = $pageSize + 2
    # 先に描画領域を確保してから、その先頭行を基準に描き直す
    for ($i = 0; $i -lt $lineCount; $i++) { [Console]::WriteLine() }
    $origin = [Console]::CursorTop - $lineCount
    $state = New-SsmcMenuState
    $cursorVisible = [Console]::CursorVisible
    try {
        [Console]::CursorVisible = $false
        while ($true) {
            Write-SsmcMenuFrame -Origin $origin -Title $Title -Items $Items -State $state -PageSize $pageSize
            $key = [Console]::ReadKey($true)
            $state = Update-SsmcMenuState -State $state -Items $Items -KeyName $key.Key.ToString() -KeyChar $key.KeyChar -PageSize $pageSize
            if ($state.Action -eq 'Cancel') { return $null }
            if ($state.Action -eq 'Select') {
                $indexes = @(Get-SsmcMenuFilteredIndex -Items $Items -Filter $state.Filter)
                return $Items[$indexes[$state.Cursor]].Value
            }
        }
    } finally {
        [Console]::CursorVisible = $cursorVisible
        [Console]::SetCursorPosition(0, $origin + $lineCount)
    }
}

function Show-SsmcNumberMenu {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][object[]]$Items
    )
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host (' [{0}] {1}' -f ($i + 1), $Items[$i].Label)
    }
    while ($true) {
        $answer = Read-Host "番号を入力してください (1-$($Items.Count), q:終了)"
        if ($answer -eq 'q') { return $null }
        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Items.Count) {
            return $Items[$number - 1].Value
        }
    }
}

function Read-SsmcConfirmation {
    param([Parameter(Mandatory)][string]$Message)
    $answer = Read-Host "$Message [y/N]"
    return ($answer -match '^(y|yes)$')
}
#endregion
