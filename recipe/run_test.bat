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
  python -m numba.runtests -b --random=0.5 --exclude-tags=long_running -m %CPU_COUNT%
) else (
  python -m numba.runtests -b --exclude-tags=long_running -m %CPU_COUNT%
)
if errorlevel 1 exit /b 1

@rem Windows: rattler-build removes the test dir immediately after this script,
@rem but the numba python.exe that ran the suite (its image lives inside the test
@rem prefix) may not have released yet -> "Access is denied (os error 5)".
@rem Print anything still running from D:\bld (diagnosis), reap stragglers (safe
@rem here: this interpreter is cmd, not python), then wait for handle release.
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like 'D:\bld\*' } | ForEach-Object { Write-Host ('HOLDER ' + $_.ProcessId + ' ' + $_.Name + ' :: ' + $_.ExecutablePath) }"
taskkill /F /T /IM python.exe >nul 2>&1
ping -n 8 127.0.0.1 >nul
exit /b 0
