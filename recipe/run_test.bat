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

@rem ===== EXPERIMENT: run tests from a TEMP dir outside D:\bld (prefix-dev/rattler-build#2657) =====
@rem The post-test os-error-5 lock is rattler-build failing to rmdir the test dir. The exact holder
@rem at the delete instant is unobserved (probes undershoot), and log-size redirection alone did not
@rem fix it. This variant additionally runs the suite from %TEMP%\numba_run (CWD OUTSIDE the test dir)
@rem and writes the captured output there, so nothing WE create lands in the dir rattler deletes.
@rem Caveat: rattler's own conda_build.log and numba's in-tree site-packages caches still remain in
@rem the test dir, so this only tests whether a CWD/temp file was contributing. --random=0.25 kept to
@rem isolate the temp-dir variable vs the redirect-only baseline (2/6 fail).
set "NUMBA_TMP=%TEMP%\numba_run"
if not exist "%NUMBA_TMP%" mkdir "%NUMBA_TMP%"
cd /d "%NUMBA_TMP%"
python -m numba.runtests -b --exclude-tags=long_running --random=0.25 -m %CPU_COUNT% > "%NUMBA_TMP%\numba_test_output.log" 2>&1
set "_RC=%errorlevel%"
if not "%_RC%"=="0" (
  echo ===== numba.runtests FAILED rc=%_RC% -- dumping captured output =====
  type "%NUMBA_TMP%\numba_test_output.log"
  exit /b 1
)
echo ===== numba.runtests PASSED -- summary only =====
findstr /C:"Ran " "%NUMBA_TMP%\numba_test_output.log"
findstr /C:"OK (" "%NUMBA_TMP%\numba_test_output.log"
exit /b 0
