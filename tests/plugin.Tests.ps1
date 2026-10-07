#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# The Claude Code plugin manifests in .claude-plugin/. CI also runs `claude plugin validate`.
Describe 'Claude Code plugin' {
    BeforeAll {
        $root = Join-Path $PSScriptRoot '..'
        $plugin = Get-Content -Raw (Join-Path $root '.claude-plugin/plugin.json') | ConvertFrom-Json
        $marketplace = Get-Content -Raw (Join-Path $root '.claude-plugin/marketplace.json') | ConvertFrom-Json
    }

    It 'has the same version as the module manifest' {
        $moduleVersion = (Import-PowerShellDataFile (Join-Path $root 'azswap/azswap.psd1')).ModuleVersion
        $plugin.version | Should -Be $moduleVersion
    }

    It 'lists the plugin in its own marketplace' {
        $marketplace.name | Should -Be 'azswap'
        $marketplace.owner.name | Should -Not -BeNullOrEmpty
        $entry = @($marketplace.plugins | Where-Object name -EQ $plugin.name)
        $entry.Count | Should -Be 1
        $entry[0].source | Should -Be './'
    }

    It 'points at every skill folder in the repo' {
        $plugin.skills | Should -Contain './skill/'
        foreach ($skill in Get-ChildItem (Join-Path $root 'skill') -Directory) {
            Join-Path $skill.FullName 'SKILL.md' | Should -Exist
        }
    }
}
