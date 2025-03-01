[CmdletBinding()]
Param(
    [Parameter(Position=1)]
    [String] $Target = "build",
    [String] $AdditionalArgs = '',
    [String] $Build = '',
    [String] $RemotingVersion = '3107.v665000b_51092',
    [String] $BuildNumber = '1',
    [switch] $PushVersions = $false,
    [switch] $DisableEnvProps = $false
)

$Repository = 'agent'
$Organization = 'jenkins'

if(!$DisableEnvProps) {
    Get-Content env.props | ForEach-Object {
        $items = $_.Split("=")
        if($items.Length -eq 2) {
            $name = $items[0].Trim()
            $value = $items[1].Trim()
            Set-Item -Path "env:$($name)" -Value $value
        }
    }
}

if(![String]::IsNullOrWhiteSpace($env:DOCKERHUB_REPO)) {
    $Repository = $env:DOCKERHUB_REPO
}

if(![String]::IsNullOrWhiteSpace($env:DOCKERHUB_ORGANISATION)) {
    $Organization = $env:DOCKERHUB_ORGANISATION
}

if(![String]::IsNullOrWhiteSpace($env:REMOTING_VERSION)) {
    $RemotingVersion = $env:REMOTING_VERSION
}

# this is the jdk version that will be used for the 'bare tag' images, e.g., jdk8-windowsservercore-1809 -> windowsserver-1809
$defaultBuild = '11'
$builds = @{}
$env:REMOTING_VERSION = "$RemotingVersion"
$ProgressPreference = 'SilentlyContinue' # Disable Progress bar for faster downloads

# Ensures that docker-compose is present
# Docker-compose v2 does not works and prints a "not implemented" message (tested with 2.0.1)
$dockerComposeBin = "C:\tools\docker-compose.exe"
if (-not(Test-Path -Path $dockerComposeBin)) {
    Invoke-WebRequest "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-Windows-x86_64.exe" -OutFile "$dockerComposeBin"
}
& "$dockerComposeBin" --version

Get-ChildItem -Recurse -Include windows -Directory | ForEach-Object {
    Get-ChildItem -Directory -Path $_ | Where-Object { Test-Path (Join-Path $_.FullName "Dockerfile") } | ForEach-Object {
        $dir = $_.FullName.Replace((Get-Location), "").TrimStart("\")
        $items = $dir.Split("\")
        $jdkVersion = $items[0]
        $baseImage = $items[2]
        $basicTag = "jdk${jdkVersion}-${baseImage}"
        $versionTag = "${RemotingVersion}-${BuildNumber}-${basicTag}"
        $tags = @( $basicTag, $versionTag )
        if($jdkVersion -eq $defaultBuild) {
            $tags += $baseImage
        }

        $builds[$basicTag] = @{
            'Folder' = $dir;
            'Tags' = $tags;
        }
    }
}

# Prebuild in parallel all images to populate the cache
Write-Host "BUILD: Starting Docker Compose General Build"
& "$dockerComposeBin" --file=build-windows.yaml build --parallel --pull
Write-Host "BUILD: Finished Docker Compose General Build"

if(![System.String]::IsNullOrWhiteSpace($Build) -and $builds.ContainsKey($Build)) {
    foreach($tag in $builds[$Build]['Tags']) {
        Write-Host "BUILD: Building $Build => tag=$tag"
        $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $tag, $AdditionalArgs, $builds[$Build]['Folder']
        Invoke-Expression $cmd

        if($PushVersions) {
            $buildTag = "$RemotingVersion-$BuildNumber-$tag"
            if($tag -eq 'latest') {
                $buildTag = "$RemotingVersion-$BuildNumber"
            }
            Write-Host "BUILD: Building $Build => tag=$buildTag"
            $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $buildTag, $AdditionalArgs, $builds[$Build]['Folder']
            Invoke-Expression $cmd
        }
    }
} else {
    foreach($b in $builds.Keys) {
        foreach($tag in $builds[$b]['Tags']) {
            Write-Host "BUILD: Building $b => tag=$tag"
            $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $tag, $AdditionalArgs, $builds[$b]['Folder']
            Invoke-Expression $cmd

            if($PushVersions) {
                $buildTag = "$RemotingVersion-$BuildNumber-$tag"
                if($tag -eq 'latest') {
                    $buildTag = "$RemotingVersion-$BuildNumber"
                }
                Write-Host "BUILD: Building $Build => tag=$buildTag"
                $cmd = "docker build --build-arg VERSION='$RemotingVersion' -t {0}/{1}:{2} {3} {4}" -f $Organization, $Repository, $buildTag, $AdditionalArgs, $builds[$b]['Folder']
                Invoke-Expression $cmd
            }
        }
    }
}

if($lastExitCode -ne 0) {
    exit $lastExitCode
}

if($target -eq "test") {
    Write-Host "BUILD: Starting test harness"

    # Only fail the run afterwards in case of any test failures
    $testFailed = $false
    $mod = Get-InstalledModule -Name Pester -MinimumVersion 5.3.0 -MaximumVersion 5.3.3 -ErrorAction SilentlyContinue
    if($null -eq $mod) {
        $module = "c:\Program Files\WindowsPowerShell\Modules\Pester"
        if(Test-Path $module) {
            takeown /F $module /A /R
            icacls $module /reset
            icacls $module /grant Administrators:'F' /inheritance:d /T
            Remove-Item -Path $module -Recurse -Force -Confirm:$false
        }
        Install-Module -Force -Name Pester -MaximumVersion 5.3.3
    }

    Import-Module Pester
    $configuration = [PesterConfiguration]::Default
    $configuration.Run.PassThru = $true
    $configuration.Run.Path = '.\tests'
    $configuration.Run.Exit = $true
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.Output.Verbosity = 'Diagnostic'
    $configuration.CodeCoverage.Enabled = $false

    if(![System.String]::IsNullOrWhiteSpace($Build) -and $builds.ContainsKey($Build)) {
        $folder = $builds[$Build]['Folder']
        $env:FOLDER = $folder
        $env:VERSION = "$RemotingVersion-$BuildNumber"
        if(Test-Path ".\target\$folder") {
            Remove-Item -Recurse -Force ".\target\$folder"
        }
        New-Item -Path ".\target\$folder" -Type Directory | Out-Null
        $configuration.TestResult.OutputPath = ".\target\$folder\junit-results.xml"
        $TestResults = Invoke-Pester -Configuration $configuration
        if ($TestResults.FailedCount -gt 0) {
            Write-Host "There were $($TestResults.FailedCount) failed tests in $Build"
            $testFailed = $true
        } else {
            Write-Host "There were $($TestResults.PassedCount) passed tests out of $($TestResults.TotalCount) in $Build"
        }
        Remove-Item env:\FOLDER
        Remove-Item env:\VERSION
    } else {
        foreach($b in $builds.Keys) {
            $folder = $builds[$b]['Folder']
            $env:FOLDER = $folder
            $env:VERSION = "$RemotingVersion-$BuildNumber"
            if(Test-Path ".\target\$folder") {
                Remove-Item -Recurse -Force ".\target\$folder"
            }
            New-Item -Path ".\target\$folder" -Type Directory | Out-Null
            $configuration.TestResult.OutputPath = ".\target\$folder\junit-results.xml"
            $TestResults = Invoke-Pester -Configuration $configuration
            if ($TestResults.FailedCount -gt 0) {
                Write-Host "There were $($TestResults.FailedCount) failed tests in $b"
                $testFailed = $true
            } else {
                Write-Host "There were $($TestResults.PassedCount) passed tests out of $($TestResults.TotalCount) in $b"
            }
            Remove-Item env:\FOLDER
            Remove-Item env:\VERSION
        }
    }

    # Fail if any test failures
    if($testFailed -ne $false) {
        Write-Error "Test stage failed!"
        exit 1
    } else {
        Write-Host "Test stage passed!"
    }
}

if($target -eq "publish") {
    # Only fail the run afterwards in case of any issues when publishing the docker images
    $publishFailed = 0
    if(![System.String]::IsNullOrWhiteSpace($Build) -and $builds.ContainsKey($Build)) {
        foreach($tag in $Builds[$Build]['Tags']) {
            Write-Host "Publishing $Build => tag=$tag"
            $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $tag
            Invoke-Expression $cmd
            if($lastExitCode -ne 0) {
                $publishFailed = 1
            }

            if($PushVersions) {
                $buildTag = "$RemotingVersion-$BuildNumber-$tag"
                if($tag -eq 'latest') {
                    $buildTag = "$RemotingVersion-$BuildNumber"
                }
                Write-Host "Publishing $Build => tag=$buildTag"
                $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $buildTag
                Invoke-Expression $cmd
                if($lastExitCode -ne 0) {
                    $publishFailed = 1
                }
            }
        }
    } else {
        foreach($b in $builds.Keys) {
            foreach($tag in $Builds[$b]['Tags']) {
                Write-Host "Publishing $b => tag=$tag"
                $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $tag
                Invoke-Expression $cmd
                if($lastExitCode -ne 0) {
                    $publishFailed = 1
                }

                if($PushVersions) {
                    $buildTag = "$RemotingVersion-$BuildNumber-$tag"
                    if($tag -eq 'latest') {
                        $buildTag = "$RemotingVersion-$BuildNumber"
                    }
                    Write-Host "Publishing $Build => tag=$buildTag"
                    $cmd = "docker push {0}/{1}:{2}" -f $Organization, $Repository, $buildTag
                    Invoke-Expression $cmd
                    if($lastExitCode -ne 0) {
                        $publishFailed = 1
                    }
                }
            }
        }
    }

    # Fail if any issues when publising the docker images
    if($publishFailed -ne 0) {
        Write-Error "Publish failed!"
        exit 1
    }
}

if($lastExitCode -ne 0) {
    Write-Error "Build failed!"
} else {
    Write-Host "Build finished successfully"
}
exit $lastExitCode
