function Get-ModuleHandle {
    Param (
        [OutputType([IntPtr])]

        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ModuleName
    )

    $baseAddress = [IntPtr]::Zero
    $modules = [System.Diagnostics.Process]::GetCurrentProcess().Modules

    foreach ($mod in $modules) {
        if ($mod.ModuleName -ieq $ModuleName) {
            $baseAddress = $mod.BaseAddress
            break
        }
    }

    $baseAddress
}


function Get-ProcAddress {
    Param (
        [OutputType([IntPtr])]

        [Parameter(Mandatory = $true, Position = 0)]
        [IntPtr]$Module,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$ProcName
    )

    $functionAddress = [IntPtr]::Zero
    $export_dir = [IntPtr]::Zero
    $numberOfNames = 0
    $addressOfFunctions = [IntPtr]::Zero
    $addressOfNames = [IntPtr]::Zero
    $addressOfNameOrdinals = [IntPtr]::Zero
    $namePointer = [IntPtr]::Zero

    if ([System.Runtime.InteropServices.Marshal]::ReadInt16($Module) -ne 0x5A4D) {
        return [IntPtr]::Zero
    }

    $e_lfanew = [System.Runtime.InteropServices.Marshal]::ReadInt32($Module, 0x3C)

    if ([IntPtr]::Size -eq 8) {
        $virtual_address = [System.Runtime.InteropServices.Marshal]::ReadInt32($Module, $e_lfanew + 0x18 + 0x70)
        $export_dir = [IntPtr]($Module.ToInt64() + $virtual_address)
        $numberOfNames = [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x18)
        $addressOfFunctions = [IntPtr]($Module.ToInt64() + [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x1C))
        $addressOfNames = [IntPtr]($Module.ToInt64() + [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x20))
        $addressOfNameOrdinals = [IntPtr]($Module.ToInt64() + [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x24))
    } else {
        $virtual_address = [System.Runtime.InteropServices.Marshal]::ReadInt32($Module, $e_lfanew + 0x18 + 0x60)
        $export_dir = [IntPtr]($Module.ToInt32() + $virtual_address)
        $numberOfNames = [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x18)
        $addressOfFunctions = [IntPtr]($Module.ToInt32() + [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x1C))
        $addressOfNames = [IntPtr]($Module.ToInt32() + [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x20))
        $addressOfNameOrdinals = [IntPtr]($Module.ToInt32() + [System.Runtime.InteropServices.Marshal]::ReadInt32($export_dir, 0x24))
    }

    for ($counter = 0; $counter -lt $numberOfNames; $counter++) {
        if ([IntPtr]::Size -eq 8) {
            $namePointer = [IntPtr]($Module.ToInt64() + [System.Runtime.InteropServices.Marshal]::ReadInt32($addressOfNames, 4 * $counter))
        } else {
            $namePointer = [IntPtr]($Module.ToInt32() + [System.Runtime.InteropServices.Marshal]::ReadInt32($addressOfNames, 4 * $counter))
        }

        $entryName = [System.Runtime.InteropServices.Marshal]::PtrToStringAnsi($namePointer)

        if ($entryName -ieq $ProcName) {
            $ordinal = [System.Runtime.InteropServices.Marshal]::ReadInt16($addressOfNameOrdinals, 2 * $counter)
            $offset = [System.Runtime.InteropServices.Marshal]::ReadInt32($addressOfFunctions, 4 * $ordinal)

            if ([IntPtr]::Size -eq 8) {
                $functionAddress = [IntPtr]($Module.ToInt64() + $offset)
            } else {
                $functionAddress = [IntPtr]($Module.ToInt32() + $offset)
            }
            break
        }
    }

    $functionAddress
}


function Get-SyscallNumber {
    Param (
        [OutputType([Int32])]

        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SyscallName
    )

    $moduleNames = @("ntdll.dll", "win32u.dll")
    $moduleName = $null
    $syscallNumber = -1;

    if ($SyscallName -notmatch "^Nt\S+$") {
        Write-Warning "Syscall name should be start with `"Nt`"."

        return -1
    }

    foreach ($moduleName in $moduleNames) {
        $moduleBase = Get-ModuleHandle $moduleName

        if ($moduleBase -eq [IntPtr]::Zero) {
            Write-Warning "Failed to resolve module base."
            break
        }

        $functionBase = Get-ProcAddress $moduleBase $SyscallName

        if ($functionBase -eq [IntPtr]::Zero) {
            continue
        }

        $architecture = [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")

        if ($architecture -ieq "x86") {
            $isArm = [System.IO.Directory]::Exists("C:\Windows\SysArm32")

            for ($count = 0; $count -lt 0x10; $count++) {
                if ([System.Runtime.InteropServices.Marshal]::ReadByte($functionBase) -eq 0xB8) { # mov eax, 0x????
                    $syscallNumber = [System.Runtime.InteropServices.Marshal]::ReadInt32($functionBase, 1) + $count
                    break
                } else {
                    if ($isArm) {
                        $functionBase = [IntPtr]($functionBase.ToInt32() - 0x10)
                    } else {
                        $functionBase = [IntPtr]($functionBase.ToInt32() - 0x20)
                    }
                }
            }
        } elseif ($architecture -ieq "AMD64") {
            for ($count = 0; $count -lt 0x10; $count++) {
                if ([System.Runtime.InteropServices.Marshal]::ReadInt32($functionBase) -eq 0xB8D18B4C) { # mov r10, rcx; mov eax, 0x???? 
                    $syscallNumber = [System.Runtime.InteropServices.Marshal]::ReadInt32($functionBase, 4) + $count
                    break
                } else {
                    $functionBase = [IntPtr]($functionBase.ToInt64() - 0x20)
                }
            }
        } elseif ($architecture -ieq "ARM64") {
            for ($count = 0; $count -lt 0x10; $count++) {
                $instruction = [System.Runtime.InteropServices.Marshal]::ReadInt32($functionBase)

                if (($instruction -band 0xFFE0001F) -eq 0xD4000001) { # svc #0x??
                    $syscallNumber = (($instruction -shr 5) -band 0x0000FFFF) + $count
                    break
                } else {
                    $functionBase = [IntPtr]($functionBase.ToInt64() - 0x10)
                }
            }
        } else {
            Write-Warning "Unsupported architecture."
            break
        }

        if ($syscallNumber -ne -1) {
            break
        }
    }

    if ($functionBase -eq [IntPtr]::Zero) {
        Write-Warning "Failed to resolve the specified syscall name."
    }

    if ($syscallNumber -ne -1) {
        Write-Host "Syscall Number : 0x$($syscallNumber.ToString("X"))"
    }

    $syscallNumber
}
