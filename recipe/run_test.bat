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

@rem ===== EXPERIMENT: log-size hypothesis for the rattler-build test-dir cleanup lock =====
@rem prefix-dev/rattler-build#2657: rattler holds its own conda_build.log (inside the test dir)
@rem open, then rmdir's that dir -> "Access is denied (os error 5)" when the log has not closed
@rem in time. Diagnosis: the failure probability scales with test VOLUME, and the sole handle
@rem holder is conda_build.log, whose SIZE tracks the captured test output. Hypothesis: keep that
@rem log small and cleanup wins even at full volume. So run the FULL suite but REDIRECT the
@rem voluminous output to a file (kept OUT of stdout -> out of conda_build.log). Only a short
@rem summary is echoed on success; on failure the whole file is dumped so diagnostics survive.
@rem NOTE: FAST_TESTS branch intentionally collapsed to full for this experiment; restore later.
python -m numba.runtests -b --exclude-tags=long_running --random=0.25 -m %CPU_COUNT% > numba_test_output.log 2>&1
set "_RC=%errorlevel%"
if not "%_RC%"=="0" (
  echo ===== numba.runtests FAILED rc=%_RC% -- dumping captured output =====
  type numba_test_output.log
  exit /b 1
)
echo ===== numba.runtests PASSED -- summary only (full output suppressed to keep conda_build.log small) =====
findstr /C:"Ran " numba_test_output.log
findstr /C:"OK (" numba_test_output.log
exit /b 0
