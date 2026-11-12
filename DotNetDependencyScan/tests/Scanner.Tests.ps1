# Pester 5 tests for the scanner's parsing and roll-forward logic.
# Run from the repository root:  Invoke-Pester ./tests
# These only exercise the pure functions, so they also run under pwsh on Linux/macOS.

BeforeAll {
    . (Join-Path $PSScriptRoot '../src/Invoke-DotNetDependencyScan.ps1')

    function New-Runtime([string]$Version, [string]$Architecture = 'x64', [string]$Framework = 'Microsoft.NETCore.App') {
        [pscustomobject]@{ FrameworkName = $Framework; Version = $Version; Architecture = $Architecture }
    }
    function Get-Dependency([string]$Json) {
        Get-RuntimeConfigInfo -Path 'C:\Program Files\Contoso\Contoso.Agent.runtimeconfig.json' -Content $Json
    }
}

Describe 'Get-RuntimeConfigInfo' {
    It 'reads a single framework, keeps dotted app names whole and defaults rollForward to Minor' {
        $r = Get-Dependency '{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
        $r.AppName | Should -Be 'Contoso.Agent'
        $r.AppFolder | Should -Be 'C:\Program Files\Contoso'
        $r.FrameworkName | Should -Be 'Microsoft.NETCore.App'
        $r.RequestedVersion | Should -Be '8.0.0'
        $r.RequestedMajor | Should -Be 8
        $r.Tfm | Should -Be 'net8.0'
        $r.RollForward | Should -Be 'Minor'
        $r.AllowsMajorRollForward | Should -BeFalse
        $r.SelfContained | Should -BeFalse
    }

    It 'returns one record per entry in frameworks[]' {
        $r = @(Get-Dependency '{"runtimeOptions":{"frameworks":[{"name":"Microsoft.NETCore.App","version":"8.0.0"},{"name":"Microsoft.WindowsDesktop.App","version":"8.0.0"}]}}')
        $r.Count | Should -Be 2
        $r.FrameworkName | Should -Be @('Microsoft.NETCore.App', 'Microsoft.WindowsDesktop.App')
    }

    It 'treats includedFrameworks as self-contained' {
        $r = Get-Dependency '{"runtimeOptions":{"includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"8.0.11"}]}}'
        $r.SelfContained | Should -BeTrue
        $r.RollForward | Should -Be ''
    }

    It 'prefers a framework-level rollForward over the app-wide one' {
        $r = @(Get-Dependency '{"runtimeOptions":{"rollForward":"Major","frameworks":[{"name":"Microsoft.NETCore.App","version":"8.0.0"},{"name":"Microsoft.AspNetCore.App","version":"8.0.0","rollForward":"LatestPatch"}]}}')
        $r[0].RollForward | Should -Be 'Major'
        $r[0].AllowsMajorRollForward | Should -BeTrue
        $r[1].RollForward | Should -Be 'LatestPatch'
    }

    It 'normalises rollForward casing' {
        (Get-Dependency '{"runtimeOptions":{"rollForward":"latestmajor","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}').RollForward |
            Should -Be 'LatestMajor'
    }

    It 'maps legacy rollForwardOnNoCandidateFx=<Value> applyPatches=<Patches> to <Expected>' -ForEach @(
        @{ Value = 2; Patches = 'null'; Expected = 'Major' }
        @{ Value = 1; Patches = 'null'; Expected = 'Minor' }
        @{ Value = 0; Patches = 'null'; Expected = 'LatestPatch' }
        @{ Value = 0; Patches = 'false'; Expected = 'Disable' }
    ) {
        $json = '{"runtimeOptions":{"rollForwardOnNoCandidateFx":' + $Value + ',"applyPatches":' + $Patches +
            ',"framework":{"name":"Microsoft.NETCore.App","version":"6.0.0"}}}'
        (Get-Dependency $json).RollForward | Should -Be $Expected
    }

    It 'applies DOTNET_ROLL_FORWARD only when the app sets nothing' {
        $none = '{"runtimeOptions":{"framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
        $own = '{"runtimeOptions":{"rollForward":"Disable","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
        (Get-RuntimeConfigInfo -Path 'C:\a\A.runtimeconfig.json' -Content $none -EnvRollForward 'LatestMajor').RollForward | Should -Be 'LatestMajor'
        (Get-RuntimeConfigInfo -Path 'C:\a\A.runtimeconfig.json' -Content $own -EnvRollForward 'LatestMajor').RollForward | Should -Be 'Disable'
    }

    It 'reports malformed JSON as a parse error instead of throwing' {
        $r = Get-Dependency '{"runtimeOptions": {'
        $r.ParseError | Should -Not -BeNullOrEmpty
    }

    It 'returns nothing when there is no framework reference' {
        Get-Dependency '{"runtimeOptions":{"configProperties":{}}}' | Should -BeNullOrEmpty
    }
}

Describe 'Select-FrameworkVersion' {
    BeforeAll {
        $installed = '8.0.11', '8.0.31', '8.1.2', '9.0.10', '10.0.0', '10.0.12', '11.0.0-preview.1.25000.1'
    }

    It '<Requested> with <Policy> (excluding major <Exclude>) resolves to <Expected>' -ForEach @(
        @{ Requested = '8.0.0';  Policy = 'Minor';       Exclude = -1; Expected = '8.0.31' }
        @{ Requested = '8.0.0';  Policy = 'LatestPatch'; Exclude = -1; Expected = '8.0.31' }
        @{ Requested = '8.0.0';  Policy = 'LatestMinor'; Exclude = -1; Expected = '8.1.2' }
        @{ Requested = '8.0.0';  Policy = 'Major';       Exclude = -1; Expected = '8.0.31' }
        @{ Requested = '8.0.0';  Policy = 'LatestMajor'; Exclude = -1; Expected = '10.0.12' }
        @{ Requested = '8.0.11'; Policy = 'Disable';     Exclude = -1; Expected = '8.0.11' }
        @{ Requested = '8.0.5';  Policy = 'Disable';     Exclude = -1; Expected = $null }
        @{ Requested = '8.2.0';  Policy = 'Minor';       Exclude = -1; Expected = $null }
        @{ Requested = '7.0.0';  Policy = 'Minor';       Exclude = -1; Expected = $null }
        @{ Requested = '7.0.0';  Policy = 'Major';       Exclude = -1; Expected = '8.0.31' }
        @{ Requested = '8.0.0';  Policy = 'Minor';       Exclude = 8;  Expected = $null }
        @{ Requested = '8.0.0';  Policy = 'Major';       Exclude = 8;  Expected = '9.0.10' }
        @{ Requested = '8.0.0';  Policy = 'LatestMajor'; Exclude = 10; Expected = '9.0.10' }
        @{ Requested = '11.0.0-preview.1.25000.1'; Policy = 'Minor'; Exclude = -1; Expected = '11.0.0-preview.1.25000.1' }
    ) {
        $actual = Select-FrameworkVersion -RequestedVersion $Requested -RollForward $Policy -Available $installed -ExcludeMajor $Exclude
        if ($null -eq $Expected) { $actual | Should -BeNullOrEmpty } else { $actual | Should -Be $Expected }
    }
}

Describe 'Resolve-FrameworkDependency' {
    It 'marks a default (Minor) app as Pinned to the major it runs on' {
        $d = Get-Dependency '{"runtimeOptions":{"framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
        Resolve-FrameworkDependency -Dependency $d -InstalledRuntime (New-Runtime '8.0.31'), (New-Runtime '10.0.12') -Architecture x64
        $d.ResolvedVersion | Should -Be '8.0.31'
        $d.ResolvedMajor | Should -Be 8
        $d.Verdict | Should -Be 'Pinned'
    }

    It 'says NeedsNewerMajor when Major roll-forward is allowed but nothing newer is installed' {
        $d = Get-Dependency '{"runtimeOptions":{"rollForward":"Major","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
        Resolve-FrameworkDependency -Dependency $d -InstalledRuntime (New-Runtime '8.0.31') -Architecture x64
        $d.Verdict | Should -Be 'NeedsNewerMajor'
    }

    It 'says RollsForward, with the fallback version, when a newer major is installed' {
        $d = Get-Dependency '{"runtimeOptions":{"rollForward":"Major","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
        Resolve-FrameworkDependency -Dependency $d -InstalledRuntime (New-Runtime '8.0.31'), (New-Runtime '10.0.12') -Architecture x64
        $d.ResolvedVersion | Should -Be '8.0.31'
        $d.FallbackVersion | Should -Be '10.0.12'
        $d.Verdict | Should -Be 'RollsForward'
    }

    It 'attributes a LatestMajor app to the newest major, not the one it asked for' {
        $d = Get-Dependency '{"runtimeOptions":{"rollForward":"LatestMajor","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}'
        Resolve-FrameworkDependency -Dependency $d -InstalledRuntime (New-Runtime '8.0.31'), (New-Runtime '10.0.12') -Architecture x64
        $d.ResolvedMajor | Should -Be 10
        $d.FallbackVersion | Should -Be '8.0.31'
    }

    It 'ignores installed runtimes when the app is self-contained' {
        $d = Get-Dependency '{"runtimeOptions":{"includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"8.0.11"}]}}'
        Resolve-FrameworkDependency -Dependency $d -InstalledRuntime @() -Architecture x64
        $d.Verdict | Should -Be 'SelfContained'
    }

    It 'only matches runtimes of the same framework and architecture' {
        $d = Get-Dependency '{"runtimeOptions":{"framework":{"name":"Microsoft.WindowsDesktop.App","version":"8.0.0"}}}'
        $runtimes = (New-Runtime '8.0.31' 'x64' 'Microsoft.WindowsDesktop.App'), (New-Runtime '8.0.31' 'x86' 'Microsoft.NETCore.App')
        Resolve-FrameworkDependency -Dependency $d -InstalledRuntime $runtimes -Architecture x86
        $d.Verdict | Should -Be 'Unresolved'
    }
}
