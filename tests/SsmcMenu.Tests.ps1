BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\lib\SsmcMenu.psm1') -Force
    function New-TestItems {
        param([int]$Count)
        foreach ($i in 1..$Count) {
            $name = 'srv{0:D2}' -f $i
            [pscustomobject]@{ Label = $name; SearchText = "$name i-$i 10.0.0.$i"; Dim = $false; Value = $name }
        }
    }
    function Invoke-Keys {
        param($Items, [string[]]$Keys, [int]$PageSize = 5)
        $state = New-SsmcMenuState
        foreach ($key in $Keys) {
            if ($key.Length -eq 1) {
                $state = Update-SsmcMenuState -State $state -Items $Items -KeyName 'A' -KeyChar $key -PageSize $PageSize
            } else {
                $state = Update-SsmcMenuState -State $state -Items $Items -KeyName $key -PageSize $PageSize
            }
        }
        return $state
    }
}

Describe 'Get-SsmcMenuFilteredIndex' {
    It '絞り込み文字列が空ならすべての添字を返す' {
        @(Get-SsmcMenuFilteredIndex -Items @(New-TestItems 3) -Filter '').Count | Should -Be 3
    }
    It 'SearchText を大文字小文字を区別せずに部分一致で絞り込む' {
        (@(Get-SsmcMenuFilteredIndex -Items @(New-TestItems 12) -Filter 'SRV1') -join ',') | Should -Be '9,10,11'
    }
    It 'IP でも絞り込める' {
        (@(Get-SsmcMenuFilteredIndex -Items @(New-TestItems 3) -Filter '10.0.0.2') -join ',') | Should -Be '1'
    }
}

Describe 'Update-SsmcMenuState' {
    BeforeAll { $items = @(New-TestItems 12) }
    It '下矢印で移動し、末尾で止まる' {
        (Invoke-Keys $items @('DownArrow', 'DownArrow')).Cursor | Should -Be 2
        (Invoke-Keys $items (@('DownArrow') * 20)).Cursor | Should -Be 11
    }
    It '上矢印で移動し、先頭で止まる' {
        (Invoke-Keys $items @('UpArrow')).Cursor | Should -Be 0
    }
    It 'PageDown / PageUp で 1 ページ分移動する' {
        (Invoke-Keys $items @('PageDown')).Cursor | Should -Be 5
        (Invoke-Keys $items @('PageDown', 'PageDown', 'PageUp')).Cursor | Should -Be 5
    }
    It 'End / Home で末尾・先頭へ移動する' {
        (Invoke-Keys $items @('End')).Cursor | Should -Be 11
        (Invoke-Keys $items @('End', 'Home')).Cursor | Should -Be 0
    }
    It 'カーソルが表示範囲を超えたらスクロールする' {
        $state = Invoke-Keys $items (@('DownArrow') * 6)
        $state.Cursor | Should -Be 6
        $state.Top | Should -Be 2
        (Invoke-Keys $items @('End')).Top | Should -Be 7
    }
    It '文字入力で絞り込み、カーソルを先頭に戻す' {
        $state = Invoke-Keys $items @('DownArrow', 'DownArrow', '1')
        $state.Filter | Should -Be '1'
        $state.Cursor | Should -Be 0
        $state.Top | Should -Be 0
    }
    It 'Backspace で 1 文字消す' {
        (Invoke-Keys $items @('s', 'r', 'Backspace')).Filter | Should -Be 's'
    }
    It 'Enter で Select になる' {
        (Invoke-Keys $items @('Enter')).Action | Should -Be 'Select'
    }
    It '該当がなければ Enter しても Select にならない' {
        (Invoke-Keys $items @('z', 'z', 'Enter')).Action | Should -Be 'None'
    }
    It 'Escape で Cancel になる' {
        (Invoke-Keys $items @('Escape')).Action | Should -Be 'Cancel'
    }
}

Describe 'Format-SsmcMenuText' {
    It '幅に足りない分を空白で埋める' {
        Format-SsmcMenuText -Text 'abc' -Width 5 | Should -Be 'abc  '
    }
    It '全角文字を幅 2 として切り詰める' {
        Format-SsmcMenuText -Text 'あいう' -Width 5 | Should -Be 'あい '
    }
}

Describe 'Show-SsmcMenu（番号入力方式）' {
    BeforeEach {
        Mock -ModuleName SsmcMenu Write-Host { }
    }
    It 'コンソールでなければ番号入力方式に切り替える' {
        Mock -ModuleName SsmcMenu Test-SsmcInteractiveConsole { $false }
        Mock -ModuleName SsmcMenu Show-SsmcNumberMenu { 'picked' }
        Show-SsmcMenu -Title 't' -Items @(New-TestItems 2) | Should -Be 'picked'
    }
    It '番号で選んだ項目の Value を返す（不正な入力は聞き直す）' {
        $answers = [System.Collections.Queue]::new(@('x', '9', '2'))
        Mock -ModuleName SsmcMenu Read-Host { $answers.Dequeue() }
        Show-SsmcNumberMenu -Title 't' -Items @(New-TestItems 3) | Should -Be 'srv02'
        Should -Invoke -ModuleName SsmcMenu Read-Host -Times 3 -Exactly
    }
    It 'q で $null を返す' {
        Mock -ModuleName SsmcMenu Read-Host { 'q' }
        Show-SsmcNumberMenu -Title 't' -Items @(New-TestItems 3) | Should -BeNullOrEmpty
    }
}

Describe 'Read-SsmcConfirmation' {
    It 'y なら true' {
        Mock -ModuleName SsmcMenu Read-Host { 'y' }
        Read-SsmcConfirmation -Message '接続しますか？' | Should -BeTrue
    }
    It '空入力なら false' {
        Mock -ModuleName SsmcMenu Read-Host { '' }
        Read-SsmcConfirmation -Message '接続しますか？' | Should -BeFalse
    }
}
