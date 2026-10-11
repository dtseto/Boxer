# Phase 5: Remove the remaining DOSBox umbrella dependency

Phase 4 is closed. Phase 5 removes the last DOSBox-side dependency on the
umbrella `BXCoalface.h` header while retaining the legacy symbols required by
the extracted DOSBox harnesses.

## Boundary plan

1. Inventory the two approved transition references:
   - `DOSBox-Staging/include/BXDOSBoxCoalfaceCompatibility.h` included
     `BXCoalface.h` as the DOSBox compatibility umbrella.
   - `DOSBox-Staging/src/hardware/parport/printer_redir.cpp` retained a
     comment naming the old printer contract.
2. Move the DOSBox-required legacy declarations into
   `BXDOSBoxLegacyDeclarations.h`. This header is DOSBox-side only and is not
   part of the public opaque callback registration contract.
3. Remove the umbrella include from the DOSBox compatibility path.
4. Keep printer redirection on `BXDOSBoxLegacyCompatibility.h` and remove the
   obsolete transition comment now that the typed printer callback table
   represents the contract.
5. Keep standalone harness fallbacks and C++-linkage callback definitions
   compatible with the existing harness sources.

## Current implementation

- `BXDOSBoxBridgeRegistration.h` remains opaque and contains callback tables
  only.
- `BXDOSBoxLegacyDeclarations.h` supplies the DOSBox-only declarations and
  legacy remaps needed for production DOSBox compilation and ABI-compatible
  linkage.
- `BXDOSBoxLegacyCompatibility.h` retains weak fallback symbols and typed
  adapter tables for extracted harnesses.
- `printer_redir.cpp` has no `BXCoalface.h` reference and uses only the typed
  printer adapter at its call site.
- The integration contract test now asserts the new boundary.

## Acceptance checks

- No DOSBox source or compatibility header includes `BXCoalface.h`.
- No printer transition comment refers to the retired umbrella contract.
- Build-for-testing succeeds.
- Printer contract and runtime harness tests pass.
- Full test suite remains green.
- The application launches and DOS `exit` follows the existing clean shutdown
  path without the former KVO exception.

## Commit split

- Commit the DOSBox submodule changes separately.
- Commit the Boxer contract-test/documentation changes separately.
- Leave Xcode project churn, vendor submodules, and unrelated untracked files
  untouched.
