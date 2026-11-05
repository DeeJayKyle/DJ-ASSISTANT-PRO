; DJ Assistant 2.0 installer (NSIS, per-user, no admin rights).
;
; It replaces DJ Assistant 1.x in place, the way 1.x's own (Tauri) installer
; updates itself, so the 1.x auto-updater can install 2.0:
;   - same product name, folder (%LOCALAPPDATA%\DJ Assistant) and registry keys;
;   - the 1.x program is removed by running its own uninstaller with /UPDATE,
;     which never touches app data or shortcuts;
;   - the switches the 1.x updater passes are understood:
;     /P passive (progress only), /S silent, /UPDATE, /R restart, /ARGS.
; The DJ's library, catalogue and settings live in
; %APPDATA%\com.deejaykyle.djassistant and are never read or removed here.
;
; Build: makensis /DVERSION=2.0.0 /DSRC=<flutter Release folder> /DICON=<app_icon.ico>
;        /DOUT=<setup.exe> dj_assistant.nsi

Unicode true
ManifestDPIAware true
SetCompressor /SOLID lzma
RequestExecutionLevel user

!ifndef VERSION
  !error "pass /DVERSION=x.y.z"
!endif
!ifndef SRC
  !error "pass /DSRC=<folder with dj_assistant.exe>"
!endif
!ifndef OUT
  !define OUT "DJ-Assistant_${VERSION}_x64-setup.exe"
!endif

!define PRODUCTNAME "DJ Assistant"
!define MANUFACTURER "DeeJayKyle"
!define BUNDLEID "com.deejaykyle.djassistant"
!define MAINBINARYNAME "dj_assistant"
!define UNINSTKEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCTNAME}"
!define MANUPRODUCTKEY "Software\${MANUFACTURER}\${PRODUCTNAME}"

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

Name "${PRODUCTNAME}"
OutFile "${OUT}"
InstallDir "$LOCALAPPDATA\${PRODUCTNAME}"
InstallDirRegKey HKCU "${MANUPRODUCTKEY}" ""
BrandingText "${PRODUCTNAME} ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "${PRODUCTNAME}"
VIAddVersionKey "CompanyName" "${MANUFACTURER}"
VIAddVersionKey "FileDescription" "${PRODUCTNAME} installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "Copyright (c) 2026 DeeJayKyle. MIT licence."

Var PassiveMode
Var UpdateMode
Var OldMainBinaryName

!ifndef ICON
  !error "pass /DICON=<app_icon.ico>"
!endif
!define MUI_ICON "${ICON}"
!define MUI_UNICON "${ICON}"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\${MAINBINARYNAME}.exe"
!define MUI_FINISHPAGE_RUN_TEXT "Open ${PRODUCTNAME}"

!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_WELCOME
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_PAGE_CUSTOMFUNCTION_PRE SkipIfPassive
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

Function SkipIfPassive
  ${IfThen} $PassiveMode = 1 ${|} Abort ${|}
FunctionEnd

Function .onInit
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/P" $R1
  ${IfNot} ${Errors}
    StrCpy $PassiveMode 1
  ${EndIf}
  ClearErrors
  ${GetOptions} $R0 "/UPDATE" $R1
  ${IfNot} ${Errors}
    StrCpy $UpdateMode 1
  ${EndIf}
  ; keep a custom folder chosen for 1.x
  ReadRegStr $R2 HKCU "${MANUPRODUCTKEY}" ""
  ${If} $R2 != ""
    StrCpy $INSTDIR $R2
  ${EndIf}
FunctionEnd

; Waits until a running copy has closed (the 1.x updater exits before it runs us).
Function WaitForAppToClose
  StrCpy $R9 0
  loop:
    ClearErrors
    ${If} ${FileExists} "$INSTDIR\${MAINBINARYNAME}.exe"
      FileOpen $R8 "$INSTDIR\${MAINBINARYNAME}.exe" a
      ${If} ${Errors}
        IntOp $R9 $R9 + 1
        ${If} $R9 > 30
          ${If} $PassiveMode = 1
          ${OrIf} ${Silent}
            Abort "${PRODUCTNAME} is still running."
          ${EndIf}
          MessageBox MB_RETRYCANCEL|MB_ICONEXCLAMATION "Close ${PRODUCTNAME}, then choose Retry." IDRETRY retry
          Abort
          retry:
          StrCpy $R9 0
        ${EndIf}
        Sleep 500
        Goto loop
      ${EndIf}
      FileClose $R8
    ${EndIf}
FunctionEnd

; Removes the 1.x (Tauri) program with its own uninstaller in update mode, so
; its app data, shortcuts and autostart entry are kept.
Function RemoveOneX
  ReadRegStr $R1 HKCU "${UNINSTKEY}" "UninstallString"
  ReadRegStr $R2 HKCU "${UNINSTKEY}" "DisplayVersion"
  ReadRegStr $OldMainBinaryName HKCU "${UNINSTKEY}" "MainBinaryName"
  ${If} $R1 == ""
    Return
  ${EndIf}
  StrCpy $R3 $R2 2
  ${If} $R3 != "1."
    Return ; an earlier 2.x: files are simply replaced below
  ${EndIf}
  DetailPrint "Removing DJ Assistant $R2 (your library and settings are kept)…"
  ; the Tauri uninstaller copies itself to %TEMP% unless _?= names its folder
  ExecWait '$R1 /UPDATE /P _?=$INSTDIR' $0
  ${If} $0 <> 0
    Abort "Could not remove DJ Assistant $R2 (code $0). Nothing else was changed."
  ${EndIf}
  ; _?= leaves the uninstaller itself behind
  Delete "$INSTDIR\uninstall.exe"
FunctionEnd

; Points an existing shortcut at the new program (1.x's exe had another name).
!macro RetargetShortcut LNK
  ${If} ${FileExists} "${LNK}"
    CreateShortcut "${LNK}" "$INSTDIR\${MAINBINARYNAME}.exe"
  ${EndIf}
!macroend

Section "Install"
  SetShellVarContext current
  Call WaitForAppToClose
  Call RemoveOneX

  SetOutPath "$INSTDIR"
  ; replace the previous 2.x files (the data folder is elsewhere)
  RMDir /r "$INSTDIR\data"
  File /r "${SRC}\*.*"
  WriteUninstaller "$INSTDIR\uninstall.exe"

  WriteRegStr HKCU "${MANUPRODUCTKEY}" "" "$INSTDIR"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayName" "${PRODUCTNAME}"
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayIcon" '"$INSTDIR\${MAINBINARYNAME}.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "${UNINSTKEY}" "Publisher" "${MANUFACTURER}"
  WriteRegStr HKCU "${UNINSTKEY}" "InstallLocation" '"$INSTDIR"'
  WriteRegStr HKCU "${UNINSTKEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKCU "${UNINSTKEY}" "MainBinaryName" "${MAINBINARYNAME}.exe"
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINSTKEY}" "NoRepair" 1
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKCU "${UNINSTKEY}" "EstimatedSize" "$0"

  ; 1.x kept its shortcuts through the update: point them at 2.0
  !insertmacro RetargetShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk"
  !insertmacro RetargetShortcut "$DESKTOP\${PRODUCTNAME}.lnk"
  ${IfNot} ${FileExists} "$SMPROGRAMS\${PRODUCTNAME}.lnk"
    CreateShortcut "$SMPROGRAMS\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
  ${EndIf}
  ; a first install also gets a desktop shortcut (not on updates)
  ${If} $UpdateMode <> 1
  ${AndIfNot} ${FileExists} "$DESKTOP\${PRODUCTNAME}.lnk"
    CreateShortcut "$DESKTOP\${PRODUCTNAME}.lnk" "$INSTDIR\${MAINBINARYNAME}.exe"
  ${EndIf}

  ${If} $PassiveMode = 1
    SetAutoClose true
  ${EndIf}
SectionEnd

Function .onInstSuccess
  ; /R (from the updater): start the app again
  ${If} $PassiveMode = 1
  ${OrIf} ${Silent}
    ${GetParameters} $R0
    ClearErrors
    ${GetOptions} $R0 "/R" $R1
    ${IfNot} ${Errors}
      Exec '"$INSTDIR\${MAINBINARYNAME}.exe"'
    ${EndIf}
  ${EndIf}
FunctionEnd

Function un.onInit
  ${GetParameters} $R0
  ClearErrors
  ${GetOptions} $R0 "/UPDATE" $R1
  ${IfNot} ${Errors}
    StrCpy $UpdateMode 1
  ${EndIf}
FunctionEnd

; Removes the program only. The DJ's library, catalogue, settings, packs and
; backups (%APPDATA%\com.deejaykyle.djassistant) are always kept.
Section "Uninstall"
  SetShellVarContext current
  Delete "$INSTDIR\${MAINBINARYNAME}.exe"
  Delete "$INSTDIR\*.dll"
  RMDir /r "$INSTDIR\data"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"
  ${If} $UpdateMode <> 1
    Delete "$SMPROGRAMS\${PRODUCTNAME}.lnk"
    Delete "$DESKTOP\${PRODUCTNAME}.lnk"
    DeleteRegKey HKCU "${UNINSTKEY}"
    DeleteRegKey HKCU "${MANUPRODUCTKEY}"
    DeleteRegKey /ifempty HKCU "Software\${MANUFACTURER}"
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "${PRODUCTNAME}"
  ${EndIf}
SectionEnd
