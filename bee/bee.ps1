# Bee bootstrap script. If you use powershell as your shell, runnning ./bee
# will directly run this script. If you're running cmd.exe running ./bee will
# run the bee.cmd and that will run powershell to run this script. This script
# is responsible for downloading a dotnet runtime if required, and for
# downloading a bee distribution if required, and for starting the actual bee
# driver executable.

trap
{
  # Ensure that we exit with an error code if there are uncaught exceptions.
  $ErrorActionPreference = "Continue"
  Write-Error $_
  exit 1
}

$ErrorActionPreference = "Stop"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Fixup common environment variables that perl might have messed up
# They get corrupted if they contain certain unicode characters (use emojis for testing)
$envUserProfile = $env:USERPROFILE
$actualUserProfile = [Environment]::GetFolderPath('UserProfile');

if ([string]::IsNullOrEmpty($actualUserProfile)) {
    # Protect ourselves in cases we're run not as a user
    $actualUserProfile = $HOME
}

$isCorruptedUserProfile =
    -not [string]::IsNullOrEmpty($envUserProfile) -and
    -not [string]::IsNullOrEmpty($actualUserProfile) -and
    -not (Test-Path -LiteralPath $envUserProfile -PathType Container -ErrorAction Ignore)

if ($isCorruptedUserProfile) {
    $env:USERPROFILE = $actualUserProfile;
    $env:HOME = $actualUserProfile;

    if (-not [string]::IsNullOrEmpty($env:LOCALAPPDATA) -and $env:LOCALAPPDATA.StartsWith($envUserProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        $env:LOCALAPPDATA = $actualUserProfile + $env:LOCALAPPDATA.Substring($envUserProfile.Length)
    }

    if (-not [string]::IsNullOrEmpty($env:APPDATA) -and $env:APPDATA.StartsWith($envUserProfile, [System.StringComparison]::OrdinalIgnoreCase)) {
        $env:APPDATA = $actualUserProfile + $env:APPDATA.Substring($envUserProfile.Length)
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Ensure some environment variables that can break the build are not set.
$env:MSBuildSDKsPath = $null # See BUILD-1219

# These two values will be replaced by the buildprocess when this script is
# used in a bootstrap distribution. When not replaced this script assumes it
# lives next to the standalone driver.
$use_bee_from_steve="bee/b649be378334_1a7f70b95e6ff016b5a75212ef827687532a7698eb826ea856f49f4162fe95ed.zip"
$use_bee_from_steve_repo="https://public-stevedore.unity3d.com/r/public"

if("$use_bee_from_steve_repo" -Match "testing")
{
  Write-Host "Warning this bee bootstrap script is using a bee from the testing repository. This fine for testing, but not to use in production."
}

if ($false -eq $IsWindows)
{
  Write-Error "The bee powershell script is only supported on Windows, please run the ./bee script instead."
  exit 1
}

# Stevedore artifact for the dotnet runtimes & SDKs. these are produced by the
# yamato CI UploadDotNetSdk. The zip file contains an info file
# that describes from which git commit / yamato-id it was built.  They are
# plain upstream packages, just unzipped & rezipped with this extra
# information added.
$dotnet_runtime_win_x64 = "dotnet-runtime-win-x64/10.0.11-9854b7a_4df1e2d4126427eb1afba7c2871895815df610a66ae5f420499b82adfd98b7bd.zip"
$dotnet_runtime_win_arm64 = "dotnet-runtime-win-arm64/10.0.11-9854b7a_6e20639d28b10257b41b93be11b893867e76196aa9c18e5692b7c03f84a47f8a.zip"
$dotnet_sdk_win_x64="dotnet-sdk-win-x64/10.0.303-9854b7a_53ef5e78cf2ff8cbd31b6db17c420271efefb38f4c03ed453aef27bbf59560fe.7z"
$dotnet_sdk_win_arm64="dotnet-sdk-win-arm64/10.0.303-9854b7a_0c43200246662e26e934beda55bee3f7aed313460137d21245dc57e90b60789b.7z"


$global:steve_artifact_return_value = ""

function Get-StevedorePackageInfo($steve_name)
{
    if (-not ($steve_name -match "^(?<name>.*)/(?<version>.*)_(?<hash>.*)\..*$")) { throw "Invalid stevedore artifact name: $steve_name" }
    return @($matches.name, $matches.version, $matches.hash, "$($matches.name)_$(-join $matches.hash[0..3])")
}

function Get-Args($scriptArgs)
{
    # Workaround for powershell parsing the command line arguments.  Powershell will drop the `:` when passed things like `-p:Foo=true` which is a common
    # way to pass arguments to msbuild when using dotnet.

    $kernel32_definition = @'
[DllImport("kernel32")]
public static extern IntPtr GetCommandLineW();
[DllImport("kernel32")]
public static extern IntPtr LocalFree(IntPtr hMem);
'@

    $kernel32 = Add-Type -IgnoreWarnings -MemberDefinition $kernel32_definition -Name 'Kernel32' -Namespace 'Win32' -PassThru

    $shell32_definition = @'
[DllImport("shell32.dll", SetLastError = true)]
public static extern IntPtr CommandLineToArgvW(
[MarshalAs(UnmanagedType.LPWStr)] string lpCmdLine,
out int pNumArgs);
'@

    $shell32 = Add-Type -IgnoreWarnings -MemberDefinition $shell32_definition -Name 'Shell32' -Namespace 'Win32' -PassThru

    $raw_command_line = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($kernel32::GetCommandLineW())

    $parsed_arg_count = 0
    $parsed_arg_ptr = $shell32::CommandLineToArgvW($raw_command_line, [ref] $parsed_arg_count)

    $all_args = @( )
    try
    {
        for ($i = 0; $i -lt $parsed_arg_count; $i++)
        {
            $all_args += [System.Runtime.InteropServices.Marshal]::PtrToStringUni(
                [System.Runtime.InteropServices.Marshal]::ReadIntPtr($parsed_arg_ptr, $i * [IntPtr]::Size)
            )
        }
    }
    finally
    {
        $kernel32::LocalFree($parsed_arg_ptr) | Out-Null
    }

    # Everything up to and including this script's own path (e.g.
    #   argv[0] <PowerShell>
    #   argv[1] <-NoProfile>
    #   argv[2] <-ExecutionPolicy>
    #   argv[3] <Bypass>
    #   argv[4] <-File>
    #   argv[5] <this script's path>
    # ) is PowerShell's own invocation preamble, not user args. We locate it by
    # path instead of assuming a fixed token count (6), since that count depends
    # on exactly how PowerShell was invoked and isn't guaranteed.
    $script_index = -1
    for ($i = 0; $i -lt $all_args.Length; $i++)
    {
        if ($all_args[$i] -eq $PSCommandPath)
        {
            $script_index = $i
            break
        }
    }

    if ($script_index -eq -1)
    {
        # Couldn't find our own script path in the raw command line (e.g. this
        # script was dot-sourced or invoked directly in an interactive session
        # rather than launched as its own process); fall back to PowerShell's
        # own (colon-mangling) argument parsing.
        return $scriptArgs
    }

    if ($script_index -eq $all_args.Length - 1)
    {
        # No user args were passed.
        return @( )
    }

    return $all_args[($script_index + 1)..($all_args.Length - 1)]
}


function Get-Stevedore-Artifact($steve_name, $steve_repo_url, $output_name)
{
    $package_name, $package_version, $package_hash, $package_unique_path = Get-StevedorePackageInfo $steve_name
    
    # We could extend this to parse the Stevedore.conf, and to attempt
    # downloads from multiple mirrors...
    $unzip_dir_path = "$actualUserProfile\.beebootstrap\$package_unique_path"

    $unpacked_marker = "$unzip_dir_path\.UNPACKED"
    if(![System.IO.File]::Exists($unpacked_marker)) {

        if (Test-Path $unzip_dir_path) {
            Remove-Item $unzip_dir_path -Recurse -Force
        }

        $download_link = "$steve_repo_url/$steve_name"
        $random = Get-Random
        $temporary_dir = "$actualUserProfile/.beebootstrap/download_$random"
        New-Item -ItemType Directory -Force -Path $temporary_dir | Out-Null
        $downloaded_file = "$temporary_dir/download.zip"

        # Turn off this weird powershell progress thing. Not only is it super
        # ugly, it's also reported to be the cause of making the download
        # superslow.
        # https://stackoverflow.com/questions/28682642/powershell-why-is-using-invoke-webrequest-much-slower-than-a-browser-download
        $ProgressPreference = 'SilentlyContinue'

        Write-Host "Downloading $output_name"

        # A couple of short retries first, then back off to ~30s intervals; the
        # last retry lands a bit past the 3 minute mark before giving up.
        $dl_success = $false
        $retry_delays_seconds = @(0, 2, 2, 30, 30, 30, 30, 30, 30, 30)
        foreach ($sleep_seconds in $retry_delays_seconds)
        {
            Start-Sleep -Seconds $sleep_seconds

            try { Invoke-WebRequest $download_link -outfile "$downloaded_file" }
            catch
            {
                Write-Host "Download of `"$download_link`" failed: $($_.Exception.Message)"
                continue
            }

            if (Get-Command Get-FileHash -errorAction SilentlyContinue)
            {
                $actual_sha256 = (Get-FileHash "$downloaded_file" -Algorithm SHA256).Hash
                if ($actual_sha256 -ne $package_hash)
                {
                    Write-Host "$downloaded_file sha256 mismatch: expected $package_hash actual $actual_sha256 - removing"
                    Remove-Item "$downloaded_file" -Force
                    continue
                }
            }

            $dl_success = $true
            break
        }
        if (!$dl_success)
        {
            Write-Host "Failed to download `"$download_link`""
            exit 1
        }

        # Make sure the parent directory of the target directory already exists
        $parent_dir = Split-Path -Parent $unzip_dir_path
        if( -Not (Test-Path -Path $parent_dir) )
        {
            New-Item -ItemType Directory -Path $parent_dir | Out-Null
        }

        Write-Host "Unzipping $output_name"
        [System.IO.Compression.ZipFile]::ExtractToDirectory("$downloaded_file", "$unzip_dir_path")

        # Create the .UNPACKED marker file
        Out-File -FilePath "$unpacked_marker"

        Remove-Item "$temporary_dir" -Recurse -Force
    }

    # We assign to a global instead of returning a value, since returning
    # a value is somehow very brittle, as any command in this function
    # that isn't piped to Out-Null might actually pollute the return value.
    $global:steve_artifact_return_value = $unzip_dir_path
}

if( $use_bee_from_steve -eq "no") {
    # This script supports running as part of a full bee distribution. In
    # this case, use_bee_from_steve is not set, and we find the path to
    # the distribution by looking at where the script itself is. It should
    # be placed in Standalone/Release of the distribution.
    $standalone_release=$PSScriptRoot
}
else {
    # We also support downloading the bee distribution from a stevedore
    # server. In this case use_bee_from_steve should be set to a stevedore
    # artifact name. We'll download it and run it. In this mode, the only
    # thing a user needs to version in their repo is this script.
    Get-Stevedore-Artifact "$use_bee_from_steve" "$use_bee_from_steve_repo" "Bee distribution"
    $standalone_release = "$global:steve_artifact_return_value/Standalone/Release"
}

$distribution_path = [System.IO.Path]::GetFullPath("$standalone_release/../..")
$standalone_path = "$standalone_release/Bee.StandaloneDriver.exe"
if(![System.IO.File]::Exists($standalone_path)) {
    $standalone_path = "$standalone_release/Bee.StandaloneDriver.dll"
}

if([Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE", 'Machine') -eq "ARM64")
{
    $dotnet_runtime_steve_artifact = "$dotnet_runtime_win_arm64"
    $dotnet_sdk_steve_artifact = "$dotnet_sdk_win_arm64"
}
else
{
    $dotnet_runtime_steve_artifact = "$dotnet_runtime_win_x64"
    $dotnet_sdk_steve_artifact = "$dotnet_sdk_win_x64"
}

if($Null -ne $env:BEE_DOTNET_MUXER)# if we are recursing, then use the dotnet.exe from outside.
{
    $dotnet_exe = $env:BEE_DOTNET_MUXER
}
else
{
    Get-Stevedore-Artifact $dotnet_runtime_steve_artifact "https://public-stevedore.unity3d.com/r/public" "Dotnet runtime"
    $dotnet_exe = "$global:steve_artifact_return_value\dotnet.exe"
}

$parsed_args = Get-Args $args

#we assign BEE_DOTNET_MUXER env var here, so that the bee that is running knows how it can use this dotnet runtime to start other dotnet framework dependent apps.
#it uses this to run the stevedore downloader program.
try {
    $env:BEE_DISTRIBUTION_PATH = $distribution_path
    $env:BEE_DOTNET_MUXER = $dotnet_exe
    $DOTNET_MULTILEVEL_LOOKUP_backup = $env:DOTNET_MULTILEVEL_LOOKUP
    $env:DOTNET_MULTILEVEL_LOOKUP = 0

    # Decide the branch using PowerShell's own $args (reliable) rather than the
    # raw-reparsed $parsed_args, since the latter's alignment depends on how this
    # script was invoked. $parsed_args is only needed below to preserve `:` in
    # arguments like `-p:Foo=true` when passing them on to the dotnet SDK.
    if($args.Length -gt 0 -and $args[0] -eq 'dotnet')
    {
        if($Null -ne $env:BEE_DOTNET_SDK_UNZIP_DIR_PATH) # if there is a dotnet_sdk from outside
        { # use the dotnet sdk from outside.
            $bee_dotnet_sdk_unzip_dir_path = $env:BEE_DOTNET_SDK_UNZIP_DIR_PATH
        }
        else
        {
            # Use bee steve to download and unpack the dotnet SDK
            $package_name, $package_version, $package_hash, $package_unique_path = Get-StevedorePackageInfo $dotnet_sdk_steve_artifact
            $bee_dotnet_sdk_unzip_dir_path = "$actualUserProfile\.beebootstrap\$package_unique_path"
            & $dotnet_exe $standalone_path "steve", "internal-unpack", "public", "$dotnet_sdk_steve_artifact", "$bee_dotnet_sdk_unzip_dir_path"

            # use the dotnet sdk we just downloaded.
            $env:BEE_DOTNET_SDK_UNZIP_DIR_PATH = $bee_dotnet_sdk_unzip_dir_path
        }

        # Set the path so this dotnet SDK can be used by children.
        $PATH_backup = $env:PATH
        $env:PATH = "$bee_dotnet_sdk_unzip_dir_path;$env:PATH"

        # DOTNET_ROOT lets child processes locate the .NET runtime directly. Without it,
        # spawned processes (e.g. vstest test hosts) cannot find hostfxr.dll and fail to start.
        $env:DOTNET_ROOT = $bee_dotnet_sdk_unzip_dir_path

        # Run the wrapper and pass on any user args
        $dotnet_sdk_exe = "$bee_dotnet_sdk_unzip_dir_path\dotnet.exe"
        if ($parsed_args.Length -gt 1)
        {
            & $dotnet_sdk_exe $parsed_args[1..($parsed_args.Length - 1)]
        }
        else
        {
            & $dotnet_sdk_exe
        }
    } else {

        # Run the wrapper and pass on any user args
        & $dotnet_exe $standalone_path $args
    }
    
} finally {
    $env:BEE_DISTRIBUTION_PATH = $Null
    $env:BEE_DOTNET_MUXER = $Null
    $env:DOTNET_MULTILEVEL_LOOKUP = $DOTNET_MULTILEVEL_LOOKUP_backup
    if($Null -ne $PATH_backup)
    {
        $env:PATH = $PATH_backup
    }
}


# Ensure exit code is preserved when running from another script.
exit $LastExitCode



# Automatically generated by Yamato Job: https://unity-ci.cds.internal.unity3d.com/job/77194119
#MANIFEST public: bee/b649be378334_1a7f70b95e6ff016b5a75212ef827687532a7698eb826ea856f49f4162fe95ed.zip
