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
  python -m numba.runtests -b --random=0.25 --exclude-tags=long_running -m %CPU_COUNT%
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

@rem ===== DELAYED DETACHED PROBE (prefix-dev/rattler-build#2657) =====
@rem The early probe above runs too soon: on FAILING jobs it comes back clean because the handle
@rem that blocks removal only appears at/after rattler-build's delete syscall -- which happens AFTER
@rem this script exits. So: (1) cd OUT of the test dir so cmd.exe stops holding it as CWD (also a
@rem control: if the job still fails, cmd's CWD was never the cause); (2) launch a DETACHED powershell
@rem that outlives our exit, sleeps past it, then loops handle64 over the test dir. It inherits
@rem rattler-build's still-open stdout pipe, so its output lands in the CI log right around the
@rem os-error-5 -- no file retrieval needed. taskkill/ping removed: proven useless (the probe named
@rem no python.exe holder on failing jobs, and the 10s delay did not prevent the failure).
cd /d C:\ 2>nul
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Sleep -Seconds 3; $h = $env:TEMP + '\handle64.exe'; for ($i=0; $i -lt 28; $i++) { Write-Host ('DELAYED_PROBE i=' + $i); if (Test-Path $h) { & $h -accepteula -nobanner 'D:\bld\test' 2>&1 | Write-Host } else { Write-Host 'DELAYED_NO_HANDLE64' }; Start-Sleep -Milliseconds 1500 }"
ping -n 2 127.0.0.1 >nul
exit /b 0
