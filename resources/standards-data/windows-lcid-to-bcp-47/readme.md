# LCID to BCP-47 mappings

These two mappings are not 100% identical. map-lcid-bcp47-icu.txt is sourced from the ICU source code, 
http://bugs.icu-project.org/trac/browser/trunk/icu4c/source/common/locmap.cpp and hand-massaged into a
data format.

The map-lcid-bcp47-win.txt file was generated by <keyman.git>/windows/src/support/locale-enum/locproc.dpr.
It was then hand-massaged to remove a few system-specific and irrelevant entries.

The two files are not identical. At present we are using the map-lcid-bcp47-win.txt file, but further
research could be done to determine which is the more appropriate file to use. The deviation from the 
Windows LCID mapping is mostly documented in the ICU source file above.

The map-lcid-bcp47-win.txt file is recommended for use by Keyman apps for translating between legacy
language IDs and BCP-47 codes, rather than Windows API functions, which may be lacking on down-level
platforms.

These tables are static and unlikely to change as Microsoft are no longer issuing new LCIDs.

unicode-copyright.txt may apply to the content extracted from locmap.cpp in map-lcid-bcp47-icu.txt
(not currently used but kept for future reference).
