BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    . (Join-Path $PSScriptRoot 'helpers\Resolve-ArmTestExpression.ps1')
    $arm = Get-Content (Join-Path $repo 'src\mlz.json') -Raw | ConvertFrom-Json -AsHashtable
    $ui = Get-Content (Join-Path $repo 'src\mlz.uiDefinition.json') -Raw | ConvertFrom-Json -AsHashtable

    function Get-TestModule {
        param($Template, [string]$Prefix)
        $matches = @($Template.resources | Where-Object { $_.name -eq $Prefix -or $_.name -like "*'$Prefix*" })
        if ($matches.Count -ne 1) { throw "Expected one compiled module: $Prefix" }
        return $matches[0]
    }

    function New-ProfileContext {
        param([hashtable]$Overrides = @{})
        $parameters = @{}
        foreach ($tier in @('hub', 'operations', 'sharedServices', 'identity')) {
            $parameters["${tier}SubscriptionId"] = '00000000-0000-0000-0000-000000000001'
        }
        foreach ($key in $Overrides.Keys) { $parameters[$key] = $Overrides[$key] }
        return @{ Template = $arm; Parameters = $parameters }
    }

    $networkingModule = Get-TestModule $arm 'deploy-networking-'
    $networking = $networkingModule.properties.template
    $diagnosticModule = Get-TestModule $arm 'deploy-diagnostic-settings-'
    $diagnostics = $diagnosticModule.properties.template
    $storageModule = Get-TestModule $arm 'deploy-diag-storage-'
    $remoteModule = Get-TestModule $arm 'deploy-remote-access-'
    $addsModule = Get-TestModule $arm 'deploy-adds-'
}

Describe 'Compiled deployment profile topology' {
    It 'defaults to the private customer profile without changing the naming inputs' {
        $arm.parameters.deploymentProfile.defaultValue | Should -BeExactly 'customer-il2'
        $arm.parameters.deploymentProfile.allowedValues | Should -Be @('customer-il2', 'legacy')
        $context = New-ProfileContext
        $networks = Resolve-ArmTestExpression $arm.variables.activeNetworks $context
        $networks.name | Should -Be @('hub', 'operations')
        $networks.shortName | Should -Be @('hub', 'ops')
        $networkingModule.properties.parameters.networks.value | Should -BeExactly "[variables('activeNetworks')]"
        foreach ($name in @('identifier', 'environmentAbbreviation', 'location')) {
            $networkingModule.properties.parameters[$name].value | Should -BeExactly "[parameters('$name')]"
        }
    }

    It 'selects <Expected> for <Profile> with identity requested=<IdentityRequested>' -ForEach @(
        @{ Profile = 'customer-il2'; IdentityRequested = $false; Expected = @('hub', 'operations') }
        @{ Profile = 'customer-il2'; IdentityRequested = $true; Expected = @('hub', 'operations') }
        @{ Profile = 'legacy'; IdentityRequested = $false; Expected = @('hub', 'operations', 'sharedServices') }
        @{ Profile = 'legacy'; IdentityRequested = $true; Expected = @('hub', 'operations', 'sharedServices', 'identity') }
    ) {
        $context = New-ProfileContext @{ deploymentProfile = $Profile; deployIdentity = $IdentityRequested }
        $networks = Resolve-ArmTestExpression $arm.variables.activeNetworks $context
        $networks.name | Should -Be $Expected
        $networks[0].name | Should -BeExactly 'hub'
        $networks[1].name | Should -BeExactly 'operations'
        $networkContext = @{
            Template = $networking
            Parameters = @{
                networks = $networks
                deployIdentity = (Resolve-ArmTestExpression $arm.variables.effectiveDeployIdentity $context)
            }
        }
        $spokes = Resolve-ArmTestExpression $networking.variables.spokes $networkContext
        $spokes.name | Should -Be @($Expected | Where-Object { $_ -ne 'hub' })
        foreach ($loopName in @('spokeNetworks', 'hubVirtualNetworkPeerings', 'spokeVirtualNetworkPeerings')) {
            $loop = $networking.resources | Where-Object { $_.copy.name -eq $loopName }
            Resolve-ArmTestExpression $loop.copy.count $networkContext | Should -Be ($Expected.Count - 1)
        }
        $indexes = Resolve-ArmTestExpression $networking.variables.spokeIndexesByTier $networkContext
        foreach ($spoke in $spokes) { $spokes[$indexes[$spoke.name]].name | Should -BeExactly $spoke.name }
        Resolve-ArmTestExpression $networking.variables.hasIdentity $networkContext |
            Should -Be ($Profile -eq 'legacy' -and $IdentityRequested)
    }

    It 'ignores every blocked customer workload switch, including their credential defaults' {
        $context = New-ProfileContext @{
            deployIdentity = $true
            deployActiveDirectoryDomainServices = $true
            deployLinuxVirtualMachine = $true
            deployWindowsVirtualMachine = $true
        }
        foreach ($variable in @(
            'effectiveDeployIdentity', 'effectiveDeployActiveDirectoryDomainServices',
            'effectiveDeployLinuxVirtualMachine', 'effectiveDeployWindowsVirtualMachine'
        )) {
            Resolve-ArmTestExpression $arm.variables[$variable] $context | Should -BeFalse
        }
        (Resolve-ArmTestExpression $arm.variables.activeNetworks $context).name |
            Should -Be @('hub', 'operations')
        Resolve-ArmTestExpression $addsModule.condition $context | Should -BeFalse
        Resolve-ArmTestExpression $remoteModule.condition $context | Should -BeFalse
        (Resolve-ArmTestExpression $arm.outputs.domainControllerResourceIds.value $context).Count | Should -Be 0
        foreach ($parameter in @('linuxVmAdminPasswordOrKey', 'windowsVmAdminPassword')) {
            (Resolve-ArmTestExpression $arm.parameters[$parameter].defaultValue $context).Length |
                Should -BeGreaterOrEqual 12
        }
        $arm.outputs.domainControllerResourceIds.value | Should -Match "^.if\(variables\('effectiveDeployActiveDirectoryDomainServices'\)"
    }

    It 'preserves legacy ADDS and jump-box opt-ins, with ADDS still requiring Identity' {
        $context = New-ProfileContext @{
            deploymentProfile = 'legacy'
            deployIdentity = $true
            deployActiveDirectoryDomainServices = $true
            deployLinuxVirtualMachine = $true
            deployWindowsVirtualMachine = $true
        }
        Resolve-ArmTestExpression $addsModule.condition $context | Should -BeTrue
        Resolve-ArmTestExpression $remoteModule.condition $context | Should -BeTrue
        foreach ($name in @('deployLinuxVirtualMachine', 'deployWindowsVirtualMachine')) {
            Resolve-ArmTestExpression $remoteModule.properties.parameters[$name].value $context | Should -BeTrue
        }
        $context.Parameters.deployIdentity = $false
        Resolve-ArmTestExpression $addsModule.condition $context | Should -BeFalse
    }

    It 'allows customer Bastion without creating jump-box resource groups or CMK workloads' {
        $context = New-ProfileContext @{ deployBastion = $true; deployLinuxVirtualMachine = $true; deployWindowsVirtualMachine = $true }
        Resolve-ArmTestExpression $remoteModule.condition $context | Should -BeTrue
        $remoteContext = @{ Template = $remoteModule.properties.template; Parameters = @{} }
        foreach ($name in @('deployBastion', 'deployLinuxVirtualMachine', 'deployWindowsVirtualMachine')) {
            $remoteContext.Parameters[$name] = Resolve-ArmTestExpression $remoteModule.properties.parameters[$name].value $context
        }
        foreach ($resource in $remoteContext.Template.resources) {
            Resolve-ArmTestExpression $resource.condition $remoteContext |
                Should -Be ($resource.name -like '*deploy-ra-bastion-host*')
        }
        $cmk = Get-TestModule $storageModule.properties.template 'deploy-st-cmk-'
        $cmk.ContainsKey('condition') | Should -BeFalse
    }

    It 'returns the safe absent-tier output and keeps the historical legacy NSG-valued contract' {
        $networks = Resolve-ArmTestExpression $arm.variables.activeNetworks (New-ProfileContext)
        $context = @{ Template = $networking; Parameters = @{ networks = $networks } }
        Resolve-ArmTestExpression $networking.outputs.sharedServicesSubnetResourceId.value $context |
            Should -BeExactly ''
        $networking.outputs.sharedServicesSubnetResourceId.value | Should -Match 'outputs.networkSecurityGroupResourceId.value'
        $networking.outputs.sharedServicesSubnetResourceId.value | Should -Not -Match 'spokes\(\)\[[12]\]'
    }

    It 'passes the same active tier outputs into monitoring, storage, diagnostics, and security' {
        $tierExpression = $diagnosticModule.properties.parameters.tiers.value
        foreach ($prefix in @('deploy-diag-storage-', 'deploy-security-')) {
            (Get-TestModule $arm $prefix).properties.parameters.tiers.value | Should -BeExactly $tierExpression
        }
        $monitoringTier = (Get-TestModule $arm 'deploy-monitoring-').properties.parameters.tier.value
        $monitoringTier | Should -Match ([regex]::Escape($tierExpression.Substring(1, $tierExpression.Length - 2)))
        $monitoringTier = $monitoringTier.Replace(
            $tierExpression.Substring(1, $tierExpression.Length - 2), "parameters('tiers')"
        )
        (Resolve-ArmTestExpression $monitoringTier @{
            Template = $arm; Parameters = @{ tiers = @(@{ name = 'hub' }, @{ name = 'operations' }) }
        }).name | Should -BeExactly 'operations'
        foreach ($template in @($storageModule.properties.template, (Get-TestModule $arm 'deploy-security-').properties.template)) {
            foreach ($loop in @($template.resources | Where-Object { $_.ContainsKey('copy') })) {
                Resolve-ArmTestExpression $loop.copy.count @{ Template = $template; Parameters = @{ tiers = @('hub', 'operations') } } |
                    Should -Be 2
            }
        }
        foreach ($loopName in @('storageAccountDiagnosticSettings', 'virtualNetworkDiagnostics')) {
            $loop = $diagnostics.resources | Where-Object { $_.copy.name -eq $loopName }
            Resolve-ArmTestExpression $loop.copy.count @{ Template = $diagnostics; Parameters = @{ tiers = @('hub', 'operations') } } |
                Should -Be 2
        }
        $rgModule = Get-TestModule $networking 'deploy-resource-groups-'
        $rgLoop = $rgModule.properties.template.resources | Where-Object { $_.copy.name -eq 'resourceGroups' }
        Resolve-ArmTestExpression $rgLoop.copy.count @{
            Template = $rgModule.properties.template; Parameters = @{ tiers = @('hub', 'operations') }
        } | Should -Be 2
    }
}

Describe 'Explicit tier associations independent of generated resource names' {
    BeforeAll {
        $hubStorage = '/subscriptions/sub/resourceGroups/arbitrary-one/providers/Microsoft.Storage/storageAccounts/storeone'
        $opsStorage = '/subscriptions/sub/resourceGroups/arbitrary-two/providers/Microsoft.Storage/storageAccounts/storetwo'
        $diagnosticContext = @{
            Template = $diagnostics
            Parameters = @{
                tiers = @(@{ name = 'hub' }, @{ name = 'operations' })
                storageAccountResourceIds = @($hubStorage, $opsStorage)
            }
        }
    }

    It 'associates Operations diagnostics with Operations storage without parsing its name' {
        $mapping = Resolve-ArmTestExpression $diagnostics.variables.storageAccountsByTier $diagnosticContext
        $mapping.hub | Should -BeExactly $hubStorage
        $mapping.operations | Should -BeExactly $opsStorage
        $law = Get-TestModule $diagnostics 'deploy-law-diag-'
        Resolve-ArmTestExpression $law.properties.parameters.diagnosticStorageAccountName.value $diagnosticContext |
            Should -BeExactly 'storetwo'
        $kv = $diagnostics.resources | Where-Object { $_.copy.name -eq 'keyVaultDiagnosticSettings' }
        $kv.properties.parameters.keyVaultStorageAccountId.value | Should -Match "storageAccountsByTier.*tierName"
    }

    It 'resolves a renamed <ExpectedTier> NIC by case-insensitive authoritative subnet ID' -ForEach @(
        @{ TierIndex = 0; ExpectedTier = 'hub' }
        @{ TierIndex = 1; ExpectedTier = 'operations' }
        @{ TierIndex = 2; ExpectedTier = 'sharedServices' }
        @{ TierIndex = 3; ExpectedTier = 'identity' }
    ) {
        $nic = ($diagnostics.resources | Where-Object { $_.copy.name -eq 'networkInterfaceDiagnostics' }).properties.template
        $resourceModule = Get-TestModule $nic 'deploy-nic-diag-'
        $resourceModule.name | Should -Match "uniqueString\(parameters\('networkInterfaceResourceId'\)\)"
        # Substitute only the Azure GET result; evaluate the actual compiled ownership expression.
        $reference = "reference(resourceId('Microsoft.Network/networkInterfaces', split(parameters('networkInterfaceResourceId'), '/')[8]), '2021-02-01')"
        $tiers = @('hub', 'operations', 'sharedServices', 'identity') | ForEach-Object {
            @{
                name = $_
                subnetResourceId = "/subscriptions/sub/resourceGroups/opaque/providers/Microsoft.Network/virtualNetworks/custom/subnets/$_"
                namingConvention = @{ virtualMachineNetworkInterfaceDiagnosticSetting = "$_-nic-diag-purpose_token" }
            }
        }
        $storageIds = @($hubStorage, $opsStorage, '/storage-shared', '/storage-identity')
        $context = @{
            Template = $nic
            Parameters = @{
                tiers = $tiers; actualSubnetId = $tiers[$TierIndex].subnetResourceId.ToUpperInvariant()
                storageAccountResourceIds = $storageIds
                delimiter = '-'; tokens = @{ purpose = 'purpose_token' }
            }
        }
        $storageExpression = $resourceModule.properties.parameters.storageAccountId.value
        $diagnosticExpression = $resourceModule.properties.parameters.diagnosticSettingName.value
        $lookup = "$reference.ipConfigurations[0].properties.subnet.id"
        $storageExpression | Should -Match ([regex]::Escape($lookup))
        $storageExpression = $storageExpression.Replace($lookup, "parameters('actualSubnetId')")
        $diagnosticExpression = $diagnosticExpression.Replace($lookup, "parameters('actualSubnetId')")
        Resolve-ArmTestExpression $storageExpression $context |
            Should -BeExactly $storageIds[$TierIndex]
        Resolve-ArmTestExpression $diagnosticExpression $context |
            Should -BeExactly "$ExpectedTier-nic-diag"
        $context.Parameters.actualSubnetId = '/unknown-subnet'
        { Resolve-ArmTestExpression $storageExpression $context } | Should -Throw '*Invalid ARM index*'
    }

    It 'keeps Operations storage associated when tier/storage pairs are reordered' {
        $context = @{
            Template = $diagnostics
            Parameters = @{
                tiers = @(@{ name = 'operations' }, @{ name = 'hub' })
                storageAccountResourceIds = @($opsStorage, $hubStorage)
            }
        }
        $law = Get-TestModule $diagnostics 'deploy-law-diag-'
        Resolve-ArmTestExpression $law.properties.parameters.diagnosticStorageAccountName.value $context |
            Should -BeExactly 'storetwo'
    }

    It 'has no generated-name tier parsing or fixed optional-spoke indices' {
        foreach ($path in @('networking.bicep', 'diagnostic-settings.bicep', 'network-interface-diagnostic-setting.bicep')) {
            $source = Get-Content (Join-Path $repo "src\modules\$path") -Raw
            $source | Should -Not -Match "contains\([^\r\n]*'-(ops|svcs|id)-'"
            $source | Should -Not -Match 'spokeNetworks\[[12]\]'
        }

        $source = Get-Content (Join-Path $repo 'src\modules\networking.bicep') -Raw
        $source | Should -Not -Match "contains\(name,.*(hub|operations|sharedServices|identity)"
        $source | Should -Match 'resourceGroups.outputs.tiers'
    }
}

Describe 'ARM topology test evaluator guardrails' {
    It 'evaluates only the selected branch and rejects unsupported functions' {
        Resolve-ArmTestExpression "[if(true(), 'selected', unsupported())]" @{} | Should -BeExactly 'selected'
        { Resolve-ArmTestExpression '[unsupported()]' @{} } | Should -Throw '*Unsupported ARM test function*'
        { Resolve-ArmTestExpression "[createArray('one')[-1]]" @{} } | Should -Throw '*Invalid ARM index*'
    }
}

Describe 'Deployment profile portal controls' {
    It 'defaults to customer-il2 and offers an explicit legacy profile' {
        $basics = $ui.view.properties.steps | Where-Object name -eq 'basics'
        $profile = $basics.elements | Where-Object name -eq 'deploymentProfile'
        $profile.defaultValue | Should -BeExactly 'customer-il2'
        $profile.constraints.allowedValues.value | Should -Be @('customer-il2', 'legacy')
        $ui.view.outputs.parameters.deploymentProfile | Should -BeExactly "[steps('basics').deploymentProfile]"
    }

    It 'hides unsupported tiers and workloads and gates stale output selections' {
        foreach ($section in @(
            @{ Step = 'basics'; Element = 'identitySection' },
            @{ Step = 'basics'; Element = 'sharedServicesSection' },
            @{ Step = 'networking'; Element = 'identityVirtualNetwork' },
            @{ Step = 'networking'; Element = 'sharedServicesVirtualNetwork' },
            @{ Step = 'identity'; Element = 'addsSection' },
            @{ Step = 'identity'; Element = 'forestSection' },
            @{ Step = 'identity'; Element = 'vmSection' },
            @{ Step = 'remoteAccess'; Element = 'linuxVmSection' },
            @{ Step = 'remoteAccess'; Element = 'windowsVmSection' }
        )) {
            $step = $ui.view.properties.steps | Where-Object name -eq $section.Step
            ($step.elements | Where-Object name -eq $section.Element).visible |
                Should -Match "equals\(steps\('basics'\).deploymentProfile, 'legacy'\)"
        }
        foreach ($name in @('deployIdentity', 'deployActiveDirectoryDomainServices', 'deployLinuxVirtualMachine', 'deployWindowsVirtualMachine')) {
            $ui.view.outputs.parameters[$name] | Should -Match "equals\(steps\('basics'\).deploymentProfile, 'legacy'\)"
        }
        foreach ($name in @('linuxVmAdminPasswordOrKey', 'windowsVmAdminPassword')) {
            $ui.view.outputs.parameters[$name] | Should -Match ', guid\(\)\)\]$'
        }
    }
}
