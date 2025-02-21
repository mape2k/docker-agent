# escape=`

# The MIT License
#
#  Copyright (c) 2020, Alex Earl and other Jenkins Contributors
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.
ARG JAVA_VERSION=17.0.6_10
FROM eclipse-temurin:"${JAVA_VERSION}"-jdk-windowsservercore-1809 AS core

# If you pass in a POWERSHELL_VERSION, make sure it ends with a hyphen, leaving it empty will
# use the 'latest'
ARG POWERSHELL_VERSION=
FROM mcr.microsoft.com/powershell:"${POWERSHELL_VERSION}nanoserver-1809"

ARG JAVA_VERSION=17.0.6_10
ARG JAVA_HOME="C:\openjdk-17"

# The nanoserver image is nice and small, but we need a couple of things to get SSH working
COPY --from=core /windows/system32/netapi32.dll /windows/system32/netapi32.dll
COPY --from=core /windows/system32/whoami.exe /windows/system32/whoami.exe
COPY --from=core $JAVA_HOME $JAVA_HOME

SHELL ["pwsh.exe", "-Command", "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]
USER ContainerAdministrator

ARG GIT_VERSION=2.39.2
ARG GIT_PATCH_VERSION=1
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 ; `
    # The patch "windows.1" always have a different URL than the subsequent patch (ZIP filename is different)
    if($env:GIT_PATCH_VERSION -eq 1) { $url = $('https://github.com/git-for-windows/git/releases/download/v{0}.windows.{1}/MinGit-{0}-64-bit.zip' -f $env:GIT_VERSION, $env:GIT_PATCH_VERSION); } `
    else {$url = $('https://github.com/git-for-windows/git/releases/download/v{0}.windows.{1}/MinGit-{0}.{1}-64-bit.zip' -f $env:GIT_VERSION, $env:GIT_PATCH_VERSION)} ; `
    Write-Host "Retrieving $url..." ; `
    Invoke-WebRequest $url -OutFile 'mingit.zip' -UseBasicParsing ; `
    Expand-Archive mingit.zip -DestinationPath c:\mingit ; `
    Remove-Item mingit.zip -Force

ARG GIT_LFS_VERSION=3.1.4
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 ; `
    $url = $('https://github.com/git-lfs/git-lfs/releases/download/v{0}/git-lfs-windows-amd64-v{0}.zip' -f $env:GIT_LFS_VERSION) ; `
    Write-Host "Retrieving $url..." ; `
    Invoke-WebRequest $url -OutFile 'GitLfs.zip' -UseBasicParsing ; `
    Expand-Archive GitLfs.zip -DestinationPath c:\mingit\mingw64\bin ; `
    Remove-Item GitLfs.zip -Force ; `
    & C:\mingit\cmd\git.exe lfs install

ENV ProgramFiles="C:\Program Files" `
    WindowsPATH="C:\Windows\system32;C:\Windows" `
    JAVA_HOME="${JAVA_HOME}"
ENV PATH="${WindowsPATH};${ProgramFiles}\PowerShell;${JAVA_HOME}\bin;C:\mingit\cmd"

ARG user=jenkins

ARG AGENT_FILENAME=agent.jar
ARG AGENT_HASH_FILENAME=$AGENT_FILENAME.sha1

RUN net accounts /maxpwage:unlimited ; `
    net user "$env:user" /add /expire:never /passwordreq:no ; `
    net localgroup Administrators /add $env:user ; `
    New-Item -ItemType Directory -Path C:/ProgramData/Jenkins | Out-Null

ARG AGENT_ROOT=C:/Users/$user
ARG AGENT_WORKDIR=${AGENT_ROOT}/Work

ENV AGENT_WORKDIR=${AGENT_WORKDIR}

# Get the Agent from the Jenkins Artifacts Repository
ARG VERSION=3107.v665000b_51092
RUN [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 ; `
    Invoke-WebRequest $('https://repo.jenkins-ci.org/public/org/jenkins-ci/main/remoting/{0}/remoting-{0}.jar' -f $env:VERSION) -OutFile $(Join-Path C:/ProgramData/Jenkins $env:AGENT_FILENAME) -UseBasicParsing ; `
    Invoke-WebRequest $('https://repo.jenkins-ci.org/public/org/jenkins-ci/main/remoting/{0}/remoting-{0}.jar.sha1' -f $env:VERSION) -OutFile (Join-Path C:/ProgramData/Jenkins $env:AGENT_HASH_FILENAME) -UseBasicParsing ; `
    if ((Get-FileHash (Join-Path C:/ProgramData/Jenkins $env:AGENT_FILENAME) -Algorithm SHA1).Hash -ne (Get-Content (Join-Path C:/ProgramData/Jenkins $env:AGENT_HASH_FILENAME))) {exit 1} ; `
    Remove-Item -Force (Join-Path C:/ProgramData/Jenkins $env:AGENT_HASH_FILENAME)

USER $user

RUN New-Item -Type Directory $('{0}/.jenkins' -f $env:AGENT_ROOT) | Out-Null ; `
    New-Item -Type Directory $env:AGENT_WORKDIR | Out-Null

RUN git config --global core.longpaths true

VOLUME "${AGENT_ROOT}"/.jenkins
VOLUME "${AGENT_WORKDIR}"
WORKDIR "${AGENT_ROOT}"

LABEL `
    org.opencontainers.image.vendor="Jenkins project" `
    org.opencontainers.image.title="Official Jenkins Agent Base Docker image" `
    org.opencontainers.image.description="This is a base image, which provides the Jenkins agent executable (agent.jar)" `
    org.opencontainers.image.version="${VERSION}" `
    org.opencontainers.image.url="https://www.jenkins.io/" `
    org.opencontainers.image.source="https://github.com/jenkinsci/docker-agent" `
    org.opencontainers.image.licenses="MIT"
