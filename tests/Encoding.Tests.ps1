BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    # 5.1 では -LiteralPath と -Include の併用で全ファイルが対象になるため、拡張子で絞り込む
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Extension -in '.ps1', '.psm1' } |
        ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } })
}

Describe 'ファイルの文字コード' {
    It '<Name> は UTF-8 (BOM 付き) で保存されている' -ForEach $files {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        ($bytes[0..2] -join ',') | Should -Be '239,187,191'
    }
}
