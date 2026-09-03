!macro customUnInstall
  ${IfNot} ${isUpdated}
    ${IfNot} ${FileExists} "$INSTDIR\${PRODUCT_FILENAME}.exe"
      MessageBox MB_ICONSTOP|MB_OK "找不到 ZCode 状态灯主程序，无法确认 Hook 已安全移除。卸载已中止，请先恢复安装后再卸载。"
      Abort
    ${EndIf}
    ExecWait '"$INSTDIR\${PRODUCT_FILENAME}.exe" --unconfigure-hooks --silent' $R0
    ${If} $R0 != 0
      MessageBox MB_ICONSTOP|MB_OK "无法安全移除 ZCode 状态 Hook。卸载已中止，安装目录和 Hook 助手将被保留。"
      Abort
    ${EndIf}
  ${EndIf}
!macroend
