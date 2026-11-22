# PSScriptAnalyzer settings for twinbar.ps1 and the tests (CI runs them; see
# tests/smoke.ps1). All rules with Warning or Error severity apply, except:
@{
  Severity     = @('Error', 'Warning')
  ExcludeRules = @(
    # Get-AllProfiles, Find-ElectronApps... return several things and read better plural.
    'PSUseSingularNouns',
    # These are the script's own helpers, not cmdlets: the commands check, refuse
    # and use the Recycle Bin themselves instead of -WhatIf/-Confirm.
    'PSUseShouldProcessForStateChangingFunctions',
    # The tests print coloured ok/FAIL lines.
    'PSAvoidUsingWriteHost',
    # WinForms event handlers receive (sender, event arguments) whether they use them or not.
    'PSReviewUnusedParameter'
  )
}
