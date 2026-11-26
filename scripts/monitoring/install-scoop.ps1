# Install Scoop on a runner, from the installer of one commit of ScoopInstaller/Install, and put its shims on the PATH of
# the steps that follow.
#
# The installer is a script that is downloaded and then run, so it is held to the commit and the digest named in the
# environment before it runs: a change of the installer is a commit of this repository, and a file that is not the one
# reviewed is never executed. What the installer itself then downloads (Scoop) is what the Scoop project publishes, and
# is not held here. The job that runs this has no secret and a read-only token.
#
#   SCOOP_INSTALLER_COMMIT   the commit of ScoopInstaller/Install
#   SCOOP_INSTALLER_SHA256   the SHA-256 of install.ps1 at that commit, in lowercase
$ErrorActionPreference = 'Stop'

if ($env:SCOOP_INSTALLER_COMMIT -notmatch '^[0-9a-f]{40}$') { throw 'SCOOP_INSTALLER_COMMIT is not a commit' }
if ($env:SCOOP_INSTALLER_SHA256 -notmatch '^[0-9a-f]{64}$') { throw 'SCOOP_INSTALLER_SHA256 is not a lowercase SHA-256' }

$installer = Join-Path $env:RUNNER_TEMP 'install.ps1'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ScoopInstaller/Install/$env:SCOOP_INSTALLER_COMMIT/install.ps1" -OutFile $installer
$actual = (Get-FileHash -Path $installer -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $env:SCOOP_INSTALLER_SHA256) {
    throw "the installer of Scoop is $actual, not the $env:SCOOP_INSTALLER_SHA256 this workflow holds, and it is not run"
}
& $installer -RunAsAdmin
Add-Content -Path $env:GITHUB_PATH -Value (Join-Path $env:USERPROFILE 'scoop\shims')
