@echo on

set "NUMBA_DEVELOPER_MODE=1"
set "NUMBA_DISABLE_ERROR_MESSAGE_HIGHLIGHTING=1"
set "PYTHONFAULTHANDLER=1"
@rem generic CPU avoids LLVM 20 OOM; reduced Windows test set; UTF-8 so that
@rem `numba -s` encodes correctly on a piped stdout (numba.tests.test_cli).
set "NUMBA_CPU_NAME=generic"
set "_NUMBA_REDUCED_TESTING=1"
set "PYTHONUTF8=1"

python -m numba.tests.test_runtests
if errorlevel 1 exit /b 1

if "%FAST_TESTS%"=="1" (
  python -m numba.runtests -b --random=0.1 --exclude-tags=long_running -m %CPU_COUNT%
) else (
  python -m numba.runtests -b --exclude-tags=long_running -m %CPU_COUNT%
)
if errorlevel 1 exit /b 1

@rem ===== DIAGNOSTIC (prefix-dev/rattler-build#2657): name the real handle owner =====
@rem Runs BEFORE taskkill so it captures the NATURAL holder of the test dir. Every line
@rem is print-only and must not change the exit code (tests already passed above). Layers:
@rem   (1) processes whose EXECUTABLE lives under the build tree (old probe);
@rem   (2) openfiles (only reports if the 'maintain objects list' flag is on; else harmless);
@rem   (3) Sysinternals handle64 -- the only probe that names a process HOLDING A HANDLE into
@rem       the dir. If NO holder is reported here, the lock is acquired only at/after script
@rem       exit -> rattler-build's own teardown, i.e. #2657, not fixable in this recipe.
echo === HANDLE PROBE START ===
echo PROBE_CWD=%CD%
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like 'D:\bld\*' } | ForEach-Object { Write-Host ('INTREE ' + $_.ProcessId + ' ' + $_.Name + ' :: ' + $_.ExecutablePath) }"
openfiles /query /fo table 2>&1 | findstr /i /c:"bld\test"
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $o = $env:TEMP + '\handle64.exe'; Invoke-WebRequest -UseBasicParsing 'https://live.sysinternals.com/handle64.exe' -OutFile $o; Write-Host 'HANDLE_DL_OK' } catch { Write-Host ('HANDLE_DL_FAIL ' + $_.Exception.Message) }"
if exist "%TEMP%\handle64.exe" ("%TEMP%\handle64.exe" -accepteula -nobanner "D:\bld\test" 2>&1) else (echo HANDLE64_MISSING)
echo === HANDLE PROBE END ===

@rem Windows: known rattler-build test-dir cleanup race (prefix-dev/rattler-build#2657) --
@rem rattler removes the test dir right after this script and Windows may not have
@rem released the test env's handles yet ("Access is denied", os error 5). Reap any
@rem straggler and pause so the OS can release; reduces (does not eliminate) the flake.
taskkill /F /T /IM python.exe >nul 2>&1
ping -n 10 127.0.0.1 >nul
exit /b 0
