#Requires -Version 3
param([string] $DefaultVaultPath)
Set-StrictMode -Version 2
$errorActionPreference = 'Stop'
$home = if($env:USERPROFILE){ $env:USERPROFILE } else { $env:HOME }
if(-not $DefaultVaultPath) {
    $DefaultVaultPath =
        if (Test-Path "$home/Dropbox/1Password/1Password.agilekeychain"){ "$home/Dropbox/1Password/1Password.agilekeychain" }
        elseif (Test-Path "$home/Dropbox/1Password/1Password.opvault") { "$home/Dropbox/1Password/1Password.opvault" }
        else { Write-Warning "Unable to auto-detect a 1Password vault location. Use Set-1PDefaultVaultPath to set a default." }
}
# Add-Type is very slow, prefer Powershell types.
# Sadly, these declarations need to be in the primary module file
# due to limitations on usage of Powershell types
if($PSVersionTable.PSVersion -ge '5.0.0') {
    class Entry {
        [string] $Name
        [string] $Id
        [string] $VaultPath
        [string] $SecurityLevel
        [string] $KeyId
        [string] $KeyData
        [string] $Location
        [string] $Type
        [DateTime] $CreatedAt
        [DateTime] $LastUpdated
        [string] $EncryptedData
        [string] ToString() { return $this.Name }
    }
} else {
    Add-Type -ea 0 @'
    public class Entry {
        public string Name;
        public string Id;
        public string VaultPath;
        public string SecurityLevel;
        public string KeyId;
        public string KeyData;
        public string Location;
        public string Type;
        public System.DateTime CreatedAt;
        public System.DateTime LastUpdated;
        public string EncryptedData;
        public override string ToString() {
           return Name;
        }
     }
'@
}

. $psScriptRoot/lib.ps1

<#
.SYNOPSIS
Sets the default 1Password vault directory to a new value.

.DESCRIPTION
Sets the default 1Password vault directory to a new value. The 1Password vault at this location
will be used by other 1Poshword cmdlets unless otherwise specified.

.PARAMETER Path
Specifies the root directory of the default 1Password vault. This is the ".agilekeychain" or
".opvault" directory.

.EXAMPLE
PS ~$ Set-1PDefaultVaultPath /Users/calvin/Dropbox/OtherVault.agilekeychain

.EXAMPLE
PS ~$ Set-1PDefaultVaultPath /Users/calvin/Dropbox/OtherVault.opvault
#>
function Set-1PDefaultVaultPath {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ (Test-Path $_ -PathType Container) -and ($_ -match '\.(agilekeychain|opvault)(/|\\)?$') })]
        [string] $Path
    )

    if ($psCmdlet.ShouldProcess($path)) {
        $script:DefaultVaultPath = (Resolve-Path $path).Path
    }
}

<#
.SYNOPSIS
Gets the default 1Password root directory.

.DESCRIPTION
Gets the default 1Password root directory. The 1Password vault at this location
will be used by all other 1Poshword cmdlets unless otherwise specified.

.EXAMPLE
PS ~$ Get-1PDefaultVaultPath
#>
function Get-1PDefaultVaultPath {
    $script:DefaultVaultPath
}

<#
.SYNOPSIS
Gets encrypted 1Password entries and their associated metadata.

.DESCRIPTION
Gets one or more encrypted 1Password entries by name, along with associated metadata.
The 'agilekeychain' vault format leaves entry metadata in plaintext, so no password is required for this operation.
The 'opvault' vault format encrypts all entry metadata, so a password is required if this operation is run
against an 'opvault' vault.

.PARAMETER Name
Specifies the name of the 1Password entry.
A case-insensitive wildcard match is used.

.PARAMETER VaultPassword
Specifies the 1Password vault password.
Required only if the 1Password vault is in 'opvault' format. In this case, if no value is specified,
the user will be prompted to enter password interactively.

.PARAMETER VaultPath
Specifies the root directory of the 1Password vault from which to read.
The default root directory can be read via Get-1PDefaultVaultPath, and changed via Set-1PDefaultVaultPath.

.EXAMPLE
# Gets an entry by name

PS ~$ Get-1PEntry gmail
Name   Type  LastUpdated          Location
----   ----  -----------          --------
gmail  Login 11/30/15 12:11:50 AM https://accounts.gmail.com/ServiceLogin

# show all available properties

PS ~$ Get-1PEntry gmail | Format-List *

Name          : gmail
Id            : 11C5741DE2294A1EB32FB088F5838951
VaultPath     : /Users/calvin/Dropbox/1Password/1Password.agilekeychain
SecurityLevel : SL5
KeyId         :
KeyData       :
Location      : https://accounts.gmail.com/ServiceLogin
Type          : Login
CreatedAt     : 10/28/15 11:21:15 PM
LastUpdated   : 11/30/15 12:11:50 AM
EncryptedData : U2FsdGVkX19ESuKr39T+d4185iU1NzMhKcfffu8 ...

.EXAMPLE
# Gets the list of all 1Password entries, sorted by last modified time

PS ~$ Get-1PEntry | Sort-Object LastUpdated

Name     Type  LastUpdated          Location
----     ----  -----------          --------
Twitter  Login 11/29/15 11:53:44 PM https://twitter.com/
Github   Login 11/29/15 11:58:12 PM https://github.com/login
Facebook Login 11/30/15 12:02:04 AM https://www.facebook.com/login.php
Linkedin Login 11/30/15 12:09:11 AM https://www.linkedin.com/uas/login-submit
...
#>
function Get-1PEntry {
    param(
        [Parameter(Position = 0)]
        [string] $Name,

        [Parameter(Position = 1)]
        [SecureString] $VaultPassword,

        [ValidateScript({ (Test-Path $_ -PathType Container) -and ($_ -match '\.(agilekeychain|opvault)(/|\\)?$') })]
        [string] $VaultPath = ($script:DefaultVaultPath)
    )

    if(-not $name){ $name = '*' }

    $result = $null
    if ($vaultPath -match '\.agilekeychain\b') {
        $result = GetAgileKeychainEntries $vaultPath $name
    } elseif ($vaultPath -match '\.opvault\b') {
        if (-not $vaultPassword) {
            $vaultPassword = Read-Host -AsSecureString -Prompt "1Password vault password"
        }
        $result = GetOPVaultEntries $vaultPath $name $vaultPassword
    }
    if((-not $result) -and ($name -notmatch '\*')) {
        Write-Error "No 1Password entries found with name $name"
    }
    $result
}

<#
.SYNOPSIS
Decrypts a 1Password Login, Password, Secure Note, or Generic Account.

.DESCRIPTION
Decrypts a 1Password Login, Password, Secure Note, or Generic Account to various output formats.
Logins and Generic Adcounts are returned as PSCredential by default.
Passwords and Secure Notes are returned as SecureString by default.
All forms can optionally be returned as plaintext strings or copied to the clipboard.

.PARAMETER Name
Specifies the name of the 1Password entry.
A case-insensitive wildcard match is used.
An error is thrown if no entries, or more than one entry, match the specified name.

.PARAMETER Entry
Specifies the 1Password entry to decrypt.

.PARAMETER VaultPassword
Specifies the 1Password vault password.
If no value is specified, the user will be prompted to enter password interactively.

.PARAMETER Plaintext
If specified, the decrypted data will be returned as plaintext strings.
Logins and Generic Accounts will be returned as 2 strings (username followed by password) unless -PasswordOnly is also specified.
Passwords and Secure Notes will be returned as 1 string.

.PARAMETER PasswordOnly
If specified, only the password field is included in the output.
This parameter has no effect when returning Password or Secure Note entries.

.PARAMETER Clip
If specified, the plaintext content of the entry will be copied to the clipboard.
Attempts to use a system utility for copying:
  - Windows: clip.exe
  - Mac: pbcopy
  - Linux: xclip

.PARAMETER VaultPath
Specifies the root directory of the 1Password vault from which to read.
The default root directory can be read via Get-1PDefaultVaultPath, and changed via Set-1PDefaultVaultPath.

.EXAMPLE
# Gets a login as a PSCredential.

PS ~$ Unprotect-1PEntry email
1Password vault password: **********

UserName                                Password
--------                                --------
calvin@gmail.com    System.Security.SecureString

.EXAMPLE
# Pipes a decrypted password into another command which normally prompts for a password.

PS ~$ Unprotect-1PEntry systemlogin -Plaintext -PasswordOnly | sudo -Sk echo "`ndude, sweet"
1Password vault password: **********
Password:
dude, sweet

.EXAMPLE
# Temporarily reveals a Secure Note by piping it to 'less'

PS ~$ Get-1PEntry mynote | Unprotect-1PEntry -Plaintext | less
1Password vault password: **********

.EXAMPLE
# Copies a password to the clipboard

PS ~$ Unprotect-1PEntry mylogin -Clip -PasswordOnly
1Password vault password: **********

.EXAMPLE
# Uses a bound SecureString object to specify the 1Password vault password.

PS ~$ $p = Read-Host -AsSecureString "Speak, friend, and enter"
Speak, friend, and enter: **********
PS ~$ Unprotect-1PEntry mynote $p
System.Security.SecureString
PS ~$ Unprotect-1PEntry mynote $p -Plaintext
s3cret m3ssage
#>
function Unprotect-1PEntry {
    [CmdletBinding(DefaultParameterSetName = 'Name/Secure')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Name/Secure')]
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Name/Plain')]
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = 'Name/Clip')]
        [string] $Name,

        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ParameterSetName = 'Entry/Secure')]
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ParameterSetName = 'Entry/Plain')]
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ParameterSetName = 'Entry/Clip')]
        [Entry] $Entry,

        [Parameter(Position = 1)]
        [SecureString] $VaultPassword,

        [Parameter(Mandatory = $true, ParameterSetName = 'Name/Plain')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Entry/Plain')]
        [switch] $Plaintext,

        [Parameter(ParameterSetName = 'Name/Secure')]
        [Parameter(ParameterSetName = 'Name/Plain')]
        [Parameter(ParameterSetName = 'Name/Clip')]
        [Parameter(ParameterSetName = 'Entry/Secure')]
        [Parameter(ParameterSetName = 'Entry/Plain')]
        [Parameter(ParameterSetName = 'Entry/Clip')]
        [Alias('po')]
        [switch] $PasswordOnly,

        [Parameter(Mandatory = $true, ParameterSetName = 'Name/Clip')]
        [Parameter(Mandatory = $true, ParameterSetName = 'Entry/Clip')]
        [switch] $Clip,

        [Parameter(ParameterSetName = 'Name/Secure')]
        [Parameter(ParameterSetName = 'Name/Plain')]
        [Parameter(ParameterSetName = 'Name/Clip')]
        [ValidateScript({ (Test-Path $_ -PathType Container) -and ($_ -match '\.(agilekeychain|opvault)(/|\\)?$') })]
        [string] $VaultPath = ($script:DefaultVaultPath)
    )

    $paramSet = $psCmdlet.ParameterSetName
    $opVault = ($name -and ($vaultPath -match '\.opvault\b')) -or ($entry -and $entry.KeyData)

    if ($name) {
        if ($opVault -and (-not $vaultPassword)) {
            $vaultPassword = Read-Host -AsSecureString -Prompt "1Password vault password"
        }

        $entries = Get-1PEntry -Name $name -VaultPath $vaultPath -VaultPassword $vaultPassword
        if (-not $entries) {
            Write-Error "No 1Password entries found with name $name"
        }
        if (@($entries).Length -gt 1) {
            Write-Error "More than one entry matches ${name}: $($entries -join ', ')"
        }

        $entry = $entries
    }

    if(-not $vaultPassword){
        $vaultPassword = Read-Host -AsSecureString -Prompt "1Password vault password"
    }

    $decrypted =
        if ($opVault) {
            DecryptOPVaultEntry $entry $vaultPassword
        } else {
            DecryptAgileKeychainEntry $entry $vaultPassword
        }

    if ($paramSet -match 'Secure') {
        if ($entry.Type -eq 'SecureNote') {
            ConvertTo-SecureString $decrypted.SecureNote -AsPlainText -Force
        } elseif (($entry.Type -eq 'Password') -or ($passwordOnly)) {
            ConvertTo-SecureString $decrypted.Password -AsPlainText -Force
        } else {
            New-Object PSCredential @($decrypted.Username, (ConvertTo-SecureString $decrypted.Password -AsPlainText -Force))
        }
    } else {
        $result = $(
            if(-not $passwordOnly) {
                $decrypted.Username  |? { $_ }
            }
            $decrypted.SecureNote |? { $_ }
            $decrypted.Password  |? { $_ }
        )
        if ($paramSet -match 'Plain') { $result }
        elseif ($paramSet -match 'Clip') { ClipboardCopy $result }
    }
}

if (Test-Path function:\TabExpansion) {
    Rename-Item function:\TabExpansion TabExpansionBackup
}

# tab completion support for entry names
function TabExpansion($line, $lastWord) {
    if ($script:DefaultVaultPath -match '\.agilekeychain\b') {
        $lastBlock = ($line -split '[|;]')[-1].TrimStart()
        if ($lastBlock -match '^(?:1p|g1p|Get-1PEntry|Unprotect-1pEntry)') {
            return 1PTabExpansion $lastBlock $script:DefaultVaultPath
        }
    }
    if (Test-Path function:\TabExpansionBackup) {
        TabExpansionBackup $line $lastWord
    }
}

New-Alias g1p Get-1PEntry
New-Alias 1p Unprotect-1PEntry
Update-TypeData -TypeName 'Entry' -DefaultDisplayPropertySet Name,Type,LastUpdated,Location -Force

Export-ModuleMember `
    -Function 'Get-1PDefaultVaultPath','Set-1PDefaultVaultPath','Get-1PEntry','Unprotect-1PEntry','TabExpansion' `
    -Alias 'g1p','1p'
