#
# Test the read of basic keyboard info info from js files 
#
# NOTE: The .dproj needs $(CI) added to the Delphi Compiler/Conditional defines (All 
# configurations - all platforms) section in order for the CI flag to be passed in.
# (It's best to make this change in Delphi IDE). 
#

!include ..\..\Defines.mak

test: build
    Win32\Debug\keyboardjsinfotestsuite.exe -b
  
build: 
    $(DELPHI_MSBUILD) /p:CI=CI keyboardjsinfotestsuite.dproj

clean: def-clean
    -rd /s/q Win32

!include ..\..\Target.mak
