/* A DLL of the test program's own, as a game ships some next to its exe.
 * The program imports it as CASETEST.dll; the file is casetest.dll, so the
 * loader finds it only when it compares names without regard to case. */
__declspec(dllexport) int casetest_value(void) { return 42; }
